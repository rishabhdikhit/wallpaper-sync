import Cocoa
import AVFoundation
import AVKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

// ──────────────────────────────────────────────────────────────────────
//  Window level: sit BELOW desktop icons and widgets, ABOVE the static wallpaper.
// ──────────────────────────────────────────────────────────────────────
let kDesktopIconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
let kDefaultWallpaperLevel: Int = kDesktopIconLevel - 1

final class WallpaperWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WallpaperEngine: NSObject {
    private var windows: [NSWindow] = []
    private var players: [AVQueuePlayer] = []
    private var loopers: [AVPlayerLooper] = []
    private var currentVideoPath: String
    private let fillMode: AVLayerVideoGravity
    private let pauseOnBattery: Bool
    private let pauseOnLowPower: Bool
    private var powerSavingMode: Bool
    private let sanityMode: Bool
    private let windowLevel: Int
    private let configPath: String
    private var isPaused = false
    private var windowVisible: [Bool] = []   // per-window: is the wallpaper actually on screen?
    private var occlusionWork: [DispatchWorkItem?] = []  // per-window debounce for occlusion flapping
    private var configSource: DispatchSourceFileSystemObject?
    private var configFD: Int32 = -1
    private var configFallbackTimer: Timer?
    private var logRotateTimer: Timer?
    private var isShuttingDown = false
    private var aerialNeedsRefresh = false
    private var sleepStartedAt: Date?
    private static let longSleepThreshold: TimeInterval = 120  // 2 minutes

    init(videoPath: String, fillMode: AVLayerVideoGravity, pauseOnBattery: Bool,
         pauseOnLowPower: Bool, powerSavingMode: Bool, sanityMode: Bool, windowLevel: Int, configPath: String) {
        self.currentVideoPath = videoPath
        self.fillMode = fillMode
        self.pauseOnBattery = pauseOnBattery
        self.pauseOnLowPower = pauseOnLowPower
        self.powerSavingMode = powerSavingMode
        self.sanityMode = sanityMode
        self.windowLevel = windowLevel
        self.configPath = configPath
        super.init()
    }

