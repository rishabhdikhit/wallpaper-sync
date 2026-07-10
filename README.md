# 🎬 Wallpaper Sync

> **Live animated video wallpapers for macOS — synced to both desktop and lock screen, tuned for near-zero CPU.**

Put the *same* animated video on your desktop background **and** your lock/login screen, with HEVC hardware decoding and a native menu-bar UI. This build focuses hard on **resource efficiency**: the wallpaper stops decoding the moment nothing can see it.

[![macOS](https://img.shields.io/badge/macOS-Sonoma%20%7C%20Sequoia%20%7C%20Tahoe-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-orange)](#)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Features

- 🖥️ **Animated desktop wallpaper** — video plays behind your icons and windows
- 🔒 **Lock screen sync** — same video on your lock/login screen automatically
- 🪫 **Occlusion pause** — when a fullscreen app or maximized window fully covers a display, that display's video **stops decoding** (CPU → ~0%). Per-display, so covering one monitor doesn't stop the others.
- 🔋 **Battery smart** — auto-pause on battery and in Low Power Mode
- 🧊 **Power Save mode** — freeze on a single frame (0% CPU, GPU idle)
- 🎞️ **GIF support** — drop in a `.gif` (or `.mp4` / `.mov` / `.webm`); it's transcoded to HEVC once on import
- 🎨 **Native menu-bar UI** — no dock clutter; runs quietly in the background
- 🧹 **One-click uninstall** — a menu item that stops the engine, restores your original lock screen, removes autostart, deletes app data, and moves the app to the Trash

## How it works

```
┌─────────────────────────────────────────────────────┐
│  Your video (.mp4 / .mov / .gif / .webm)            │
│       │                                             │
│       ▼                                             │
│  ffmpeg → HEVC .mov (one-time conversion on import) │
│       │                                             │
│       ├──→ WallpaperEngine (desktop window)         │
│       │    └─ AVPlayer behind desktop icons         │
│       │    └─ pauses on: occlusion · battery ·      │
│       │       Low Power · sleep · lock · Power Save │
│       │                                             │
│       └──→ Aerial slot replacement (lock screen)    │
│            └─ atomic copy to system aerial file     │
└─────────────────────────────────────────────────────┘
```

- **WallpaperEngine** (Swift) — renders video in a borderless window at `desktopIconLevel − 1`, below icons and above the static wallpaper.
- **MenuApp** (Swift) — menu-bar GUI: library, import, Power Save toggle, uninstall.
- **bin/wallpaper** (Bash) — CLI for every operation.
- **_set_lockscreen_video.py** (Python) — manages the macOS aerial-file replacement.

### Why occlusion pause matters

Most live-wallpaper apps keep decoding video at full frame rate even when a maximized window or fullscreen app hides the desktop entirely — burning CPU/GPU on pixels nobody sees. This build listens to each window's `occlusionState` and pauses that display's player when it isn't visible, then resumes instantly when the desktop shows again.

## Install (build from source)

Requires only the **Command Line Tools** (`swiftc`) — no full Xcode.

```bash
# Clone
git clone https://github.com/rishabhdikhit/wallpaper-sync.git
cd wallpaper-sync

# Dependency (runtime, for video transcoding)
brew install ffmpeg

# Build — compiles the binaries AND assembles "Wallpaper Sync.app"
./install.sh

# Launch
open "Wallpaper Sync.app"
```

`install.sh` builds `Wallpaper Sync.app` from scratch and ad-hoc signs it so macOS will run it locally. On first launch you may still see an "unidentified developer" prompt (the app isn't notarized) — right-click the app → **Open**, or allow it in **System Settings → Privacy & Security**.

### First-time lock-screen setup
1. Open **System Settings → Wallpaper** and download an animated ("aerial") wallpaper (e.g. *Tahoe Day*).
2. Enable **"Show as Screen Saver."**
3. Import your videos in the app and pick one.

## Usage

**GUI:** click the menu-bar icon to open the library. Click a thumbnail to activate it. Right-click the icon for Power Save, Uninstall, and Quit.

**CLI:**
```bash
wallpaper set <file>          # import + activate (accepts .gif/.mp4/.mov/.webm)
wallpaper use <name>          # switch to a library wallpaper (instant)
wallpaper list                # list library (▶ = active)
wallpaper add <file>          # import without activating
wallpaper remove <name>       # delete from library
wallpaper start | stop        # control the engine
wallpaper battery on|off      # auto-pause on battery
wallpaper powersave on|off    # static-frame power save
wallpaper enable | disable    # login autostart
wallpaper uninstall           # stop, restore lock screen, delete app data
wallpaper status
```

## Requirements

- macOS Sonoma (14), Sequoia (15), or Tahoe (26)
- Apple Silicon or Intel Mac
- [ffmpeg](https://formulae.brew.sh/formula/ffmpeg) (`brew install ffmpeg`)
- One downloaded aerial wallpaper in System Settings (for lock-screen sync)

## Credits

Fork of **[Wallpaper-Sync](https://github.com/GonzaloRojas14/Wallpaper-Sync)** by **Gonzalo Rojas** ([@gonza._007](https://instagram.com/gonza._007)), released under the MIT License. This fork adds occlusion-based pausing, an in-app uninstaller, an English UI, and a from-scratch `.app` build in `install.sh`. All original credit to Gonzalo — go star the upstream project.

## License

MIT — © 2026 Gonzalo Rojas. See [LICENSE](LICENSE).
