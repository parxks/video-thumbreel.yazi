--- @since 25.2.7
--- Optimized video thumbreel plugin for Yazi 26.5.6
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
M.play_states = M.play_states or {}          -- per-file "playing" / "stopped"
M.anim_states = M.anim_states or {}          -- { index, last_update, max_frame }
M.task_queue = M.task_queue or {}            -- pending ffmpeg batch jobs
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

-- ====================== Metadata: use built-in video plugin ======================
-- Load the official Yazi video plugin (provides list_meta)
local video_plugin_ok, video = pcall(require, "video")
if not video_plugin_ok then
    ya.err("Could not load built-in video plugin; falling back to ffprobe.")
end

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
    -- Fallback to manual ffprobe
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
    local codec = lines[1] or "unknown"
    local width = tonumber(lines[2]) or 0
    local height = tonumber(lines[3]) or 0
    local duration = tonumber(lines[4]) or 0
    if duration == 0 and tonumber(lines[1]) then
        duration = tonumber(lines[1])
    end
    return { codec = codec, width = width, height = height, duration = duration }
end

-- ====================== Cache key ======================
local function get_cache_key(job, info)
    local basename = job.file.name or tostring(job.file.url):match("([^/]+)$")
    local hash_input = string.format("%s|%s|%dx%d|%.2f|%s|%s|%s",
        basename, info.codec, info.width, info.height, info.duration,
        opts.base_frames, opts.frames_per_minute, opts.webp_quality
    )
    local hash = 0
    for i = 1, #hash_input do
        hash = (hash * 31 + hash_input:byte(i)) % (2^32)
    end
    return string.format("%08x", hash)
end

-- ====================== Task Queue ======================
-- Add a task to the queue, giving higher priority to current-directory files.
local function queue_task(url_str, cmd, done_path)
    -- Determine priority: 1 = current directory, 0 = other
    local current_dir = cx.active.current.cwd:gsub("/$", "")
    local file_dir = url_str:match("(.*)/[^/]+$") or ""
    local priority = (file_dir == current_dir) and 1 or 0

    -- Remove any old task for the same done_path (re‑queue)
    for i = #M.task_queue, 1, -1 do
        if M.task_queue[i].done_path == done_path then
            table.remove(M.task_queue, i)
        end
    end

    local task = { cmd = cmd, done_path = done_path, priority = priority }
    -- Insert keeping descending priority order (higher first)
    local inserted = false
    for i, t in ipairs(M.task_queue) do
        if priority > t.priority then
            table.insert(M.task_queue, i, task)
            inserted = true
            break
        end
    end
    if not inserted then
        table.insert(M.task_queue, task)
    end
end

-- Run the next task from the queue (spawns one ffmpeg)
local function process_next_task()
    if #M.task_queue == 0 then return end
    local task = table.remove(M.task_queue, 1)
    -- Avoid spawning if the done marker already appeared
    if is_valid_file(task.done_path) then
        -- Task is obsolete, skip and process next
        process_next_task()
    else
        Command("sh"):arg("-c"):arg(task.cmd):spawn()
    end
end

-- Clear the queue entirely (called on directory change)
local function clear_task_queue()
    M.task_queue = {}
end

