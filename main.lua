--- @since 25.2.7
local M = {}

-- default settings
local opts = {
	frames = 40, -- number of webp frames to extract
	fps = 1, -- frames per second used during extraction
	autoplay = true, -- start animation on hover
	frame_density = nil, -- ratio for dynamic frame count (overrides frames if set)
	-- expose ffmpeg quality/speed presets here:
	ffmpeg_preset = "fast",
	webp_quality = 80,
	-- ... other relevant ffmpeg settings
	cache_ttl_days = 30, -- auto-clean sequences older than this many days
	playback_fps = 12, -- framerate for the preview playback animation
	cache_dir = os.getenv("HOME") .. "/yazi-video-thumbreel",
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
	-- We delete the .done file and all corresponding _frame_*.webp files.
	local cmd = string.format(
		[[
        find "%s" -name "*.done" -type f -mtime +%d -print0 2>/dev/null |
        while IFS= read -r -d '' file; do
            base="${file%%.done}"
            rm -f "$base"*
        done
    ]],
		opts.cache_dir,
		opts.cache_ttl_days
	)

	Command("sh"):arg("-c"):arg(cmd):spawn()
end

local video_extensions = {
	mp4 = true,
	mkv = true,
	avi = true,
	mov = true,
	wmv = true,
	flv = true,
	webm = true,
	m4v = true,
	mpg = true,
	mpeg = true,
	["3gp"] = true,
	ogv = true,
	ts = true,
	m2ts = true,
}

local function is_video_file(url_str)
	local ext = url_str:match("%.([^%.]+)$")
	return ext and video_extensions[ext:lower()] == true
end

-- Extracts duration, resolution, and codec using ffprobe
local function get_media_info(url_str)
	local cmd = Command("ffprobe")
		:arg("-v")
		:arg("error")
		:arg("-select_streams")
		:arg("v:0")
		:arg("-show_entries")
		:arg("stream=codec_name,width,height:format=duration")
		:arg("-of")
		:arg("default=noprint_wrappers=1:nokey=1")
		:arg(url_str)

	local output = cmd:output()
	if not output or not output.stdout then
		return nil
	end

	local lines = {}
	for line in output.stdout:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	if #lines >= 4 then
		return {
			codec = lines[1],
			width = tonumber(lines[2]) or 0,
			height = tonumber(lines[3]) or 0,
			duration = tonumber(lines[4]) or 0,
		}
	elseif #lines >= 1 then
		return { codec = "unknown", width = 0, height = 0, duration = tonumber(lines[1]) or 0 }
	end
	return nil
end

-- Deduplication: Hash of basename + media info. Moving the file won't trigger regen.
local function get_cache_key(job, info)
	local basename = job.file.name or tostring(job.file.url):match("([^/]+)$")
	local hash_input = string.format(
		"%s|%s|%dx%d|%.2f|%s|%s|%s",
		basename,
		info.codec,
		info.width,
		info.height,
		info.duration,
		opts.frames,
		opts.fps,
		opts.webp_quality
	)

	local hash = 0
	for i = 1, #hash_input do
		hash = (hash * 31 + hash_input:byte(i)) % (2 ^ 32)
	end
	return string.format("%08x", hash)
end

function M:peek(job)
	local url_str = tostring(job.file.url)
	if not is_video_file(url_str) then
		return
	end

	local info = get_media_info(url_str)
	if not info or info.duration == 0 then
		return
	end

	-- Layout calculation
	local img_area = ui.Rect({ x = job.area.x, y = job.area.y, w = job.area.w, h = math.max(1, job.area.h - 1) })
	local txt_area = ui.Rect({ x = job.area.x, y = job.area.y + job.area.h - 1, w = job.area.w, h = 1 })

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
	-- FIXED: Using singular "preview_widget" here
	ya.preview_widget(job, { ui.Text(info_str):area(txt_area) })

	-- Touch .done file to keep it alive (cache auto-clean)
	local done_file = io.open(done_path, "r")
	if done_file then
		done_file:close()
		os.execute(string.format('touch "%s"', done_path))
	end

	-- Generate first frame quickly if missing
	if not io.open(first_frame_path, "r") then
		Command("ffmpeg")
			:arg("-ss")
			:arg(tostring(math.min(2.0, info.duration * 0.1))) -- Skip initial black frames safely
			:arg("-i")
			:arg(url_str)
			:arg("-frames:v")
			:arg("1")
			:arg("-c:v")
			:arg("libwebp")
			:arg("-vf")
			:arg("scale='min(640,iw)':-2")
			:arg("-quality")
			:arg(tostring(opts.webp_quality))
			:arg("-y")
			:arg(first_frame_path)
			:output()
	end

	ya.image_show(Url(first_frame_path), img_area)

	-- Background frame generation using -vf fps filter
	if not io.open(done_path, "r") then
		local extraction_cmd = Command("ffmpeg")
			:arg("-i")
			:arg(url_str)
			:arg("-vf")
			:arg(string.format("fps=%s,scale='min(640,iw)':-2", opts.fps))
			:arg("-vframes")
			:arg(tostring(target_frames))
			:arg("-c:v")
			:arg("libwebp")
			:arg("-preset")
			:arg(opts.ffmpeg_preset)
			:arg("-quality")
			:arg(tostring(opts.webp_quality))
			:arg("-y")
			:arg(string.format("%s/%s_frame_%%04d.webp", opts.cache_dir, cache_key))

		extraction_cmd:output()
		os.execute(string.format('touch "%s"', done_path))
	end

	-- Hook: Autoplay handling
	if not opts.autoplay then
		return
	end

	-- Playback Animation (No jitter: sequentially load and display valid existing frames)
	if target_frames > 1 then
		local current_frame = 1
		local interval = 1 / opts.playback_fps
		while true do
			ya.sleep(interval)
			current_frame = (current_frame % target_frames) + 1
			local frame_path = string.format("%s/%s_frame_%04d.webp", opts.cache_dir, cache_key, current_frame)

			local f = io.open(frame_path, "r")
			if f then
				f:close()
				ya.image_show(Url(frame_path), img_area)
			else
				current_frame = 0 -- Reset loop gracefully if we hit the end of actual generated frames
			end
		end
	end
end

-- New utility entries
function M:entry(job)
	local args = job.args or {}
	local action = args[1]

	if action == "prebatch" then
		-- Temporarily drops user into a terminal to select a folder using built-in fzf,
		-- then performs a batch extraction in the background.
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
		-- Runs mogrify to re-compress the webp frames footprint inside the cache
		local script = string.format(
			[[
            echo "Optimizing Yazi video thumbreel cache in %s..."
            find "%s" -name "*.webp" -exec mogrify -quality %d {} +
            echo "Optimization complete!"
            sleep 2
        ]],
			opts.cache_dir,
			opts.cache_dir,
			math.max(10, opts.webp_quality - 15)
		)
		ya.manager_emit("shell", { script, block = true, confirm = true })
	end
end

function M:seek(job) end

return M
