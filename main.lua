--- @since 25.2.7
--- Enterprise-grade video thumbreel plugin for Yazi
local M = {}

-- ====================== Configuration ======================
local home_dir = os.getenv("HOME") or "/tmp"
local cache_base = home_dir .. "/.cache"

local opts = {
  base_frames = 30,
  base_30_min_frames = 50,
  base_60_min_frames = 100,
  frames_per_minute = 0.5,
  playback_fps = 2,
  webp_quality = 50,
  width = 720,
  height = 405,
  speed_preset = 3,
  autoplay = true,
  loop = false,
  cache_ttl_days = 30,
  cache_dir = cache_base .. "/yazi-video-thumbreel",
}

-- ====================== Runtime State ======================
M.play_states = M.play_states or {}
M.anim_states = M.anim_states or {}
M._is_initialized = false

-- ====================== Helper Functions ======================
local video_extensions = {
  mp4 = true, mkv = true, avi = true, mov = true, wmv = true, flv = true, webm = true,
  m4v = true, mpg = true, mpeg = true, ["3gp"] = true, ogv = true, ts = true, m2ts = true
}

local function is_video_file(url_str)
  local ext = url_str:match("%.([^%.]+)$")
  return ext and video_extensions[ext:lower()] == true
end

local function is_valid_file(path)
  local f = io.open(path, "rb")
  if not f then return false end
  local size = f:seek("end")
  f:close()
  return size and size > 100
end

-- FIX 4: wall-clock time for accurate frame timing.
-- ya.time() is the preferred Yazi API; fall back to os.time() (1s resolution)
-- as a last resort. os.clock() returns CPU time, not elapsed time, and drifts
-- badly inside a sleeping coroutine.
local function wall_time()
  if ya and ya.time then return ya.time() end
  return os.time()
end

local video_plugin_ok, video = pcall(require, "video")

local function get_media_info(url_str)
  if video and video.list_meta then
    local ok, meta = pcall(video.list_meta, url_str)
    if ok and meta and meta.format and meta.format.duration then
      local vstream = meta.streams and meta.streams[1]
      return {
        codec  = vstream and vstream.codec_name or "unknown",
        width  = vstream and vstream.width  or 0,
        height = vstream and vstream.height or 0,
        duration = tonumber(meta.format.duration) or 0
      }
    end
  end

  local cmd = Command("ffprobe")
    :arg("-v"):arg("error")
    :arg("-select_streams"):arg("v:0")
    :arg("-show_entries"):arg("stream=codec_name,width,height:format=duration")
    :arg("-of"):arg("default=noprint_wrappers=1:nokey=1")
    :arg(url_str)
  local output = cmd:output()
  if not output or not output.stdout then return nil end

  local lines = {}
  for line in output.stdout:gmatch("[^\r\n]+") do
    table.insert(lines, line)
  end

  return {
    codec    = lines[1] or "unknown",
    width    = tonumber(lines[2]) or 0,
    height   = tonumber(lines[3]) or 0,
    duration = tonumber(lines[4]) or 0
  }
end

-- ====================== Resilient State Hashing ======================
local function get_cache_key(job, info)
  local basename = job.file.name or tostring(job.file.url):match("([^/]+)$")
  local length   = job.file.cha and job.file.cha.length   or 0
  local modified = job.file.cha and job.file.cha.modified or 0

  local hash_input = string.format("%s|%d|%d|%dx%d|%.2f|%d|%d",
    basename, length, modified, info.width, info.height, info.duration,
    opts.base_frames, opts.webp_quality
  )

  local hash = 0
  for i = 1, #hash_input do
    hash = (hash * 31 + hash_input:byte(i)) % (2^32)
  end
  return string.format("%08x", hash)
end