    func start() {
        rebuildWindows()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(powerStateChanged),
                       name: NSNotification.Name.NSProcessInfoPowerStateDidChange, object: nil)
        // Occlusion — pause a display's video when its wallpaper is fully covered
        // (fullscreen app / maximized window). Decoding hidden pixels wastes CPU/GPU.
        nc.addObserver(self, selector: #selector(occlusionChanged(_:)),
                       name: NSWindow.didChangeOcclusionStateNotification, object: nil)

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(displaySleep),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayWake),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)

        // Lock/unlock — hide our window so the native lock screen aerial plays
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(screenLocked),
                        name: NSNotification.Name("com.apple.screenIsLocked"), object: nil)
        dnc.addObserver(self, selector: #selector(screenUnlocked),
                        name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil)

        applyPowerPolicy()

        // Signal handling
        let sigTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigTerm.setEventHandler { [weak self] in self?.shutdown() }
        sigTerm.resume()
        let sigInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigInt.setEventHandler { [weak self] in self?.shutdown() }
        sigInt.resume()
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)

        // FSEvents watcher — no 2x/s polling
        startConfigWatcher()

        // Log rotation every 5 min (rotates only if it exceeds 1 MB)
        logRotateTimer = Timer.scheduledTimer(timeInterval: 300.0, target: self,
                                              selector: #selector(rotateLogIfNeeded),
                                              userInfo: nil, repeats: true)
        rotateLogIfNeeded()

        if sanityMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in self?.shutdown() }
        }
    }

    // MARK: - Log rotation

    private var logFilePath: String {
        return (configPath as NSString).deletingLastPathComponent + "/logs/engine.log"
    }

    @objc private func rotateLogIfNeeded() {
        let path = logFilePath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.uint64Value,
              size > 1_048_576 else { return }

        let oldPath = path + ".1"
        try? FileManager.default.removeItem(atPath: oldPath)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: oldPath)
        } catch {
            return
        }

        // Reopen fd 1 and fd 2 against the new file. The old descriptors keep
        // pointing at the renamed inode (.1) until dup2() replaces them.
        let newFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if newFD >= 0 {
            dup2(newFD, fileno(stdout))
            dup2(newFD, fileno(stderr))
            close(newFD)
            log("log rotated -> \(oldPath)")
        }
    }

    // MARK: - Config hot-reload (FSEvents)

    private func startConfigWatcher() {
        if isShuttingDown { return }

        let fd = open(configPath, O_EVTONLY)
        guard fd >= 0 else {
            log("config watcher: open failed (errno \(errno)), polling every 2s")
            if configFallbackTimer == nil {
                configFallbackTimer = Timer.scheduledTimer(timeInterval: 2.0, target: self,
                                                          selector: #selector(checkConfig),
                                                          userInfo: nil, repeats: true)
            }
            return
        }
        configFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )

        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let src = source else { return }
            let events = src.data
            self.checkConfig()
            if events.contains(.delete) || events.contains(.rename) {
                // Atomic replace (mv/replace): cancel and reopen against the new inode
                src.cancel()
            }
        }
        source.setCancelHandler { [weak self] in
            close(fd)
            guard let self = self, !self.isShuttingDown else { return }
            self.configFD = -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.startConfigWatcher()
                self?.checkConfig()
            }
        }

        configSource = source
        source.resume()
    }

    // MARK: - Config hot-reload

    @objc private func checkConfig() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        var changedVideo = false
        if let newVideo = json["video"] as? String,
           !newVideo.isEmpty,
           newVideo != currentVideoPath,
           FileManager.default.fileExists(atPath: newVideo) {
            currentVideoPath = newVideo
            changedVideo = true
        }

        let newPowerSave = json["powerSavingMode"] as? Bool ?? false
        let changedPowerSave = newPowerSave != powerSavingMode
        if changedPowerSave {
            powerSavingMode = newPowerSave
        }

        if changedVideo {
            log("config changed: \(currentVideoPath)")
            aerialNeedsRefresh = true
            DispatchQueue.main.async { [weak self] in self?.rebuildWindows() }
        } else if changedPowerSave {
            log("power saving mode changed: \(powerSavingMode)")
            DispatchQueue.main.async { [weak self] in self?.applyPowerPolicy() }
        }
    }

    // MARK: - Window management

    private func rebuildWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        players.removeAll()
        loopers.removeAll()

        let effectiveLevel = NSWindow.Level(rawValue: windowLevel)
        let videoURL = URL(fileURLWithPath: currentVideoPath)
        log("screens=\(NSScreen.screens.count) level=\(windowLevel)")

        for screen in NSScreen.screens {
            let frame: NSRect
            if sanityMode {
                let w: CGFloat = 320, h: CGFloat = 180, pad: CGFloat = 24
                frame = NSRect(x: screen.frame.maxX - w - pad,
                               y: screen.frame.maxY - h - pad - 40,
                               width: w, height: h)
            } else {
                frame = screen.frame
            }

            let window = WallpaperWindow(contentRect: frame, styleMask: .borderless,
                                          backing: .buffered, defer: false, screen: screen)
            window.level = effectiveLevel
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
            window.isOpaque = true
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.backgroundColor = .black
            window.isReleasedWhenClosed = false
            window.canHide = false

            // Each screen gets its own player + looper + item
            let asset = AVURLAsset(url: videoURL)
            let item = AVPlayerItem(asset: asset)
            let player = AVQueuePlayer()
            player.isMuted = true
            player.actionAtItemEnd = .none
            // true (default) lets AVPlayer wait for the buffer before playing.
            // It was previously false, which caused play() after execv (post
            // long-sleep wake) to run with the asset unloaded, leaving the
            // player stalled showing only the first frame.
            player.automaticallyWaitsToMinimizeStalling = true
            if #available(macOS 10.12, *) {
                player.preventsDisplaySleepDuringVideoPlayback = false
            }
            let looper = AVPlayerLooper(player: player, templateItem: item)

            let layer = AVPlayerLayer(player: player)
            layer.frame = CGRect(origin: .zero, size: frame.size)
            layer.videoGravity = fillMode
            layer.backgroundColor = NSColor.black.cgColor
            layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

            let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            view.layer = layer
            window.contentView = view

            window.orderFront(nil)
            player.play()

            windows.append(window)
            players.append(player)
            loopers.append(looper)
        }
        // Freshly ordered-front windows start visible; occlusion notifications correct this.
        windowVisible = Array(repeating: true, count: windows.count)
        occlusionWork.forEach { $0?.cancel() }
        occlusionWork = Array(repeating: nil, count: windows.count)
    }

    // MARK: - Lifecycle

    private func shutdown() {
        isShuttingDown = true
        configFallbackTimer?.invalidate(); configFallbackTimer = nil
        logRotateTimer?.invalidate(); logRotateTimer = nil
        configSource?.cancel(); configSource = nil
        players.forEach { $0.pause() }
        windows.forEach { $0.orderOut(nil) }
        NSApp.terminate(nil)
    }

    @objc private func screensChanged() { rebuildWindows(); applyPowerPolicy() }

    @objc private func screenLocked() {
        log("screen locked — pausing and hiding")
        players.forEach { $0.pause() }
        windows.forEach { $0.orderOut(nil) }

        // Only recycle the aerial if the video changed since the last lock —
        // avoids restarting the extension every time you lock the screen.
        guard aerialNeedsRefresh else { return }
        aerialNeedsRefresh = false
        DispatchQueue.global(qos: .background).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            proc.arguments = ["WallpaperAerialsExtension"]
            try? proc.run()
            proc.waitUntilExit()
            log("killed WallpaperAerialsExtension for fresh lock screen")
        }
    }

    @objc private func screenUnlocked() {
        log("screen unlocked — resuming")
        if !isPaused { players.forEach { $0.play() } }
        windows.forEach { $0.orderFront(nil) }
    }

    @objc private func displaySleep() {
        log("display sleep — pausing and hiding")
        sleepStartedAt = Date()
        players.forEach { $0.pause() }
        windows.forEach { $0.orderOut(nil) }
    }

    @objc private func displayWake() {
        let elapsed = sleepStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        sleepStartedAt = nil
        log("display wake (slept \(Int(elapsed))s)")

        // On long sleeps macOS tears down the GPU and the AVFoundation
        // session. Recycling AVPlayer/AVPlayerLayer within the same process
        // doesn't recover the surface — the user sees black even if the
        // rebuild "works". The only reliable way is execv: have the process
        // replace itself with a fresh instance of itself, same PID
        // (engine.pid stays valid), all AppKit/AVFoundation/GPU state
        // initialized from scratch.
        if elapsed > Self.longSleepThreshold {
            log("long sleep — execv self to reset AVFoundation/GPU state")
            // Defer a moment so the log flushes before the exec.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.execSelf()
            }
            return
        }

        // Short sleeps: the surface is still alive, so showing and resuming
        // is enough. The window level (below the lock screen) makes
        // orderFront safe even if it's still locked.
        windows.forEach { $0.orderFront(nil) }
        if !isPaused { players.forEach { $0.play() } }
    }

    private func execSelf() {
        let argv = CommandLine.arguments
        guard let exe = argv.first else {
            log("execSelf: no executable path — fallback rebuild")
            rebuildWindows(); applyPowerPolicy(); return
        }
        // Build argv as a C-string array, NULL-terminated.
        let cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        cArgs.withUnsafeBufferPointer { buf in
            _ = execv(exe, UnsafeMutablePointer(mutating: buf.baseAddress))
        }
        // If we reach here, execv failed.
        log("execv failed (errno=\(errno)) — fallback to in-process rebuild")
        rebuildWindows(); applyPowerPolicy()
    }

    @objc private func powerStateChanged() { applyPowerPolicy() }

    // MARK: - Occlusion

    @objc private func occlusionChanged(_ note: Notification) {
        guard let win = note.object as? NSWindow,
              let idx = windows.firstIndex(where: { $0 === win }) else { return }
        // occlusionState can flap rapidly during window/Space transitions. Debounce:
        // only act once it's held steady ~0.4s, so we don't thrash the player.
        guard idx < occlusionWork.count else { return }
        occlusionWork[idx]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, idx < self.windows.count, idx < self.windowVisible.count else { return }
            let visible = self.windows[idx].occlusionState.contains(.visible)
            guard self.windowVisible[idx] != visible else { return }  // settled change only
            self.windowVisible[idx] = visible
            log("occlusion: window[\(idx)] visible=\(visible)")
            if !self.isPaused && visible { self.players[idx].play() } else { self.players[idx].pause() }
        }
        occlusionWork[idx] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Single source of truth: a player runs iff power policy allows and its window is visible.
    private func refreshAllPlayback() {
        for (i, player) in players.enumerated() {
            let visible = i < windowVisible.count ? windowVisible[i] : true
            if !isPaused && visible { player.play() } else { player.pause() }
        }
    }

    // MARK: - Power

    private func isOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for src in sources {
            if let desc = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
               let state = desc[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }

    private func applyPowerPolicy() {
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let battery = isOnBattery()
        let shouldPause = powerSavingMode || (pauseOnLowPower && lowPower) || (pauseOnBattery && battery)
        log("power: lowPower=\(lowPower) battery=\(battery) powerSave=\(powerSavingMode) shouldPause=\(shouldPause)")
        isPaused = shouldPause
        refreshAllPlayback()   // respects per-window occlusion, not a blanket play/pause
    }
}

