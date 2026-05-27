## ✅ Keybinding Verification: `M-p` and `M-o`

I verified that `M-p` (`Alt+p`) and `M-o` (`Alt+o`) are **not used** in Yazi's default keymap file at `yazi-config/preset/keymap-default.toml`. A subsequent check of the wider Yazi plugin ecosystem returned no known plugins using these bindings either. This makes them a safe choice and avoids overwriting any defaults or built-in plugin defaults.

---

## 📝 Updated `README.md` with Shoutout

````markdown
# 🎬 Video Thumb Reel Preview for Yazi

Generate **animated WebP thumb reels** for video files directly in Yazi. Quickly scan video contents without playing the full file.

- 🎞️ **Single animated preview** – one cached WebP file per video
- ⚡ **Fast & efficient** – ffmpeg optimized for speed
- 📈 **Smart frame allocation** – fixed minimum frames + extra frames for longer videos
- 🖼️ **High‑DPI aware** – configurable preview dimensions
- 🔁 **Auto‑cached** – MD5 hashed, regenerates only when video or settings change
- 📦 **Batch pre‑caching** – generate WebPs ahead of time for entire directories
- 🗜️ **Cache optimization** – re‑encode cached WebPs to shrink file sizes

## 🙏 Credits & Inspiration

This plugin was heavily inspired by **nbaud's [yazi-video-timeline](https://github.com/nbaud/yazi-video-timeline)** — a fantastic timeline previewer that demonstrates how powerful Yazi's plugin system can be. We extended the idea to generate **animated WebP reels** with dynamic frame allocation, built‑in caching, and on‑demand optimisation commands, while keeping performance as tight as possible.

## 📦 Installation

### Using yazi‑plugin manager (recommended)

```bash
ya pkg add PhorestsDownStream/video-thumbreel-preview
```
````

### Manual install

```bash
git clone https://github.com/PhorestsDownStream/video-thumbreel-preview.git ~/.config/yazi/plugins/video-thumbreel-preview.yazi
```

### Enable the previewer

Add to `~/.config/yazi/yazi.toml`:

```toml
[plugin]
prepend_previewers = [
  { mime = "video/*", run = "video-thumbreel-preview" },
]
```

### Keybindings (add to `~/.config/yazi/keymap.toml`)

```toml
[[manager.preview]]
key = "M-p"
run = "plugin video-thumbreel-preview precache"

[[manager.preview]]
key = "M-o"
run = "plugin video-thumbreel-preview optimize"
```

> 💡 These keys are verified unused in Yazi's default keymap.

## ⚙️ Configuration

Add to your `~/.config/yazi/init.lua`:

```lua
require("video-thumbreel-preview"):setup({
    min_frames = 40,          -- minimum frames for short videos
    frames_per_minute = 2,    -- additional frames per minute of duration
    fps_rate = 3,             -- animation playback speed (fps)
    webp_quality = 40,        -- WebP quality (0-100, lower = faster)
    width = 640,              -- preview width (pixels)
    height = 360,             -- preview height (pixels)
    meta_lines = 14,          -- lines reserved for video metadata
})
```

### Recommended values for different use cases

| Use case                 | `min_frames` | `frames_per_minute` | Notes                      |
| ------------------------ | ------------ | ------------------- | -------------------------- |
| Quick scanning (default) | 40           | 2                   | Balanced                   |
| Very fast, low CPU       | 20           | 1                   | Fewer frames, lighter      |
| Detailed preview         | 60           | 4                   | More frames, slower encode |

## 🚀 Usage

### Automatic preview

Hover over any video file in Yazi. The plugin will:

1. Compute video duration.
2. Calculate frame count = `max(min_frames, duration_minutes * frames_per_minute)`.
3. Sample evenly spaced frames using ffmpeg.
4. Generate an animated WebP preview.
5. Cache the result for future previews.

### Batch pre‑caching – `Alt+p`

Select one or more video files and press `Alt+p` to pre‑generate their animated WebP thumbnails in the background. This is ideal before browsing a large media directory — previews will appear instantly later.

- Works on current selection; shows progress notification
- Uses the same ffmpeg settings as automatic preview
- Cached WebPs land in `~/.cache/yazi-video-thumbreel/`

### Cache optimization – `Alt+o`

Press `Alt+o` anytime to re‑encode all existing cached WebP files with maximum compression. The optimized copies are saved to `~/.cache/yazi-video-thumbreel_optimized/` — you can then replace the original cache if you prefer smaller files.

- Compression level 6 (max) and configurable quality
- Non‑destructive: original cache remains untouched
- Useful after accumulating many previews

## 🧠 How it works

- **Frame allocation** – short videos get exactly `min_frames` frames. Longer videos get additional frames proportional to length (`duration_minutes * frames_per_minute`). No upper limit – you control density via `frames_per_minute`.
- **Sampling** – `ffmpeg` uses the `fps` filter with `num_frames / duration` to extract exact frames.
- **Caching** – each video+settings combination is hashed (MD5 of file stats + dimensions + frame count + quality). Cached WebPs are stored in `~/.cache/yazi-video-thumbreel/`.
- **Batch pre‑caching** – spawns the same preview pipeline for each selected file, populating the cache without displaying anything.
- **Cache optimization** – iterates over every `.webp` in the cache directory and re‑encodes with higher compression.

## 🛠️ Dependencies

- [ffmpeg](https://ffmpeg.org/) – video decoding and WebP encoding
- `bc` or `awk` – floating‑point calculation (usually pre‑installed on Linux/macOS)

Install ffmpeg:

```bash
# Ubuntu/Debian
sudo apt install ffmpeg

# macOS
brew install ffmpeg

# Arch
sudo pacman -S ffmpeg
```

## 🤝 Contributing

Issues and pull requests welcome! Please test your changes with multiple video formats (mp4, mkv, avi, mov, webm).

## 📄 License

MIT © PhorestsDownStream

## 🙏 Acknowledgements

- [Yazi](https://github.com/sxyazi/yazi) – blazing fast terminal file manager
- [ffmpeg](https://ffmpeg.org/) – multimedia framework
- [nbaud](https://github.com/nbaud) – inspiration from [yazi-video-timeline](https://github.com/nbaud/yazi-video-timeline)

```

```