-- ====================== Init & Cache ======================
local function ensure_init()
    if M._is_initialized then return end
    M._is_initialized = true
    os.execute(string.format('mkdir -p "%s"', opts.cache_dir))
    M:check_and_invalidate_cache()
    M:auto_clean()
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
        "base=%d|base30=%d|base60=%d|fpm=%.2f|fps=%d|q=%d|w=%d|h=%d|speed=%d|autoplay=%s|loop=%s",
        opts.base_frames, opts.base_30_min_frames, opts.base_60_min_frames,
        opts.frames_per_minute, opts.playback_fps, opts.webp_quality,
        opts.width, opts.height, opts.speed_preset,
        tostring(opts.autoplay), tostring(opts.loop)
    )
    local f = io.open(status_path, "r")
    local old_sig = f and f:read("*a")
    if f then f:close() end
    if old_sig ~= current_sig then
        os.execute(string.format('find "%s" -type f \\( -name "*.webp" -o -name "*.done" \\) -delete 2>/dev/null', opts.cache_dir))
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

    -- Layout
    local img_area = ui.Rect {
        x = job.area.x, y = job.area.y,
        w = job.area.w, h = math.max(1, job.area.h - 1)
    }
    local txt_area = ui.Rect {
        x = job.area.x, y = job.area.y + job.area.h - 1,
        w = job.area.w, h = 1
    }

    -- Dynamic frame count
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

    -- Info bar
    local info_str = string.format(" %s | %dx%d | %.1fs | %d frames ",
        info.codec:upper(), info.width, info.height, info.duration, target_frames)
    ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

    -- Refresh TTL
    if is_valid_file(done_path) then
        Command("touch"):arg(done_path):spawn()
    end

    -- ----- Centering calculation -----
    local video_w = info.width
    local video_h = info.height
    -- Compute rendered size keeping aspect ratio, fitting into img_area
    local scale = math.min(img_area.w / video_w, img_area.h / video_h)
    local rendered_w = math.floor(video_w * scale)
    local rendered_h = math.floor(video_h * scale)
    local x_offset = img_area.x + math.floor((img_area.w - rendered_w) / 2)
    local y_offset = img_area.y + math.floor((img_area.h - rendered_h) / 2)
    local centered_area = ui.Rect {
        x = x_offset, y = y_offset,
        w = rendered_w, h = rendered_h
    }

    -- ----- First frame: async extraction -----
    if not is_valid_file(first_frame_path) then
        -- Spawn a single-frame ffmpeg without blocking
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
            :spawn()
        -- Show a placeholder (or nothing) – the next peek will display it
        return
    end

    -- ----- Batch extraction: use queue -----
    if not is_valid_file(done_path) then
        local extract_fps = target_frames / info.duration
        local ffmpeg_cmd = string.format(
            'ffmpeg -i "%s" -vf "fps=%f,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" -vframes %d -c:v libwebp -speed %d -quality %d -y "%s/%s_frame_%%04d.webp" && touch "%s"',
            url_str, extract_fps,
            rendered_w, rendered_h, rendered_w, rendered_h,
            target_frames, opts.speed_preset, opts.webp_quality,
            opts.cache_dir, cache_key, done_path
        )
        queue_task(url_str, ffmpeg_cmd, done_path)
        process_next_task()
    end

    -- ----- Play state initialization -----
    if M.play_states[url_str] == nil then
        M.play_states[url_str] = opts.autoplay and "playing" or "stopped"
    end

    -- ----- Non-blocking animation -----
    if M.play_states[url_str] == "playing" and target_frames > 1 then
        local now = os.clock()
        local state = M.anim_states[url_str]

        if not state then
            state = { index = 1, last_update = now, max_frame = 1 }
            M.anim_states[url_str] = state
        end

        -- Incrementally update max_frame (only check next sequential frames)
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

        if state.max_frame <= 1 then
            -- Only the first frame exists yet; display it
            ya.image_show(Url(first_frame_path), centered_area)
            return
        end

        -- Advance frame(s) based on elapsed time
        local elapsed = now - state.last_update
        local interval = 1 / opts.playback_fps

        while elapsed >= interval and M.play_states[url_str] == "playing" do
            state.index = state.index + 1
            if state.index > state.max_frame then
                if not opts.loop then
                    M.play_states[url_str] = "stopped"
                    break
                else
                    state.index = 1
                end
            end
            state.last_update = state.last_update + interval
            elapsed = now - state.last_update
        end

        if M.play_states[url_str] == "playing" then
            local current_path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, state.index)
            ya.image_show(Url(current_path), centered_area)
        else
            -- Loop disabled, show last frame
            local last_path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, state.max_frame)
            ya.image_show(Url(last_path), centered_area)
        end
        return
    end

    -- Fallback: show first frame (static mode or paused)
    if is_valid_file(first_frame_path) then
        ya.image_show(Url(first_frame_path), centered_area)
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
            ya.manager_emit("peek", { force = true })
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

-- ====================== Hooks for queue management ======================
-- Clear the task queue whenever the user changes directory.
-- This prevents processing of videos from a folder you already left.
function M:cd_event(job)
    clear_task_queue()
end

-- Register the hook in Yazi's initialization.
ya.hook("cd", function(job)
    M:cd_event(job)
end)

-- ====================== Cleanup ======================
function M:seek(job) end

return M
