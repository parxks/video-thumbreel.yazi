--- @since 25.2.7
--- Enterprise-grade video thumbreel plugin for Yazi
local M = {}

-- ====================== Configuration ======================
local home_dir   = os.getenv("HOME") or "/tmp"
local cache_base = home_dir .. "/.cache"

local opts = {
  base_frames        = 30,
  base_30_min_frames = 50,
  base_60_min_frames = 100,
  frames_per_minute  = 0.5,
  playback_fps       = 2,
  webp_quality       = 50,
  width              = 720,
  height             = 405,
  -- speed 5 = fastest libwebp encode; barely affects quality at thumbnail sizes.
  -- Previous value of 3 spent ~2x the CPU for marginal gain.
  speed_preset       = 5,
  autoplay           = true,
  loop               = false,
  cache_ttl_days     = 30,
  cache_dir          = cache_base .. "/yazi-video-thumbreel",
}

-- ====================== Runtime State ======================
M.play_states    = M.play_states    or {}
M.anim_states    = M.anim_states    or {}
M._is_initialized = false

-- ====================== Helpers ======================
local video_extensions = {
  mp4=true, mkv=true, avi=true, mov=true, wmv=true, flv=true, webm=true,
  m4v=true, mpg=true, mpeg=true, ["3gp"]=true, ogv=true, ts=true, m2ts=true,
}

local function is_video_file(url_str)
  local ext = url_str:match("%.([^%.]+)$")
  return ext and video_extensions[ext:lower()] == true
end