// MARK: - Logging

func log(_ msg: String) {
    FileHandle.standardError.write("[engine] \(msg)\n".data(using: .utf8)!)
}

// MARK: - Config

struct Config {
    var video: String
    var fill: String
    var pauseOnBattery: Bool
    var pauseOnLowPower: Bool
    var powerSavingMode: Bool
}

func loadConfig(path: String) -> Config {
    var cfg = Config(video: "", fill: "fill", pauseOnBattery: false, pauseOnLowPower: false, powerSavingMode: false)
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return cfg }
    if let v = obj["video"] as? String { cfg.video = v }
    if let f = obj["fill"] as? String { cfg.fill = f }
    if let b = obj["pauseOnBattery"] as? Bool { cfg.pauseOnBattery = b }
    if let l = obj["pauseOnLowPower"] as? Bool { cfg.pauseOnLowPower = l }
    if let p = obj["powerSavingMode"] as? Bool { cfg.powerSavingMode = p }
    return cfg
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write("usage: WallpaperEngine <config.json> [--sanity]\n".data(using: .utf8)!)
    exit(2)
}
let sanity = args.contains("--sanity")
var parsedLevel: Int? = nil
if sanity, let i = args.firstIndex(of: "--level"), i + 1 < args.count, let v = Int(args[i + 1]) {
    parsedLevel = v
}
let effectiveLevel = parsedLevel ?? kDefaultWallpaperLevel
let cfg = loadConfig(path: args[1])

guard !cfg.video.isEmpty, FileManager.default.fileExists(atPath: cfg.video) else {
    FileHandle.standardError.write("video not found: \(cfg.video)\n".data(using: .utf8)!)
    exit(3)
}

let gravity: AVLayerVideoGravity = {
    switch cfg.fill {
    case "fit": return .resizeAspect
    case "stretch": return .resize
    default: return .resizeAspectFill
    }
}()

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let engine = WallpaperEngine(
    videoPath: cfg.video,
    fillMode: gravity,
    pauseOnBattery: cfg.pauseOnBattery,
    pauseOnLowPower: cfg.pauseOnLowPower,
    powerSavingMode: cfg.powerSavingMode,
    sanityMode: sanity,
    windowLevel: effectiveLevel,
    configPath: args[1]
)
engine.start()
app.run()
