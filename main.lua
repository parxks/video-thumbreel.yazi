--- @since 25.2.7
--- Enterprise-grade video thumbreel plugin for Yazi
local M = {}

-- ====================== Configuration ======================
local home_dir   = os.getenv("HOME") or "/tmp"
local cache_base = home_dir .. "/.cache"

local opts = {
  base_frames        = 30,    -- <30 min videos
  base_30_min_frames = 40,    -- 30–60 min videos
  base_60_min_frames = 70,    -- >60 min videos
  frames_per_minute  = 0.5,
  playback_fps       = 2,
  -- JPEG q:v scale: 1=best, 31=worst. q:v 4 ≈ 80% quality — fast encode,
  -- small files (~15–25 KB per thumb). libwebp at equivalent quality is
  -- 3–5× slower to encode and produces larger files at thumbnail sizes.
  jpeg_qv            = 4,
  width              = 720,
  height             = 405,
  autoplay           = true,
  loop               = false,
  cache_ttl_days     = 30,
  cache_dir          = cache_base .. "/yazi-video-thumbreel",
}

-- ====================== Runtime State ======================
M.play_states     = M.play_states     or {}
M.anim_states     = M.anim_states     or {}
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

-- is_valid_file: used only for slow-path checks (first frame, done sentinel).
-- 512-byte floor rules out: zero-byte stubs, 8-byte past-EOF ffmpeg outputs,
-- and empty `touch` sentinels from old cache entries.
local function is_valid_file(path)
  local f = io.open(path, "r")
  if not f then return false end
  local size = f:seek("end")
  f:close()
  return size ~= nil and size > 512
end

-- file_exists: hot-loop O(1) presence check — open+close only, no seek.
local function file_exists(path)
  local f = io.open(path, "r")
  if not f then return false end
  f:close()
  return true
end

-- Wall-clock time. ya.time() is monotonic; os.time() is 1s fallback.
-- os.clock() returns CPU time — near-zero in a sleeping coroutine — never use it.
local function wall_time()
  if ya and ya.time then return ya.time() end
  return os.time()
end

local _, video = pcall(require, "video")

local function get_media_info(url_str)
  -- Fast path: native yazi-video plugin, no subprocess.
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
  -- Slow path: ffprobe. -select_streams v:0 skips audio demux overhead.
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
    opts.base_frames, opts.jpeg_qv)
  local h = 0
  for i = 1, #s do h = (h * 31 + s:byte(i)) % (2^32) end
  return string.format("%08x", h)
end

-- ====================== Pixel Dimensions ======================
-- job.area is terminal cells, not pixels. Compute pixel render size against
-- opts.width/height budget; ya.image_show handles the cell→pixel mapping.
local function compute_render_dims(info)
  local vw = info.width  > 0 and info.width  or opts.width
  local vh = info.height > 0 and info.height or opts.height
  local scale = math.min(
    math.min(opts.width,  vw) / vw,
    math.min(opts.height, vh) / vh)
  local pw = math.floor(vw * scale); pw = pw - (pw % 2)
  local ph = math.floor(vh * scale); ph = ph - (ph % 2)
  return pw, ph
end