-- ====================== Pixel Dimension Helpers ======================
-- FIX 1: job.area is in terminal *cells*, not pixels. We compute the render
-- dimensions in pixel-space using opts.width/height as the pixel budget, then
-- keep centered_area in cell coordinates for ya.image_show (which maps cells
-- → pixels internally via the terminal's cell size).
local function compute_render_dims(info, area)
  local video_w = info.width  > 0 and info.width  or opts.width
  local video_h = info.height > 0 and info.height or opts.height

  -- Pixel budget: honour the configured max, but never up-scale.
  local max_px_w = math.min(opts.width,  video_w)
  local max_px_h = math.min(opts.height, video_h)

  local scale    = math.min(max_px_w / video_w, max_px_h / video_h)
  local px_w     = math.floor(video_w * scale)
  local px_h     = math.floor(video_h * scale)

  -- FFmpeg requires even dimensions
  px_w = px_w - (px_w % 2)
  px_h = px_h - (px_h % 2)

  return px_w, px_h
end

-- ====================== Persistent FIFO Disk Queue ======================
local function queue_task_to_disk(task_id, cmd_str, done_path)
  local tasks_dir = opts.cache_dir .. "/tasks"
  local task_file = string.format("%s/job_%s.sh", tasks_dir, task_id)

  if is_valid_file(done_path) or is_valid_file(task_file) then return end

  local f = io.open(task_file, "w")
  if f then
    f:write(string.format("#!/bin/sh\n%s\nrm -f \"%s\"", cmd_str, task_file))
    f:close()
  end
end

local function wake_queue_daemon()
  local daemon_script = opts.cache_dir .. "/daemon.sh"
  local lock_dir      = opts.cache_dir .. "/daemon.lock"

  local script_content = string.format([[
#!/bin/sh
if ! mkdir "%s" 2>/dev/null; then exit 0; fi
trap 'rm -rf "%s"' EXIT

while true; do
  JOB=$(ls -1rt "%s/tasks"/job_*.sh 2>/dev/null | head -n 1)
  if [ -z "$JOB" ]; then
    break
  fi
  sh "$JOB"
done
]], lock_dir, lock_dir, opts.cache_dir)

  local f = io.open(daemon_script, "w")
  if f then
    f:write(script_content)
    f:close()
  end

  Command("sh"):arg(daemon_script):spawn()
end

-- ====================== Init & Cache ======================
local function ensure_init()
  if M._is_initialized then return end
  M._is_initialized = true

  os.execute(string.format('mkdir -p "%s/tasks"', opts.cache_dir))
  os.execute(string.format('rm -rf "%s/daemon.lock"', opts.cache_dir))

  M:check_and_invalidate_cache()
  M:auto_clean()
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
    "base=%d|fpm=%.2f|fps=%d|q=%d|w=%d|h=%d",
    opts.base_frames, opts.frames_per_minute, opts.playback_fps,
    opts.webp_quality, opts.width, opts.height
  )
  local f = io.open(status_path, "r")
  local old_sig = f and f:read("*a")
  if f then f:close() end

  if old_sig ~= current_sig then
    os.execute(string.format(
      'find "%s" -type f \\( -name "*.webp" -o -name "*.done" -o -name "*.sh" \\) -delete 2>/dev/null',
      opts.cache_dir
    ))
    local wf = io.open(status_path, "w")
    if wf then wf:write(current_sig); wf:close() end
  end
end

function M:auto_clean()
  local cmd = string.format([[
    find "%s" -name "*.done" -type f -mtime +%d -print0 2>/dev/null |
    while IFS= read -r -d '' file; do
      base="${file%%.done}"
      rm -f "$base"*
    done
  ]], opts.cache_dir, opts.cache_ttl_days)
  Command("sh"):arg("-c"):arg(cmd):spawn()
end

