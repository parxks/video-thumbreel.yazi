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

local video_plugin_ok, video = pcall(require, "video")

local function get_media_info(url_str)
  if video and video.list_meta then
    local ok, meta = pcall(video.list_meta, url_str)
    if ok and meta and meta.format and meta.format.duration then
      local vstream = meta.streams and meta.streams[1]
      return {
        codec = vstream and vstream.codec_name or "unknown",
        width = vstream and vstream.width or 0,
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
    codec = lines[1] or "unknown",
    width = tonumber(lines[2]) or 0,
    height = tonumber(lines[3]) or 0,
    duration = tonumber(lines[4]) or 0
  }
end

-- ====================== Resilient State Hashing ======================
local function get_cache_key(job, info)
  -- We use Yazi's built-in file characteristics (cha). 
  -- If the file size or modification date changes, the hash changes,
  -- invalidating the cache safely without blocking the UI thread.
  local basename = job.file.name or tostring(job.file.url):match("([^/]+)$")
  local length = job.file.cha and job.file.cha.length or 0
  local modified = job.file.cha and job.file.cha.modified or 0
  
  local hash_input = string.format("%s|%d|%d|%dx%d|%.2f|%s|%d",
    basename, length, modified, info.width, info.height, info.duration,
    opts.base_frames, opts.webp_quality
  )
  
  local hash = 0
  for i = 1, #hash_input do
    hash = (hash * 31 + hash_input:byte(i)) % (2^32)
  end
  return string.format("%08x", hash)
end

-- ====================== Persistent FIFO Disk Queue ======================
local function queue_task_to_disk(task_id, cmd_str, done_path)
  local tasks_dir = opts.cache_dir .. "/tasks"
  local task_file = string.format("%s/job_%s.sh", tasks_dir, task_id)
  
  -- If it's done or already queued, skip.
  if is_valid_file(done_path) or is_valid_file(task_file) then return end

  -- Write the bash task
  local f = io.open(task_file, "w")
  if f then
    f:write(string.format("#!/bin/sh\n%s\nrm -f \"%s\"", cmd_str, task_file))
    f:close()
  end
end

local function wake_queue_daemon()
  local daemon_script = opts.cache_dir .. "/daemon.sh"
  local lock_dir = opts.cache_dir .. "/daemon.lock"
  
  -- The Daemon script: Uses atomic mkdir as a strict process lock.
  -- Sorts tasks by time (-rt) to prioritize FIFO (finish started tasks first).
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
  
  -- Spawn detached. If Yazi dies, the daemon dies, but the tasks/ folder 
  -- remains on disk. Next time Yazi opens, it resumes the exact queue!
  Command("sh"):arg(daemon_script):spawn()
end

-- ====================== Init & Cache ======================
local function ensure_init()
  if M._is_initialized then return end
  M._is_initialized = true
  
  os.execute(string.format('mkdir -p "%s/tasks"', opts.cache_dir))
  
  -- Clear stale daemon locks from previous aborted Yazi sessions
  os.execute(string.format('rm -rf "%s/daemon.lock"', opts.cache_dir))
  
  M:check_and_invalidate_cache()
  M:auto_clean()
  
  -- If tasks exist from a previous session, immediately wake the daemon to resume them
  wake_queue_daemon()
end

function M:setup(user_opts)
  if user_opts then
    for k, v in pairs(user_opts) do
      opts[k] = v
    end
  end
  ensure_init()
end