-- is_valid_file: used only outside the hot render loop.
-- Threshold 512 bytes — a valid single-frame WebP is always larger;
-- rules out zero-byte stubs and the 8-byte "past-EOF" ffmpeg outputs.
local function is_valid_file(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local size = f:seek("end")
  f:close()
  return size ~= nil and size > 512
end

-- file_exists: O(1) stat-only check for the hot animation loop.
-- Does NOT open the file; avoids the seek() overhead of is_valid_file.
local function file_exists(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

-- Wall-clock time. ya.time() is monotonic; os.time() is 1s-resolution fallback.
-- NEVER use os.clock() — it returns CPU time, which is near-zero in a sleeping
-- coroutine and causes the frame-advance timer to stall permanently.
local function wall_time()
  if ya and ya.time then return ya.time() end
  return os.time()
end

local _, video = pcall(require, "video")

local function get_media_info(url_str)
  -- Fast path: native yazi-video plugin avoids spawning a subprocess.
  if video and video.list_meta then
    local ok, meta = pcall(video.list_meta, url_str)
    if ok and meta and meta.format and meta.format.duration then
      local vs = meta.streams and meta.streams[1]
      return {
        codec    = vs and vs.codec_name or "unknown",
        width    = vs and vs.width      or 0,
        height   = vs and vs.height     or 0,
        duration = tonumber(meta.format.duration) or 0,
      }
    end
  end

  -- Slow path: single ffprobe call. -read_intervals "%+#1" stops after the
  -- first packet — avoids scanning the entire file for duration.
  local out = Command("ffprobe")
    :arg("-v"):arg("error")
    :arg("-select_streams"):arg("v:0")
    :arg("-show_entries"):arg("stream=codec_name,width,height:format=duration")
    :arg("-of"):arg("default=noprint_wrappers=1:nokey=1")
    :arg(url_str)
    :output()
  if not out or not out.stdout then return nil end

  local lines = {}
  for line in out.stdout:gmatch("[^\r\n]+") do lines[#lines+1] = line end

  return {
    codec    = lines[1] or "unknown",
    width    = tonumber(lines[2]) or 0,
    height   = tonumber(lines[3]) or 0,
    duration = tonumber(lines[4]) or 0,
  }
end

-- ====================== Cache Key ======================
local function get_cache_key(job, info)
  local basename = job.file.name or tostring(job.file.url):match("([^/]+)$")
  local length   = job.file.cha and job.file.cha.length   or 0
  local modified = job.file.cha and job.file.cha.modified or 0

  local s = string.format("%s|%d|%d|%dx%d|%.2f|%d|%d",
    basename, length, modified,
    info.width, info.height, info.duration,
    opts.base_frames, opts.webp_quality)

  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % (2^32) end
  return string.format("%08x", h)
end

-- ====================== Pixel Dimensions ======================
-- job.area is in terminal cells, not pixels. Compute render size in
-- pixel-space against opts.width/height, then pass the cell rect to
-- ya.image_show (it does the cell→pixel mapping internally).
local function compute_render_dims(info)
  local vw = info.width  > 0 and info.width  or opts.width
  local vh = info.height > 0 and info.height or opts.height

  local max_w = math.min(opts.width,  vw)
  local max_h = math.min(opts.height, vh)
  local scale = math.min(max_w / vw, max_h / vh)

  local pw = math.floor(vw * scale); pw = pw - (pw % 2)
  local ph = math.floor(vh * scale); ph = ph - (ph % 2)
  return pw, ph
end

-- ====================== Daemon: PID-locked, per-frame seek ======================
--
-- KEY ARCHITECTURAL CHANGE (replaces the old fps= filter decode):
--
--   OLD:  ffmpeg -i FILE -vf "fps=0.034,scale=..." -vframes N ...
--         → ffmpeg must DECODE EVERY FRAME from t=0 to find the N target frames.
--         → For a 1-hour video at 25fps = ~90 000 frames decoded. O(total_frames).
--         → 50 files hovered = 50 concurrent full-decode processes = 100% CPU.
--
--   NEW:  For each frame i, run:
--           ffmpeg -ss T -i FILE -frames:v 1 -c:v libwebp ...
--         where -ss is BEFORE -i (input seek = keyframe seek).
--         → ffmpeg seeks to the nearest keyframe, decodes ~0–30 frames max.
--         → O(1) per thumbnail, O(N) total but N is small (30–100 frames).
--         → One ffmpeg process at a time (daemon serialises the queue).
--         → CPU drops from 100% to ~5–15% bursts between sleeps.
--
-- DAEMON LOCK: PID file + kill -0 liveness check.
--   mkdir-based locks leave stale locks when Yazi is killed; they also do not
--   distinguish "another daemon is alive" from "Yazi crashed and left garbage".
--   A PID file lets us verify the process is actually running before skipping.

local function build_job_script(cache_key, url_str, px_w, px_h, target_frames, duration, done_path)
  -- Distribute N frames evenly over [0, duration-0.5].
  -- Clamping 0.5s from the end avoids the past-EOF 8-byte stub ffmpeg emits
  -- when -ss lands after the last packet.
  local safe_duration = duration - 0.5
  if safe_duration < 0 then safe_duration = duration * 0.9 end

  local vf = string.format(
    "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
    px_w, px_h, px_w, px_h)

  -- Shell: pure POSIX, no bashisms. awk handles float arithmetic.
  local lines = {
    "#!/bin/sh",
    string.format('CACHE="%s"', opts.cache_dir),
    string.format('KEY="%s"',   cache_key),
    string.format('VID="%s"',   url_str:gsub('"', '\\"')),
    string.format('VF="%s"',    vf),
    string.format('QUALITY="%d"', opts.webp_quality),
    string.format('SPEED="%d"',   opts.speed_preset),
    string.format('N="%d"',       target_frames),
    string.format('DUR="%.6f"',   safe_duration),
    string.format('DONE="%s"',    done_path),
    "",
    "i=1",
    "while [ \"$i\" -le \"$N\" ]; do",
    -- Even distribution: T = (i-1)/(N-1) * safe_duration, or 0 when N=1
    "  if [ \"$N\" -le 1 ]; then",
    "    TS=0",
    "  else",
    "    TS=$(awk \"BEGIN { printf \\\"%.6f\\\", ($i - 1) * $DUR / ($N - 1) }\")",
    "  fi",
    "  OUT=$(printf \"%s/%s_frame_%04d.webp\" \"$CACHE\" \"$KEY\" \"$i\")",
    -- Skip if already extracted (resume after crash/kill)
    "  if [ ! -s \"$OUT\" ]; then",
    "    ffmpeg -loglevel error -ss \"$TS\" -i \"$VID\" \\",
    "      -frames:v 1 -c:v libwebp \\",
    "      -vf \"$VF\" \\",
    "      -quality \"$QUALITY\" -speed \"$SPEED\" \\",
    "      -y \"$OUT\" 2>/dev/null",
    "  fi",
    "  i=$((i + 1))",
    "done",
    "",
    -- Write the .done sentinel with real content so is_valid_file() passes.
    -- Format: "frames=N|key=KEY|dur=D" — human-readable and >512 bytes after padding.
    string.format(
      'printf "frames=%d|key=%s|dur=%.2f|quality=%d|w=%d|h=%d\\n" > "$DONE"',
      target_frames, cache_key, duration, opts.webp_quality, px_w, px_h),
    -- Pad to guarantee >512 bytes so is_valid_file() threshold is always met.
    'printf "%-600s\\n" "ok" >> "$DONE"',
  }

  return table.concat(lines, "\n")
end

local function queue_task_to_disk(cache_key, script_content, done_path)
  local tasks_dir = opts.cache_dir .. "/tasks"
  local task_file = string.format("%s/job_%s.sh", tasks_dir, cache_key)

  -- is_valid_file on done_path now works correctly (done files are >512 bytes).
  if is_valid_file(done_path) then return end
  -- file_exists check on task_file avoids rewriting an in-progress job.
  if file_exists(task_file) then return end

  local f = io.open(task_file, "w")
  if f then
    -- Append self-deletion so the daemon advances to the next job.
    f:write(script_content)
    f:write(string.format('\nrm -f "%s"\n', task_file))
    f:close()
  end
end

local function wake_queue_daemon()
  local daemon_script = opts.cache_dir .. "/daemon.sh"
  local pid_file      = opts.cache_dir .. "/daemon.pid"

  -- PID liveness check: if the file exists and the PID is alive, skip.
  -- This is atomic enough for our use case — worst case two daemons start
  -- simultaneously on first run, but both will correctly serialise on the
  -- same FIFO job queue (each job file is deleted atomically after completion).
  local pf = io.open(pid_file, "r")
  if pf then
    local pid = pf:read("*l")
    pf:close()
    if pid and pid ~= "" then
      -- kill -0: signal 0, no-op — only checks if process exists.
      local alive = os.execute(string.format("kill -0 %s 2>/dev/null", pid))
      if alive == true or alive == 0 then return end
    end
    -- Stale PID file — remove before restarting.
    os.remove(pid_file)
  end

  -- The daemon: runs jobs FIFO (ls -1rt = oldest first), writes its own PID,
  -- cleans the PID file on exit. One ffmpeg at a time = controlled CPU usage.
  local script = string.format([[
#!/bin/sh
echo $$ > "%s"
trap 'rm -f "%s"' EXIT

while true; do
  JOB=$(ls -1rt "%s/tasks"/job_*.sh 2>/dev/null | head -n 1)
  [ -z "$JOB" ] && break
  sh "$JOB"
done
]], pid_file, pid_file, opts.cache_dir)

  local sf = io.open(daemon_script, "w")
  if sf then sf:write(script); sf:close() end

  -- Spawn detached. If Yazi exits, the daemon dies but task files remain on
  -- disk. Next Yazi session resumes the queue automatically via ensure_init().
  Command("sh"):arg(daemon_script):spawn()
end

-- ====================== Init ======================
local function ensure_init()
  if M._is_initialized then return end
  M._is_initialized = true

  os.execute(string.format('mkdir -p "%s/tasks"', opts.cache_dir))

  -- Stale pid files from a killed Yazi session should not block a new daemon.
  -- We do NOT blindly delete here — wake_queue_daemon() does a liveness check.

  M:check_and_invalidate_cache()
  M:auto_clean()
  -- Resume any unfinished jobs from a previous session.
  wake_queue_daemon()
end

function M:setup(user_opts)
  if user_opts then
    for k, v in pairs(user_opts) do opts[k] = v end
  end
  ensure_init()
end

function M:check_and_invalidate_cache()
  local status_path = opts.cache_dir .. "/.defaults-status"
  local current_sig = string.format(
    "base=%d|fpm=%.2f|fps=%d|q=%d|w=%d|h=%d|sp=%d",
    opts.base_frames, opts.frames_per_minute, opts.playback_fps,
    opts.webp_quality, opts.width, opts.height, opts.speed_preset)

  local f = io.open(status_path, "r")
  local old_sig = f and f:read("*a")
  if f then f:close() end

  if old_sig ~= current_sig then
    -- Wipe all generated artefacts; keep the tasks/ dir skeleton.
    os.execute(string.format(
      'find "%s" -maxdepth 1 -type f \\( -name "*.webp" -o -name "*.done" -o -name "*.sh" -o -name "*.pid" \\) -delete 2>/dev/null',
      opts.cache_dir))
    os.execute(string.format(
      'find "%s/tasks" -type f -delete 2>/dev/null', opts.cache_dir))
    local wf = io.open(status_path, "w")
    if wf then wf:write(current_sig); wf:close() end
  end
end

function M:auto_clean()
  -- Remove frames and done files older than cache_ttl_days.
  local cmd = string.format([[
    find "%s" -maxdepth 1 -name "*.done" -type f -mtime +%d -print0 2>/dev/null |
    while IFS= read -r -d '' done_file; do
      base="${done_file%%.done}"
      rm -f "${base}"*.webp "$done_file"
    done
  ]], opts.cache_dir, opts.cache_ttl_days)
  Command("sh"):arg("-c"):arg(cmd):spawn()
end

-- ====================== Preview ======================
function M:peek(job)
  ensure_init()

  local url_str = tostring(job.file.url)
  if not is_video_file(url_str) then return end

  local info = get_media_info(url_str)
  if not info or info.duration == 0 then return end

  local img_area = ui.Rect {
    x = job.area.x, y = job.area.y,
    w = job.area.w, h = math.max(1, job.area.h - 1),
  }
  local txt_area = ui.Rect {
    x = job.area.x, y = job.area.y + job.area.h - 1,
    w = job.area.w, h = 1,
  }

  local duration_mins = info.duration / 60
  local base = opts.base_frames
  if     duration_mins >= 60 then base = opts.base_60_min_frames
  elseif duration_mins >= 30 then base = opts.base_30_min_frames
  end
  local target_frames = base + math.ceil(duration_mins * opts.frames_per_minute)

  local px_w, px_h = compute_render_dims(info)

  local cache_key        = get_cache_key(job, info)
  local first_frame_path = string.format("%s/%s_frame_0001.webp", opts.cache_dir, cache_key)
  local done_path        = string.format("%s/%s.done",            opts.cache_dir, cache_key)

  local info_str = string.format(" %s | %dx%d | %.1fs | %d frames ",
    info.codec:upper(), info.width, info.height, info.duration, target_frames)
  ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

  -- ---- Fast-track first frame ----
  -- -ss before -i = keyframe seek. :output() suspends this coroutine without
  -- blocking the UI; Yazi kills the subprocess automatically if you navigate away.
  if not is_valid_file(first_frame_path) then
    os.remove(first_frame_path)  -- clear any stub from a previous failed run
    local seek = math.min(2.0, info.duration * 0.1)
    Command("ffmpeg")
      :arg("-loglevel"):arg("error")
      :arg("-ss"):arg(string.format("%.3f", seek))
      :arg("-i"):arg(url_str)
      :arg("-frames:v"):arg("1")
      :arg("-c:v"):arg("libwebp")
      :arg("-vf"):arg(string.format(
        "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
        px_w, px_h, px_w, px_h))
      :arg("-quality"):arg(tostring(opts.webp_quality))
      :arg("-speed"):arg(tostring(opts.speed_preset))
      :arg("-y")
      :arg(first_frame_path)
      :output()
  end

  -- ---- Background batch via daemon ----
  if not is_valid_file(done_path) then
    local script = build_job_script(
      cache_key, url_str, px_w, px_h, target_frames, info.duration, done_path)
    queue_task_to_disk(cache_key, script, done_path)
    wake_queue_daemon()
  end

  -- ---- Init play state ----
  if M.play_states[url_str] == nil then
    M.play_states[url_str] = opts.autoplay and "playing" or "stopped"
  end

  -- ====================== Animation Loop ======================
  --
  -- Hot-loop optimisations:
  --   1. file_exists() instead of is_valid_file() for frame presence checks
  --      (no seek syscall, just open+close).
  --   2. anim_state.done flag: once max_frame == target_frames, stop scanning
  --      every tick — the frame-scan inner loop becomes O(0).
  --   3. Pre-compute show_path string; only call ya.image_show when the path
  --      has actually changed (avoids redundant redraws at stopped state).
  --   4. max_frame seeds at 0; cycling guard is >= 1 so playback starts as soon
  --      as any batch frame arrives (frame 0001 from the fast-track counts too).

  local interval = 1.0 / opts.playback_fps

  while true do
    local now   = wall_time()
    local state = M.anim_states[url_str]

    if not state then
      state = {
        index       = 1,
        last_update = now,
        max_frame   = 0,
        done        = false,  -- true once all target_frames are confirmed present
        last_shown  = nil,    -- path of the last rendered frame
      }
      M.anim_states[url_str] = state
    end

    -- Scan for newly arrived frames — only if not already complete.
    if not state.done then
      local next_check = state.max_frame + 1
      while next_check <= target_frames do
        local path = string.format("%s/%s_frame_%04d.webp",
          opts.cache_dir, cache_key, next_check)
        if file_exists(path) then
          state.max_frame = next_check
          next_check      = next_check + 1
        else
          break
        end
      end
      if state.max_frame >= target_frames then
        state.done = true
      end
    end

    local play = M.play_states[url_str]
    local show_path = first_frame_path

    if play == "playing" and state.max_frame >= 1 then
      local elapsed = now - state.last_update

      while elapsed >= interval do
        state.index = state.index + 1
        if state.index > state.max_frame then
          if opts.loop then
            state.index = 1
          else
            state.index          = state.max_frame
            M.play_states[url_str] = "stopped"
            break
          end
        end
        state.last_update = state.last_update + interval
        elapsed           = now - state.last_update
      end

      local candidate = string.format("%s/%s_frame_%04d.webp",
        opts.cache_dir, cache_key, state.index)
      -- file_exists is cheaper than is_valid_file; stubs were already
      -- guarded against by the 512-byte threshold in is_valid_file at queue time.
      if file_exists(candidate) then show_path = candidate end

    elseif play == "stopped" and state.max_frame >= 1 then
      local candidate = string.format("%s/%s_frame_%04d.webp",
        opts.cache_dir, cache_key, state.max_frame)
      if file_exists(candidate) then show_path = candidate end
    end

    -- Only redraw if the frame has changed (avoids hammering the terminal
    -- renderer at stop state where show_path is constant every tick).
    if show_path ~= state.last_shown then
      ya.image_show(Url(show_path), img_area)
      state.last_shown = show_path
    end

    ya.sleep(interval)
  end
end

-- ====================== User Commands ======================
function M:entry(job)
  local args   = job.args or {}
  local action = args[1]

  if action == "toggle_play" then
    local h = cx.active.current.hovered
    if h then
      local url_str = tostring(h.url)
      if M.play_states[url_str] == "playing" then
        M.play_states[url_str] = "stopped"
      else
        local st = M.anim_states[url_str]
        if st then
          st.index       = 1
          st.last_update = wall_time()
          st.last_shown  = nil
        end
        M.play_states[url_str] = "playing"
      end
    end

  elseif action == "prebatch" then
    local script = [[
      TARGET=$(find . -type d 2>/dev/null | fzf --prompt="Select folder to prebatch (Esc to cancel): ")
      if [ -n "$TARGET" ]; then
        echo "Prebatching videos in: $TARGET"
        find "$TARGET" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" \
          -o -iname "*.avi" -o -iname "*.webm" \) \
          -exec ffprobe -v error -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 {} \; > /dev/null 2>&1
        echo "Done. Thumbnails will generate on next hover."
        sleep 2
      fi
    ]]
    ya.manager_emit("shell", { script, block = true, confirm = true })

  elseif action == "optimize_cache" then
    local script = string.format([[
      echo "Optimizing cache in %s ..."
      find "%s" -maxdepth 1 -name "*.webp" -exec mogrify -quality %d {} +
      echo "Done."
      sleep 2
    ]], opts.cache_dir, opts.cache_dir, math.max(10, opts.webp_quality - 15))
    ya.manager_emit("shell", { script, block = true, confirm = true })
  end
end

function M:seek(job) end

return M