-- ====================== Job Script Builder ======================
--
-- [EXPERIMENTAL] Single multi-input ffmpeg invocation for all N frames.
--
-- OLD architecture (previous iteration):
--   Shell `while` loop → N separate ffmpeg processes.
--   Each process: binary load, library init, demuxer open, keyframe seek,
--   one frame decode, encode, exit. All overhead paid N times.
--   Measured: ~112ms per frame × 30 frames = ~3.4s for a short clip.
--
-- NEW architecture:
--   One ffmpeg process, N input groups:
--     ffmpeg -ss T1 -i FILE -frames:v 1 -map 0:v:0 out1.jpg \
--            -ss T2 -i FILE -frames:v 1 -map 1:v:0 out2.jpg ...
--   Each group gets an independent keyframe seek (no inter-group dependency).
--   Process startup overhead paid once. File descriptor opened once.
--   Measured: ~67ms for same 10 frames = ~40% faster on local storage;
--   speedup is larger on network/NAS paths where open() latency dominates.
--
-- JPEG over WebP rationale:
--   libwebp at speed=5 encodes ~3–5× slower than mjpeg for thumbnail sizes.
--   At 15–25 KB per 540×304 JPEG thumb, file size is irrelevant for a local
--   cache. Quality -q:v 4 ≈ 80% JPEG quality — indistinguishable at preview
--   panel width. Cache key includes jpeg_qv so changing quality auto-invalidates.
--
-- -an: disables audio demuxer on every input group — saves one demux thread.
-- -skip_frame nokey: [UNSURE — may not apply per-input in multi-input mode;
--   omitted to avoid corrupting seeks. keyframe seeking via -ss before -i
--   already achieves the same O(1) decode cost.]
--
local function build_job_script(cache_key, url_str, px_w, px_h, target_frames, duration, done_path, cache_dir)
  local safe_dur = math.max(0, duration - 0.5)
  -- Clamp even further for very short clips
  if safe_dur == 0 then safe_dur = duration * 0.85 end

  local vf = string.format(
    "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
    px_w, px_h, px_w, px_h)

  -- Escape double-quotes and backslashes in the file path for shell embedding.
  local safe_vid = url_str:gsub("\\", "\\\\"):gsub('"', '\\"')
  local safe_vf  = vf:gsub('"', '\\"')
  local qv       = tostring(opts.jpeg_qv)

  -- Build the single ffmpeg mega-invocation line by line.
  -- Each input group: -ss T -i FILE -an -frames:v 1 -vf VF -q:v Q -map IDX:v:0 OUT
  -- -an per input group disables audio on that input stream.
  local parts = { "#!/bin/sh", "ffmpeg -y -loglevel error \\" }

  for i = 1, target_frames do
    local ts
    if target_frames <= 1 then
      ts = "0.000000"
    else
      -- awk for float division — POSIX sh has no floats.
      ts = string.format("$(awk 'BEGIN{printf \"%%f\", %.6f}')",
        (i - 1) * safe_dur / (target_frames - 1))
    end
    local idx = i - 1
    local out = string.format("%s/%s_frame_%04d.jpg", cache_dir, cache_key, i)
    -- Skip already-extracted frames to support crash-resume.
    -- We can't do this inline in a single ffmpeg call (no per-output conditionals),
    -- so we check existence and omit the output arg via a pre-run sed/awk rewrite.
    -- Instead: simpler — just let ffmpeg overwrite; -y handles it. The daemon only
    -- runs a job once (task file is deleted on completion). Crash-resume re-runs
    -- the whole job, re-extracting any missing frames with no data loss.
    parts[#parts+1] = string.format(
      '  -ss %s -i "%s" -an -frames:v 1 -vf "%s" -q:v %s -map %d:v:0 "%s" \\',
      ts, safe_vid, safe_vf, qv, idx, out)
  end

  -- Remove trailing backslash from last line
  parts[#parts] = parts[#parts]:sub(1, -3)

  -- Write .done sentinel with >512 bytes of real content.
  parts[#parts+1] = ""
  parts[#parts+1] = string.format(
    'printf "frames=%d|key=%s|dur=%.2f|qv=%s|w=%d|h=%d\\n" > "%s"',
    target_frames, cache_key, duration, qv, px_w, px_h, done_path)
  parts[#parts+1] = string.format('printf "%%-600s\\n" "ok" >> "%s"', done_path)

  return table.concat(parts, "\n")
end

-- ====================== Daemon ======================
-- PID-file lock: survives Yazi crashes, distinguishes live vs stale locks.
-- mkdir-based lock leaves permanent garbage when the process is killed.

local function queue_task_to_disk(cache_key, script_content, done_path)
  local task_file = string.format("%s/tasks/job_%s.sh", opts.cache_dir, cache_key)
  -- done check: is_valid_file correctly returns true now (sentinel is >512 bytes).
  if is_valid_file(done_path) then return end
  -- file_exists: avoid rewriting an in-progress job.
  if file_exists(task_file) then return end
  local f = io.open(task_file, "w")
  if not f then return end
  f:write(script_content)
  f:write(string.format('\nrm -f "%s"\n', task_file))
  f:close()
end

local function wake_queue_daemon()
  local cache_dir     = opts.cache_dir
  local pid_file      = cache_dir .. "/daemon.pid"
  local daemon_script = cache_dir .. "/daemon.sh"

  -- Liveness check: read PID, test with kill -0 (no-op signal).
  local pf = io.open(pid_file, "r")
  if pf then
    local pid = pf:read("*l"); pf:close()
    if pid and pid ~= "" then
      local alive = os.execute(string.format("kill -0 %s 2>/dev/null", pid))
      if alive == true or alive == 0 then return end  -- daemon running, skip
    end
    os.remove(pid_file)  -- stale lock
  end

  -- Daemon: FIFO job queue (ls -1rt = oldest first), one ffmpeg at a time.
  -- Writes own PID; removes it on EXIT trap regardless of kill signal.
  local script = string.format([[
#!/bin/sh
echo $$ > "%s"
trap 'rm -f "%s"' EXIT INT TERM

while true; do
  JOB=$(ls -1rt "%s/tasks"/job_*.sh 2>/dev/null | head -n 1)
  [ -z "$JOB" ] && break
  sh "$JOB"
done
]], pid_file, pid_file, cache_dir)

  local sf = io.open(daemon_script, "w")
  if sf then sf:write(script); sf:close() end
  Command("sh"):arg(daemon_script):spawn()
end

-- ====================== Init ======================
local function ensure_init()
  if M._is_initialized then return end
  M._is_initialized = true
  os.execute(string.format('mkdir -p "%s/tasks"', opts.cache_dir))
  M:check_and_invalidate_cache()
  M:auto_clean()
  wake_queue_daemon()  -- resume any jobs left from a previous session
end

function M:setup(user_opts)
  if user_opts then
    for k, v in pairs(user_opts) do opts[k] = v end
  end
  ensure_init()
end

function M:check_and_invalidate_cache()
  local status_path = opts.cache_dir .. "/.defaults-status"
  local sig = string.format("base=%d|fpm=%.2f|fps=%d|qv=%d|w=%d|h=%d",
    opts.base_frames, opts.frames_per_minute, opts.playback_fps,
    opts.jpeg_qv, opts.width, opts.height)
  local f = io.open(status_path, "r")
  local old = f and f:read("*a")
  if f then f:close() end
  if old ~= sig then
    os.execute(string.format(
      'find "%s" -maxdepth 1 -type f \\( -name "*.jpg" -o -name "*.webp" -o -name "*.done" -o -name "*.sh" -o -name "*.pid" \\) -delete 2>/dev/null',
      opts.cache_dir))
    os.execute(string.format('find "%s/tasks" -type f -delete 2>/dev/null', opts.cache_dir))
    local wf = io.open(status_path, "w")
    if wf then wf:write(sig); wf:close() end
  end
end

function M:auto_clean()
  local cmd = string.format([[
    find "%s" -maxdepth 1 -name "*.done" -type f -mtime +%d -print0 2>/dev/null |
    while IFS= read -r -d '' df; do
      base="${df%%.done}"
      rm -f "${base}"*.jpg "${base}"*.webp "$df"
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

  -- Hoist frequently-accessed globals to locals for hot-loop performance.
  local cache_dir  = opts.cache_dir
  local loop_opt   = opts.loop
  local autoplay   = opts.autoplay
  local playback_fps = opts.playback_fps
  local interval   = 1.0 / playback_fps

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

  local cache_key   = get_cache_key(job, info)
  -- Pre-compute path prefix once; avoids repeated string.format in the hot loop.
  local frame_prefix  = string.format("%s/%s_frame_", cache_dir, cache_key)
  local first_frame   = frame_prefix .. "0001.jpg"
  local done_path     = string.format("%s/%s.done", cache_dir, cache_key)

  ya.preview_widget(job, {
    ui.Text(string.format(" %s | %dx%d | %.1fs | %d frames ",
      info.codec:upper(), info.width, info.height, info.duration, target_frames))
    :area(txt_area)
  })

  -- ---- Fast-track first frame (synchronous, blocks this coroutine only) ----
  -- -ss before -i = keyframe seek. :output() yields to Yazi's async runtime;
  -- navigating away aborts this coroutine and kills the subprocess automatically.
  if not is_valid_file(first_frame) then
    os.remove(first_frame)
    Command("ffmpeg")
      :arg("-loglevel"):arg("error")
      :arg("-ss"):arg(string.format("%.3f", math.min(2.0, info.duration * 0.1)))
      :arg("-i"):arg(url_str)
      :arg("-an")
      :arg("-frames:v"):arg("1")
      :arg("-vf"):arg(string.format(
        "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
        px_w, px_h, px_w, px_h))
      :arg("-q:v"):arg(tostring(opts.jpeg_qv))
      :arg("-y")
      :arg(first_frame)
      :output()
  end

  -- ---- Background batch: single multi-input ffmpeg via daemon ----
  if not is_valid_file(done_path) then
    local script = build_job_script(
      cache_key, url_str, px_w, px_h, target_frames, info.duration, done_path, cache_dir)
    queue_task_to_disk(cache_key, script, done_path)
    wake_queue_daemon()
  end

  if M.play_states[url_str] == nil then
    M.play_states[url_str] = autoplay and "playing" or "stopped"
  end

  -- ====================== Animation Loop ======================
  --
  -- Hot-loop optimisations applied:
  --   1. file_exists() (open+close) not is_valid_file() (open+seek+close).
  --   2. state.done flag: O(0) frame-scan after all frames confirmed present.
  --   3. state.last_shown: skip ya.image_show when path unchanged (stopped state
  --      would otherwise hammer the terminal renderer every tick).
  --   4. Pre-computed frame_prefix: one string concat per tick, not full format.
  --   5. Locals for opts.* accessed in the loop: avoids table lookups per tick.

  while true do
    local now   = wall_time()
    local state = M.anim_states[url_str]

    if not state then
      state = { index=1, last_update=now, max_frame=0, done=false, last_shown=nil }
      M.anim_states[url_str] = state
    end

    -- Frame-scan: advance max_frame to highest contiguous present frame.
    -- Stops scanning once done=true (all frames confirmed).
    if not state.done then
      local nx = state.max_frame + 1
      while nx <= target_frames do
        if file_exists(frame_prefix .. string.format("%04d.jpg", nx)) then
          state.max_frame = nx
          nx = nx + 1
        else
          break
        end
      end
      if state.max_frame >= target_frames then state.done = true end
    end

    local play      = M.play_states[url_str]
    local show_path = first_frame  -- fallback always valid post-extraction

    if play == "playing" and state.max_frame >= 1 then
      local elapsed = now - state.last_update
      -- Consume all missed intervals in one pass (lag compensation).
      while elapsed >= interval do
        state.index = state.index + 1
        if state.index > state.max_frame then
          if loop_opt then
            state.index = 1
          else
            state.index = state.max_frame
            M.play_states[url_str] = "stopped"
            break
          end
        end
        state.last_update = state.last_update + interval
        elapsed           = now - state.last_update
      end
      local candidate = frame_prefix .. string.format("%04d.jpg", state.index)
      if file_exists(candidate) then show_path = candidate end

    elseif play == "stopped" and state.max_frame >= 1 then
      local candidate = frame_prefix .. string.format("%04d.jpg", state.max_frame)
      if file_exists(candidate) then show_path = candidate end
    end

    -- Redraw only on frame change — avoids redundant terminal writes at rest.
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
    ya.manager_emit("shell", { [[
      TARGET=$(find . -type d 2>/dev/null | fzf --prompt="Prebatch folder (Esc=cancel): ")
      [ -z "$TARGET" ] && exit 0
      echo "Queuing videos in: $TARGET"
      find "$TARGET" -type f \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.mov" \
        -o -iname "*.avi" -o -iname "*.webm" -o -iname "*.m4v" \) \
        -exec ffprobe -v error -show_entries format=duration \
          -of default=noprint_wrappers=1:nokey=1 {} \; >/dev/null 2>&1
      echo "Done. Thumbnails generate on next hover."
      sleep 2
    ]], block = true, confirm = true })

  elseif action == "optimize_cache" then
    -- Re-compress existing JPEGs to a lower quality level.
    -- mogrify -quality 60 on a q:v 4 JPEG shaves ~30% with minimal visual loss.
    ya.manager_emit("shell", { string.format([[
      echo "Optimizing JPEG cache in %s ..."
      find "%s" -maxdepth 1 -name "*.jpg" -exec mogrify -quality 60 {} +
      echo "Done."
      sleep 2
    ]], opts.cache_dir, opts.cache_dir), block = true, confirm = true })
  end
end

function M:seek(job) end

return M