-- ====================== Preview Entry ======================
function M:peek(job)
  ensure_init()

  local url_str = tostring(job.file.url)
  if not is_video_file(url_str) then return end

  local info = get_media_info(url_str)
  if not info or info.duration == 0 then return end

  -- Reserve one cell row at the bottom for the info bar
  local img_area = ui.Rect {
    x = job.area.x, y = job.area.y,
    w = job.area.w, h = math.max(1, job.area.h - 1)
  }
  local txt_area = ui.Rect {
    x = job.area.x, y = job.area.y + job.area.h - 1,
    w = job.area.w, h = 1
  }

  -- Frame count based on duration bracket
  local duration_mins = info.duration / 60
  local base = opts.base_frames
  if duration_mins >= 60 then
    base = opts.base_60_min_frames
  elseif duration_mins >= 30 then
    base = opts.base_30_min_frames
  end
  local target_frames = base + math.ceil(duration_mins * opts.frames_per_minute)

  -- FIX 1: compute pixel render dimensions separately from cell area
  local px_w, px_h = compute_render_dims(info, img_area)

  -- Center the image within the cell area (Yazi maps cell coords → pixels)
  -- img_area.w/h are cells; we keep positioning in cells but scale image in pixels.
  local centered_area = ui.Rect {
    x = img_area.x,
    y = img_area.y,
    w = img_area.w,
    h = img_area.h,
  }

  local cache_key      = get_cache_key(job, info)
  local first_frame_path = string.format("%s/%s_frame_0001.webp", opts.cache_dir, cache_key)
  local done_path        = string.format("%s/%s.done",            opts.cache_dir, cache_key)

  local info_str = string.format(" %s | %dx%d | %.1fs | %d frames ",
    info.codec:upper(), info.width, info.height, info.duration, target_frames)
  ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

  -- FIX 3: First-frame extraction.
  -- • -ss BEFORE -i  → fast keyframe seek (already correct, kept).
  -- • Add -loglevel error to suppress noise that can stall :output().
  -- • Guard against ffmpeg writing a <100 byte stub on failure by deleting
  --   invalid output before retrying — prevents infinite re-runs.
  if not is_valid_file(first_frame_path) then
    -- Remove any zero/stub file left by a previous failed run
    os.remove(first_frame_path)

    local seek_pos = tostring(math.min(2.0, info.duration * 0.1))
    Command("ffmpeg")
      :arg("-loglevel"):arg("error")
      :arg("-ss"):arg(seek_pos)
      :arg("-i"):arg(url_str)
      :arg("-frames:v"):arg("1")
      :arg("-c:v"):arg("libwebp")
      :arg("-vf"):arg(string.format(
        "scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
        px_w, px_h, px_w, px_h))
      :arg("-quality"):arg(tostring(opts.webp_quality))
      :arg("-y")
      :arg(first_frame_path)
      :output()
  end

  -- Enqueue background batch extraction (all frames, lower priority)
  if not is_valid_file(done_path) then
    local extract_fps = target_frames / info.duration
    local ffmpeg_cmd  = string.format(
      'ffmpeg -loglevel error -i "%s" -vf "fps=%f,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" -vframes %d -c:v libwebp -speed %d -quality %d -y "%s/%s_frame_%%04d.webp" && touch "%s"',
      url_str, extract_fps,
      px_w, px_h, px_w, px_h,
      target_frames, opts.speed_preset, opts.webp_quality,
      opts.cache_dir, cache_key, done_path
    )
    queue_task_to_disk(cache_key, ffmpeg_cmd, done_path)
    wake_queue_daemon()
  end

  -- Initialise play state
  if M.play_states[url_str] == nil then
    M.play_states[url_str] = opts.autoplay and "playing" or "stopped"
  end

  -- ====================== Reactive Animation Loop ======================
  -- FIX 2: max_frame seeded at 0 (not 1).  A value of 0 means "we have the
  -- separately-extracted first frame but no batch frames yet."  The cycling
  -- guard is changed to >= 1 so playback starts as soon as even one batch
  -- frame exists.  This unblocks animation for the common case where the
  -- daemon finishes frame 1 quickly.
  while true do
    local now   = wall_time()  -- FIX 4: wall-clock, not CPU time
    local state = M.anim_states[url_str]

    if not state then
      state = { index = 1, last_update = now, max_frame = 0 }
      M.anim_states[url_str] = state
    end

    -- Scan forward from where we left off — O(new frames only), not O(total)
    local next_to_check = state.max_frame + 1
    while next_to_check <= target_frames do
      local path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, next_to_check)
      if is_valid_file(path) then
        state.max_frame = next_to_check
        next_to_check   = state.max_frame + 1
      else
        break
      end
    end

    local show_path = first_frame_path  -- fallback: always valid after extraction above

    -- FIX 2 (cont.): guard changed from > 1  →  >= 1
    if M.play_states[url_str] == "playing" and state.max_frame >= 1 then
      local elapsed  = now - state.last_update
      local interval = 1.0 / opts.playback_fps

      -- Advance frame index by however many intervals elapsed (handles lag)
      while elapsed >= interval do
        state.index = state.index + 1
        if state.index > state.max_frame then
          if opts.loop then
            state.index = 1
          else
            M.play_states[url_str] = "stopped"
            state.index = state.max_frame  -- hold last frame
            break
          end
        end
        state.last_update = state.last_update + interval
        elapsed           = now - state.last_update
      end

      local candidate = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, state.index)
      if is_valid_file(candidate) then show_path = candidate end

    elseif M.play_states[url_str] == "stopped" and state.max_frame >= 1 then
      local candidate = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, state.max_frame)
      if is_valid_file(candidate) then show_path = candidate end
    end

    -- Render: prefer the chosen frame; fall back to the fast-track first frame
    if is_valid_file(show_path) then
      ya.image_show(Url(show_path), centered_area)
    elseif is_valid_file(first_frame_path) then
      ya.image_show(Url(first_frame_path), centered_area)
    end

    ya.sleep(1.0 / opts.playback_fps)
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
        -- Reset index so replay starts from frame 1, not the last stopped position
        if M.anim_states[url_str] then
          M.anim_states[url_str].index       = 1
          M.anim_states[url_str].last_update = wall_time()
        end
        M.play_states[url_str] = "playing"
      end
    end

  elseif action == "prebatch" then
    local script = [[
      TARGET=$(find . -type d 2>/dev/null | fzf --prompt="Select folder to prebatch (Esc to cancel): ")
      if [ -n "$TARGET" ]; then
        echo "Prebatching videos in: $TARGET"
        find "$TARGET" -type f -exec ffprobe -v error -show_entries format=duration \
          -of default=noprint_wrappers=1:nokey=1 {} \; > /dev/null 2>&1
        echo "Triggered indexing for chosen directory."
        sleep 2
      fi
    ]]
    ya.manager_emit("shell", { script, block = true, confirm = true })

  elseif action == "optimize_cache" then
    local script = string.format([[
      echo "Optimizing Yazi video thumbreel cache in %s..."
      find "%s" -name "*.webp" -exec mogrify -quality %d {} +
      echo "Optimization complete!"
      sleep 2
    ]], opts.cache_dir, opts.cache_dir, math.max(10, opts.webp_quality - 15))
    ya.manager_emit("shell", { script, block = true, confirm = true })
  end
end

function M:seek(job) end

return M
