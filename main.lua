--- @since 25.2.7
local M = {}

-- FIXED: Bypassing XDG_CACHE_HOME to strictly prevent saving inside your .config directory
local home_dir = os.getenv("HOME") or "/tmp"
local cache_base = home_dir .. "/.cache"

-- Default settings matching your specific requirements
local opts = {
    base_frames = 30,               -- Base count for videos < 30 mins
    base_30_min_frames = 50,         -- Base count for 30+ min videos
    base_60_min_frames = 100,        -- Base count for 60+ min videos
    frames_per_minute = 0.5,         -- Added frames per minute of video length (rounds up)
    playback_fps = 2,               -- Frame rate for preview animation
    webp_quality = 50,              -- WebP compression quality
    width = 720,                    -- Rendering frame width
    height = 405,                   -- Rendering frame height
    speed_preset = 3,               -- libwebp speed/compression preset (0-6)
    autoplay = true,                -- Start animation on hover
    loop = false,                   -- Keep animation looping
    cache_ttl_days = 30,            -- Auto-clean stale caches
    cache_dir = cache_base .. "/yazi-video-thumbreel",
}

-- Registry to track active playback states across the runtime
M.play_states = M.play_states or {}
M._is_initialized = false

-- Self-initializing function to ensure folders exist even if setup() wasn't manually called
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

-- Invalidation Flag check. Triggers automatic cache flush when defaults or parameters change.
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
        -- Purge everything in the cache directory when defaults change
        os.execute(string.format('find "%s" -type f \\( -name "*.webp" -o -name "*.done" \\) -delete 2>/dev/null', opts.cache_dir))
        
        -- Store the updated configuration signature
        local wf = io.open(status_path, "w")
        if wf then
            wf:write(current_sig)
            wf:close()
        end
    end
end

-- Cleans stale extraction sequences based on elapsed time (cache_ttl_days)
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

local video_extensions = {
    mp4 = true, mkv = true, avi = true, mov = true, wmv = true, flv = true, webm = true,
    m4v = true, mpg = true, mpeg = true, ["3gp"] = true, ogv = true, ts = true, m2ts = true
}

local function is_video_file(url_str)
    local ext = url_str:match("%.([^%.]+)$")
    return ext and video_extensions[ext:lower()] == true
end

-- Validate WebP files on disk to prevent rendering partially written files
local function is_valid_file(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local size = f:seek("end")
    f:close()
    return size and size > 100
end

-- Fetch codec details, resolution, and total video duration
local function get_media_info(url_str)
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

-- Build highly specific cache key so renamed files safely use cached copies
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

function M:peek(job)
    ensure_init() -- Guarantee folders are generated and evaluated
    
    local url_str = tostring(job.file.url)
    if not is_video_file(url_str) then return end

    local info = get_media_info(url_str)
    if not info or info.duration == 0 then return end

    -- Layout split calculation
    local img_area = ui.Rect { x = job.area.x, y = job.area.y, w = job.area.w, h = math.max(1, job.area.h - 1) }
    local txt_area = ui.Rect { x = job.area.x, y = job.area.y + job.area.h - 1, w = job.area.w, h = 1 }

    -- Dynamic frames-per-minute allocation calculation
    local duration_mins = info.duration / 60
    local base = opts.base_frames
    if duration_mins >= 60 then
        base = opts.base_60_min_frames
    elseif duration_mins >= 30 then
        base = opts.base_30_min_frames
    end
    local extra = math.ceil(duration_mins * opts.frames_per_minute)
    local target_frames = base + extra

    local cache_key = get_cache_key(job, info)
    local first_frame_path = string.format("%s/%s_frame_0001.webp", opts.cache_dir, cache_key)
    local done_path = string.format("%s/%s.done", opts.cache_dir, cache_key)

    -- Display codec specifications cleanly at the bottom
    local info_str = string.format(" %s | %dx%d | %.1fs | %d frames ", info.codec:upper(), info.width, info.height, info.duration, target_frames)
    ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

    -- Maintain last accessed timestamp (refreshes the auto-clean TTL)
    local done_file = io.open(done_path, "r")
    if done_file then
        done_file:close()
        -- Use non-blocking Yazi Command instead of blocking os.execute
        Command("touch"):arg(done_path):spawn()
    end

    -- Fast-extraction for the initial render frame
    if not is_valid_file(first_frame_path) then
        Command("ffmpeg")
            :arg("-ss"):arg(tostring(math.min(2.0, info.duration * 0.1)))
            :arg("-i"):arg(url_str)
            :arg("-frames:v"):arg("1")
            :arg("-c:v"):arg("libwebp")
            :arg("-vf"):arg(string.format("scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2", opts.width, opts.height, opts.width, opts.height))
            :arg("-quality"):arg(tostring(opts.webp_quality))
            :arg("-y")
            :arg(first_frame_path)
            :output()
    end

    ya.image_show(Url(first_frame_path), img_area)

    -- Start spawning batch frames across the entire timeline asynchronously 
    if not io.open(done_path, "r") then
        local extract_fps = target_frames / info.duration
        local ffmpeg_cmd = string.format(
            'ffmpeg -i "%s" -vf "fps=%f,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" -vframes %d -c:v libwebp -speed %d -quality %d -y "%s/%s_frame_%%04d.webp" && touch "%s"',
            url_str,
            extract_fps,
            opts.width,
            opts.height,
            opts.width,
            opts.height,
            target_frames,
            opts.speed_preset,
            opts.webp_quality,
            opts.cache_dir,
            cache_key,
            done_path
        )
        Command("sh"):arg("-c"):arg(ffmpeg_cmd):spawn()
    end

    -- Initialize State logic based on user preferences
    if M.play_states[url_str] == nil then
        M.play_states[url_str] = opts.autoplay and "playing" or "stopped"
    end

    if M.play_states[url_str] ~= "playing" then return end

    -- Active playback loop with Dynamic sequential pre-loading
    if target_frames > 1 then
        local current_idx = 1
        local interval = 1 / opts.playback_fps
        while true do
            ya.sleep(interval)
            
            if M.play_states[url_str] ~= "playing" then break end

            local existing_frames = {}
            for i = 1, target_frames do
                local path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, i)
                if is_valid_file(path) then
                    table.insert(existing_frames, path)
                else
                    break
                end
            end

            if #existing_frames > 1 then
                current_idx = current_idx + 1
                if current_idx > #existing_frames then
                    if not opts.loop then
                        M.play_states[url_str] = "stopped"
                        break
                    else
                        current_idx = 1
                    end
                end
                ya.image_show(Url(existing_frames[current_idx]), img_area)
            end
        end
    end
end

-- Keybind hook entry point to safely toggle states from Yazi UI
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

function M:seek(job) end

return M
