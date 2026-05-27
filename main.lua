--- @since 25.2.7
local M = {}

-- default settings
local opts = {
    frames = 40,          -- number of webp frames to extract
    fps = 1,              -- frames per second used during extraction (fallback)
    autoplay = true,      -- start animation on hover
    frame_density = nil,  -- ratio for dynamic frame count (overrides frames if set)
    ffmpeg_preset = "fast",
    webp_quality = 80,
    cache_ttl_days = 30,  -- auto-clean sequences older than this many days
    playback_fps = 12,    -- framerate for the preview playback animation
    cache_dir = os.getenv("HOME") .. "/yazi-video-thumbreel",
    width = 640,
    height = 360,
}

function M:setup(user_opts)
    if user_opts then
        for k, v in pairs(user_opts) do
            opts[k] = v
        end
    end
    
    os.execute('mkdir -p "' .. opts.cache_dir .. '"')
    self:auto_clean()
end

function M:auto_clean()
    -- Smart Cache Auto-Clean: Deletes sequences whose .done file hasn't been modified in N days.
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

-- Safely verify that a frame file exists and is completely written
local function is_valid_file(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local size = f:seek("end")
    f:close()
    return size and size > 100 -- Standard WebP file headers are > 100 bytes
end

-- Extracts duration, resolution, and codec using ffprobe
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

-- Deduplication: Hash of basename + media info. Moving the file won't trigger regen.
local function get_cache_key(job, info)
    local basename = job.file.name or tostring(job.file.url):match("([^/]+)$")
    local hash_input = string.format("%s|%s|%dx%d|%.2f|%s|%s|%s",
        basename, info.codec, info.width, info.height, info.duration,
        opts.frames, opts.fps, opts.webp_quality
    )
    
    local hash = 0
    for i = 1, #hash_input do
        hash = (hash * 31 + hash_input:byte(i)) % (2^32)
    end
    return string.format("%08x", hash)
end

function M:peek(job)
    local url_str = tostring(job.file.url)
    if not is_video_file(url_str) then return end

    local info = get_media_info(url_str)
    if not info or info.duration == 0 then return end

    -- Layout calculation
    local img_area = ui.Rect { x = job.area.x, y = job.area.y, w = job.area.w, h = math.max(1, job.area.h - 1) }
    local txt_area = ui.Rect { x = job.area.x, y = job.area.y + job.area.h - 1, w = job.area.w, h = 1 }

    -- Dynamic frame count calculation
    local target_frames = opts.frames
    if opts.frame_density then
        target_frames = math.max(1, math.floor(info.duration * opts.frame_density))
    end

    local cache_key = get_cache_key(job, info)
    local first_frame_path = string.format("%s/%s_frame_0001.webp", opts.cache_dir, cache_key)
    local done_path = string.format("%s/%s.done", opts.cache_dir, cache_key)

    -- Show text below image (codec, resolution, duration)
    local info_str = string.format(" %s | %dx%d | %.1fs ", info.codec:upper(), info.width, info.height, info.duration)
    ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

    -- Touch .done file to keep it alive (cache auto-clean)
    local done_file = io.open(done_path, "r")
    if done_file then
        done_file:close()
        os.execute(string.format('touch "%s"', done_path))
    end

    -- Generate first frame quickly if missing (extracts exactly 1 frame instantly)
    if not is_valid_file(first_frame_path) then
        Command("ffmpeg")
            :arg("-ss"):arg(tostring(math.min(2.0, info.duration * 0.1))) -- Skip initial black frames safely
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

    -- Background frame generation using select filter to span the entire video cleanly
    if not io.open(done_path, "r") then
        local interval_sec = info.duration / target_frames
        local ffmpeg_cmd = string.format(
            'ffmpeg -i "%s" -vf "select=\'isnan(prev_selected_t)+gte(t-prev_selected_t,%f)\',scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2" -vframes %d -c:v libwebp -preset %s -quality %d -y "%s/%s_frame_%%04d.webp" && touch "%s"',
            url_str,
            interval_sec,
            opts.width,
            opts.height,
            opts.width,
            opts.height,
            target_frames,
            opts.ffmpeg_preset,
            opts.webp_quality,
            opts.cache_dir,
            cache_key,
            done_path
        )
        -- Spawn completely in the background so Yazi UI never hangs!
        Command("sh"):arg("-c"):arg(ffmpeg_cmd):spawn()
    end

    -- Hook: Autoplay handling
    if not opts.autoplay then return end

    -- Playback Animation (Sequentially loads and displays only fully valid existing frames)
    if target_frames > 1 then
        local current_idx = 1
        local interval = 1 / opts.playback_fps
        while true do
            ya.sleep(interval)
            
            -- Assemble all fully written frames sequentially.
            -- This dynamically grows as the background ffmpeg process completes!
            local existing_frames = {}
            for i = 1, target_frames do
                local path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, i)
                if is_valid_file(path) then
                    table.insert(existing_frames, path)
                else
                    break -- Keep it sequential; don't skip frames to avoid dynamic jumps
                end
            end
            
            -- Only animate when we have at least 2 valid frames ready.
            -- This completely prevents the single-frame flashing/jitter!
            if #existing_frames > 1 then
                current_idx = (current_idx % #existing_frames) + 1
                ya.image_show(Url(existing_frames[current_idx]), img_area)
            end
        end
    end
end

-- Utility entries
function M:entry(job)
    local args = job.args or {}
    local action = args[1]
    
    if action == "prebatch" then
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
