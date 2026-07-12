# 🎬 Wally

> **Live animated video wallpapers for macOS — desktop and lock screen, tuned for near-zero CPU.**

Put an animated video on your desktop background **and/or** your lock/login screen, with HEVC hardware decoding and a native menu-bar UI. This build focuses hard on **resource efficiency**: the wallpaper stops decoding the moment nothing can see it.

[![macOS](https://img.shields.io/badge/macOS-Sonoma%20%7C%20Sequoia%20%7C%20Tahoe-blue)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-6-orange)](#)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

## Features

- 🖥️ **Animated desktop wallpaper** — video plays behind your icons and windows
- 🔒 **Lock screen wallpaper** — your video on the lock/login screen (see the macOS caveats below)
- 🧩 **Desktop / lock screen are independent** — same video on both, a *different* one on each, or only one
- 🪫 **Occlusion pause** — when a fullscreen app or maximized window fully covers a display, that display's video **stops decoding** (CPU → ~0%). Per-display, so covering one monitor doesn't stop the others.
- 🔋 **Battery smart** — auto-pause on battery and in Low Power Mode
- 🧊 **Power Save mode** — freeze on a single frame (0% CPU, GPU idle)
- 🎞️ **GIF support** — drop in a `.gif` (or `.mp4` / `.mov` / `.webm`); it's transcoded to HEVC once on import
- 🎨 **Native menu-bar UI** — no dock clutter; runs quietly in the background
- 🧹 **One-click uninstall** — stops the engine, restores your original lock screen, removes autostart, deletes app data, and moves the app to the Trash

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
│            └─ atomic copy over the ACTIVE aerial    │
└─────────────────────────────────────────────────────┘
```

- **WallpaperEngine** (Swift) — renders video in a borderless window at `desktopIconLevel − 1`, below icons and above the static wallpaper.
- **MenuApp** (Swift) — menu-bar GUI: library, import, settings, uninstall.
- **bin/wallpaper** (Bash) — CLI for every operation.
- **_set_lockscreen_video.py** (Python) — manages the macOS aerial-file replacement.

### Why the lock screen works this way (a macOS limitation)

macOS has **no API to set a custom video as your lock screen** — Apple only allows its own aerial/dynamic wallpapers there. The only way to show *your* video is to **overwrite the video file of an Apple "aerial"** that's currently your active screen saver. Consequences:

- Your lock screen must be a **video-backed Apple aerial** — a moving-landscape wallpaper with **"Show as Screen Saver"** on. Static images, the "Macintosh"/graphic screen savers, and other non-aerial picks **can't be used** — there's no video file to swap.
- Wally swaps the aerial macOS is **actually playing** (detected live via the open file handle), so it targets the right one even if you have several downloaded.

**Desktop and lock screen are independent** — that's the modular part:

- **Desktop** animated wallpaper is drawn by Wally's own engine (a window below your icons). It needs no aerial and works with **any** video.
- **Lock screen** uses the aerial-swap above.
- So you can mix them: desktop-only, lock-only, both, or even a **different** video on each — right-click a wallpaper → **Set as Desktop only / Set as Lock Screen only / Set as Desktop + Lock Screen**.

### ⚠️ Getting your original lock screen back

When Wally puts your video on the lock screen, it **overwrites the video file of the aerial you have active** (e.g. *Sequoia* or *Tahoe Day*) and saves a backup of the original.

- To restore Apple's original aerial, click **⚙️ → "Restore original lock screen"** — it copies the backup back.
- If you **don't** restore and just switch wallpapers in System Settings, that aerial's slot **keeps your video** — Apple's original stays overwritten until you Restore (or re-download the aerial). It's not gone forever, but it won't return on its own.
- **Uninstall** restores the original automatically.

**Rule of thumb:** swapped an aerial you care about? Hit **Restore original lock screen** before moving on, or that slot keeps playing your video.

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

# Build — compiles the binaries, assembles Wally.app, and installs it to /Applications
./install.sh

# Launch
open -a Wally
```

`install.sh` builds `Wally.app`, ad-hoc signs it, and deploys it to `/Applications` (so it shows up in Spotlight/Launchpad). It's a menu-bar app (`LSUIElement`), so it has **no Dock icon** — look for the 🎬 icon in the menu bar. On first launch you may see an "unidentified developer" prompt (the app isn't notarized) — right-click it in `/Applications` → **Open**, or allow it in **System Settings → Privacy & Security**.

### First-time lock-screen setup
1. Open **System Settings → Wallpaper** and set an animated ("aerial") **wallpaper** — a moving landscape (e.g. *Tahoe Day*).
2. Turn **ON "Show as Screen Saver"** in that same pane (this is what makes it swappable — see the macOS-limitation note above).
3. Import your videos in Wally and set one **as Lock Screen** (right-click the thumbnail).

## Usage

**GUI:** click the menu-bar icon to open the library. Click a thumbnail to activate it; right-click for **Desktop / Lock Screen / Both**. The ⚙️ settings popover has launch-at-login, engine on/off, battery pause, power save, **Sync / Restore lock screen**, and uninstall.

**CLI:**
```bash
wallpaper set <file>          # import + activate on desktop AND lock screen
wallpaper use <name>          # activate on desktop AND lock screen (instant)
wallpaper desktop <name>      # desktop only
wallpaper lockscreen [name]   # lock screen only (active wallpaper if no name)
wallpaper lockscreen-restore  # put the original Apple aerial back
wallpaper add <file>          # import without activating
wallpaper list                # list library (▶ = active)
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
- For lock-screen use: an aerial wallpaper set with **"Show as Screen Saver"** on (see the limitation note above)

## Credits

Fork of **[Wallpaper-Sync](https://github.com/GonzaloRojas14/Wallpaper-Sync)** by **Gonzalo Rojas** ([@gonza._007](https://instagram.com/gonza._007)), released under the MIT License. This fork (Wally) adds occlusion-based pausing, independent desktop/lock-screen targeting, active-aerial detection, an in-app uninstaller, an English UI, and a from-scratch `.app` build in `install.sh`. All original credit to Gonzalo — go star the upstream project.

## License

MIT — © 2026 Gonzalo Rojas. See [LICENSE](LICENSE).