function M:check_and_invalidate_cache()
  local status_path = opts.cache_dir .. "/.defaults-status"
  local current_sig = string.format(
    "base=%d|fpm=%.2f|fps=%d|q=%d|w=%d|h=%d",
    opts.base_frames, opts.frames_per_minute, opts.playback_fps, opts.webp_quality,
    opts.width, opts.height
  )
  local f = io.open(status_path, "r")
  local old_sig = f and f:read("*a")
  if f then f:close() end
  
  if old_sig ~= current_sig then
    os.execute(string.format('find "%s" -type f \\( -name "*.webp" -o -name "*.done" -o -name "*.sh" \\) -delete 2>/dev/null', opts.cache_dir))
    local wf = io.open(status_path, "w")
    if wf then
      wf:write(current_sig)
      wf:close()
    end
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

  local img_area = ui.Rect {
    x = job.area.x, y = job.area.y,
    w = job.area.w, h = math.max(1, job.area.h - 1)
  }
  local txt_area = ui.Rect {
    x = job.area.x, y = job.area.y + job.area.h - 1,
    w = job.area.w, h = 1
  }

  local duration_mins = info.duration / 60
  local base = opts.base_frames
  if duration_mins >= 60 then
    base = opts.base_60_min_frames
  elseif duration_mins >= 30 then
    base = opts.base_30_min_frames
  end
  local target_frames = base + math.ceil(duration_mins * opts.frames_per_minute)

  local cache_key = get_cache_key(job, info)
  local first_frame_path = string.format("%s/%s_frame_0001.webp", opts.cache_dir, cache_key)
  local done_path = string.format("%s/%s.done", opts.cache_dir, cache_key)

  local info_str = string.format(" %s | %dx%d | %.1fs | %d frames ",
    info.codec:upper(), info.width, info.height, info.duration, target_frames)
  ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

  local video_w = info.width > 0 and info.width or img_area.w
  local video_h = info.height > 0 and info.height or img_area.h
  local scale = math.min(img_area.w / video_w, img_area.h / video_h)
  local rendered_w = math.floor(video_w * scale)
  local rendered_h = math.floor(video_h * scale)
  
  -- FFmpeg requires even dimensions
  rendered_w = rendered_w - (rendered_w % 2)
  rendered_h = rendered_h - (rendered_h % 2)

  local x_offset = img_area.x + math.floor((img_area.w - rendered_w) / 2)
  local y_offset = img_area.y + math.floor((img_area.h - rendered_h) / 2)
  local centered_area = ui.Rect {
    x = x_offset, y = y_offset,
    w = rendered_w, h = rendered_h
  }

  -- [CRITICAL FIX]: The Fast-Track First Frame
  -- Using :output() forces Yazi's async runtime to pause this Lua thread without blocking the UI.
  -- If you scroll to a new video, Yazi automatically aborts this thread and kills ffmpeg, saving CPU.
  -- If it finishes, it immediately paints the frame so you never see a blank screen.
  if not is_valid_file(first_frame_path) then
    Command("ffmpeg")
      :arg("-ss"):arg(tostring(math.min(2.0, info.duration * 0.1)))
      :arg("-i"):arg(url_str)
      :arg("-frames:v"):arg("1")
      :arg("-c:v"):arg("libwebp")
      :arg("-vf"):arg(string.format("scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2",
        rendered_w, rendered_h, rendered_w, rendered_h))
      :arg("-quality"):arg(tostring(opts.webp_quality))
      :arg("-y")
      :arg(first_frame_path)
      :output()
  end

  -- Background Batch Extraction Queueing
  if not is_valid_file(done_path) then
    local extract_fps = target_frames / info.duration
    local ffmpeg_cmd = string.format(
      'ffmpeg -i "%s" -vf "fps=%f,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" -vframes %d -c:v libwebp -speed %d -quality %d -y "%s/%s_frame_%%04d.webp" && touch "%s"',
      url_str, extract_fps,
      rendered_w, rendered_h, rendered_w, rendered_h,
      target_frames, opts.speed_preset, opts.webp_quality,
      opts.cache_dir, cache_key, done_path
    )
    
    queue_task_to_disk(cache_key, ffmpeg_cmd, done_path)
    wake_queue_daemon()
  end

  if M.play_states[url_str] == nil then
    M.play_states[url_str] = opts.autoplay and "playing" or "stopped"
  end

  -- Reactive Animation Loop
  while true do
    local now = os.clock()
    local state = M.anim_states[url_str]

    if not state then
      state = { index = 1, last_update = now, max_frame = 1 }
      M.anim_states[url_str] = state
    end

    -- Dynamically check how many frames the background daemon has finished
    local next_to_check = state.max_frame + 1
    while next_to_check <= target_frames do
      local path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, next_to_check)
      if is_valid_file(path) then
        state.max_frame = next_to_check
        next_to_check = state.max_frame + 1
      else
        break
      end
    end

    local show_path = first_frame_path
    
    -- If playing, cycle frames
    if M.play_states[url_str] == "playing" and state.max_frame > 1 then
      local elapsed = now - state.last_update
      local interval = 1 / opts.playback_fps

      while elapsed >= interval do
        state.index = state.index + 1
        if state.index > state.max_frame then
          if opts.loop then
            state.index = 1
          else
            M.play_states[url_str] = "stopped"
            break
          end
        end
        state.last_update = state.last_update + interval
        elapsed = now - state.last_update
      end
      
      show_path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, state.index)
    
    -- If stopped and fully loaded, show the last frame as the "cover"
    elseif M.play_states[url_str] == "stopped" and state.max_frame > 1 then
        show_path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, state.max_frame)
    end

    if is_valid_file(show_path) then
      ya.image_show(Url(show_path), centered_area)
    elseif is_valid_file(first_frame_path) then
      ya.image_show(Url(first_frame_path), centered_area)
    end

    ya.sleep(1 / opts.playback_fps)
  end
end

-- ====================== User Commands ======================
function M:entry(job)
  local args = job.args or {}
  local action = args[1]

  if action == "toggle_play" then
    local h = cx.active.current.hovered
    if h then
      local url_str = tostring(h.url)
      if M.play_states[url_str] == "playing" then
        M.play_states[url_str] = "stopped"
      else
        M.play_states[url_str] = "playing"
      end
    end

  elseif action == "prebatch" then
    local script = string.format([[
      TARGET=$(find . -type d 2>/dev/null | fzf --prompt="Select folder to prebatch (Esc to cancel): ")
      if [ -n "$TARGET" ]; then
        echo "Prebatching videos in: $TARGET"
        find "$TARGET" -type f -exec ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 {} \; > /dev/null 2>&1
        echo "Triggered indexing for chosen directory."
        sleep 2
      fi
    ]])
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
