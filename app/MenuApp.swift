import Cocoa
import AVFoundation
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Design Tokens
//
// Semantic, system-aware. They respect light/dark mode and the accent color
// chosen by the user in System Settings. Inspired by the macOS Tahoe HIG
// (Liquid Glass): translucency, deference to content, little saturated color
// in chrome.
struct Theme {
    static var accent: NSColor    { NSColor.controlAccentColor }
    static var cardBg: NSColor    { NSColor(name: nil) { $0.name == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 0, alpha: 0.04) } }
    static var cardHover: NSColor { NSColor(name: nil) { $0.name == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.07) } }
    static var textPri: NSColor   { NSColor.labelColor }
    static var textSec: NSColor   { NSColor.secondaryLabelColor }
    static var textTer: NSColor   { NSColor.tertiaryLabelColor }
    static let cardRadius: CGFloat = 16
    static let cardW: CGFloat = 240
    static let thumbH: CGFloat = 145
    static let gap: CGFloat = 18
    static let pad: CGFloat = 28
}

// MARK: - Thumbnail Cache
class ThumbCache {
    static let shared = ThumbCache()
    private var cache: [String: NSImage] = [:]

    func get(_ path: String, size: NSSize, completion: @escaping (NSImage) -> Void) {
        if let img = cache[path] { completion(img); return }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: size.width * 2, height: size.height * 2)
        let time = CMTime(seconds: 1.0, preferredTimescale: 600)
        // `gen` captured strongly so the request isn't cancelled when get() returns.
        gen.generateCGImageAsynchronously(for: time) { [weak self, gen] cgImg, _, _ in
            _ = gen
            guard let cgImg = cgImg else { return }
            let img = NSImage(cgImage: cgImg, size: size)
            DispatchQueue.main.async { self?.cache[path] = img; completion(img) }
        }
    }
}

// MARK: - Wallpaper Card
class WallpaperCard: NSView {
    let videoPath: String
    let videoName: String
    var isActive: Bool = false { didSet { updateActiveState() } }
    var isHovered: Bool = false { didSet { updateHoverState() } }
    var onClick: (() -> Void)?          // left-click = set on both surfaces
    var onSetDesktop: (() -> Void)?
    var onSetLock: (() -> Void)?
    var onDelete: (() -> Void)?
    var thumbHeight: CGFloat = Theme.thumbH

    private let thumbContainer = NSView()
    private let thumbView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let activePill = NSView()
    private let activeIcon = NSImageView()
    private let activeText = NSTextField(labelWithString: "Active")
    private var trackingArea: NSTrackingArea?

    init(path: String, name: String) {
        self.videoPath = path
        self.videoName = name
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.cardRadius
        layer?.masksToBounds = false  // shadow outside bounds
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        setupViews()
        loadThumb()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Thumbnail clipped to rounded corners
        thumbContainer.wantsLayer = true
        thumbContainer.layer?.cornerRadius = Theme.cardRadius
        thumbContainer.layer?.masksToBounds = true
        thumbContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor
        addSubview(thumbContainer)

        thumbView.imageScaling = .scaleProportionallyUpOrDown
        thumbView.wantsLayer = true
        thumbView.layer?.contentsGravity = .resizeAspectFill
        thumbContainer.addSubview(thumbView)

        nameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        nameLabel.textColor = Theme.textPri
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.maximumNumberOfLines = 1
        nameLabel.stringValue = videoName
        addSubview(nameLabel)

        // "Active" pill — capsule bar with play SF Symbol
        activePill.wantsLayer = true
        activePill.layer?.backgroundColor = Theme.accent.cgColor
        activePill.layer?.cornerRadius = 10
        activePill.isHidden = true
        addSubview(activePill)

        if let img = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Active") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            activeIcon.image = img.withSymbolConfiguration(cfg)
            activeIcon.contentTintColor = .white
        }
        activePill.addSubview(activeIcon)

        activeText.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        activeText.textColor = .white
        activePill.addSubview(activeText)
    }

    private func loadThumb() {
        ThumbCache.shared.get(videoPath, size: NSSize(width: Theme.cardW, height: Theme.thumbH)) { [weak self] img in
            self?.thumbView.image = img
        }
    }

    private func updateActiveState() {
        if isActive {
            layer?.borderWidth = 2
            layer?.borderColor = Theme.accent.cgColor
            activePill.isHidden = false
        } else {
            layer?.borderWidth = 0
            activePill.isHidden = true
        }
        needsDisplay = true
    }

    private func updateHoverState() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.allowsImplicitAnimation = true
            if isHovered {
                layer?.shadowOpacity = 0.32
                layer?.shadowRadius = 14
                layer?.transform = CATransform3DMakeScale(1.025, 1.025, 1)
            } else {
                layer?.shadowOpacity = 0.18
                layer?.shadowRadius = 10
                layer?.transform = CATransform3DIdentity
            }
        }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let b = bounds
        thumbContainer.frame = NSRect(x: 0, y: b.height - thumbHeight, width: b.width, height: thumbHeight)
        thumbView.frame = thumbContainer.bounds
        nameLabel.frame = NSRect(x: 10, y: 4, width: b.width - 20, height: b.height - thumbHeight - 6)

        // Pill at the top-right of the thumbnail
        let pillW: CGFloat = 64, pillH: CGFloat = 20
        activePill.frame = NSRect(x: b.width - pillW - 8, y: b.height - pillH - 8, width: pillW, height: pillH)
        activeIcon.frame = NSRect(x: 8, y: 5, width: 11, height: 11)
        activeText.frame = NSRect(x: 22, y: 3, width: 38, height: 14)

        // Shadow flattened with shadowPath (perf + allows scaled transforms)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Theme.cardRadius, cornerHeight: Theme.cardRadius, transform: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = isHovered ? Theme.cardHover : Theme.cardBg
        bg.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Theme.cardRadius, yRadius: Theme.cardRadius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }
    override func mouseEntered(with e: NSEvent) { isHovered = true }
    override func mouseExited(with e: NSEvent) { isHovered = false }
    override func mouseUp(with e: NSEvent) { onClick?() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        for (title, sel) in [
            ("Set as Desktop + Lock Screen", #selector(setBoth)),
            ("Set as Desktop only", #selector(setDesktopOnly)),
            ("Set as Lock Screen only", #selector(setLockOnly)),
        ] {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = self
            m.addItem(item)
        }
        m.addItem(.separator())
        let del = NSMenuItem(title: "Delete \"\(videoName)\"", action: #selector(deleteItem), keyEquivalent: "")
        del.target = self
        m.addItem(del)
        return m
    }
    @objc func setBoth() { onClick?() }
    @objc func setDesktopOnly() { onSetDesktop?() }
    @objc func setLockOnly() { onSetLock?() }
    @objc func deleteItem() { onDelete?() }
}

// MARK: - Icon Button (with hover-tint)
//
// Borderless button that changes its tint on mouse hover. We use it for the
// Instagram and donation icons in the bottom bar.
class IconButton: NSButton {
    var idleTint: NSColor = NSColor.secondaryLabelColor
    var hoverTint: NSColor = NSColor.controlAccentColor
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }
    override func mouseEntered(with event: NSEvent) { contentTintColor = hoverTint }
    override func mouseExited(with event: NSEvent) { contentTintColor = idleTint }
}

// MARK: - Grid Container
class GridView: NSView {
    var cards: [WallpaperCard] = []
    var bannerView: NSView?

    override var isFlipped: Bool { true }

    func layoutCards() {
        let availWidth = bounds.width - Theme.pad * 2
        // Dynamic columns: tighter min width
        let cols = max(2, Int(availWidth / (190 + Theme.gap)))
        let cardW = (availWidth - CGFloat(cols - 1) * Theme.gap) / CGFloat(cols)
        let thumbH = cardW * 0.58
        let cardH = thumbH + 28

        var y: CGFloat = Theme.pad

        for (i, card) in cards.enumerated() {
            let col = i % cols
            let row = i / cols
            let x = Theme.pad + CGFloat(col) * (cardW + Theme.gap)
            let cy = y + CGFloat(row) * (cardH + Theme.gap)
            card.frame = NSRect(x: x, y: cy, width: cardW, height: cardH)

            // Update thumb height inside card
            card.thumbHeight = thumbH
            card.needsLayout = true
        }

        let rows = cards.isEmpty ? 0 : (cards.count - 1) / cols + 1
        y += CGFloat(rows) * (cardH + Theme.gap)

        if let banner = bannerView {
            banner.frame = NSRect(x: Theme.pad, y: y + 4, width: availWidth, height: 130)
            y += 142
        }

        frame.size.height = max(y + Theme.pad, superview?.bounds.height ?? 0)
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutCards()
    }
}

// MARK: - Main Window Controller
class MainController: NSObject {
    let window: NSWindow
    private let scrollView = NSScrollView()
    private let gridView = GridView()
    private var activeName = ""
    private var aerialSetupOverlay: NSView?

    lazy var appSupportURL: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WallpaperSync")
        try? FileManager.default.createDirectory(at: url.appendingPathComponent("library"), withIntermediateDirectories: true)
        return url
    }()

    lazy var bundleResourcesURL: URL = {
        Bundle.main.resourceURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }()

    private let statusIcon = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let activeInfoLabel = NSTextField(labelWithString: "")
    private let powerSaveBtn = NSSwitch()
    private let searchField = NSSearchField()
    private var allCards: [WallpaperCard] = []

    // Settings popover (Liquid Glass) — controls created once, reused each open.
    private var settingsPopover: NSPopover?
    private let loginSwitch = NSSwitch()
    private let engineSwitch = NSSwitch()
    private let batterySwitch = NSSwitch()
    private let settingsStatusLabel = NSTextField(labelWithString: "")

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Wally"
        // Min width 760 leaves room for traffic lights + title + search +
        // right-side controls without overlap. Below that we hide the search
        // field dynamically.
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.collectionBehavior = [.fullScreenPrimary]
        // Don't force darkAqua: let the system decide (Liquid Glass looks good
        // in both modes). The user can change it in System Settings.

        let cv = window.contentView!
        cv.wantsLayer = true

        // Translucent base layer — idiomatic macOS Tahoe material
        let bgEffect = NSVisualEffectView(frame: cv.bounds)
        bgEffect.autoresizingMask = [.width, .height]
        bgEffect.material = .underWindowBackground
        bgEffect.blendingMode = .behindWindow
        bgEffect.state = .followsWindowActiveState
        cv.addSubview(bgEffect)

        // Header — headerView material, aligned below the native titlebar
        let headerH: CGFloat = 56
        let header = NSVisualEffectView(frame: NSRect(x: 0, y: cv.bounds.height - headerH, width: cv.bounds.width, height: headerH))
        header.autoresizingMask = [.width, .minYMargin]
        header.material = .headerView
        header.blendingMode = .withinWindow
        header.state = .active
        cv.addSubview(header)

        // Hairline separator below the header
        let headerSep = NSBox(frame: NSRect(x: 0, y: 0, width: cv.bounds.width, height: 1))
        headerSep.boxType = .custom
        headerSep.borderWidth = 0
        headerSep.fillColor = NSColor.separatorColor
        headerSep.autoresizingMask = [.width]
        header.addSubview(headerSep)

        // Title — starts after the traffic lights (≈ x=78) so it doesn't
        // cover them. The header's left column reserves 0–250 for
        // [icon · "Library"]; the search occupies the flexible center.
        let titleX: CGFloat = 84
        let titleIcon = NSImageView()
        if let img = NSImage(systemSymbolName: "play.square.stack.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            titleIcon.image = img.withSymbolConfiguration(cfg)
            titleIcon.contentTintColor = Theme.accent
        }
        titleIcon.frame = NSRect(x: titleX, y: 18, width: 22, height: 22)
        header.addSubview(titleIcon)

        let titleLabel = NSTextField(labelWithString: "Library")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = Theme.textPri
        titleLabel.frame = NSRect(x: titleX + 30, y: 18, width: 140, height: 22)
        header.addSubview(titleLabel)

        // Search field — flex center. Grows with the window via .width mask.
        // In small windows it hides in updateHeaderLayout().
        searchField.placeholderString = "Search wallpapers"
        searchField.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        let searchLeft: CGFloat = titleX + 30 + 150  // = 264
        searchField.frame = NSRect(x: searchLeft, y: 16, width: max(180, cv.bounds.width - searchLeft - 330), height: 24)
        searchField.autoresizingMask = [.width]
        header.addSubview(searchField)

        // Settings — gear opens the Liquid Glass settings popover that hosts
        // every control (login, engine, battery, power save, restore, uninstall).
        let gearBtn = IconButton()
        gearBtn.title = ""
        gearBtn.isBordered = false
        gearBtn.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: "Settings") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
            gearBtn.image = img.withSymbolConfiguration(cfg)
        }
        gearBtn.idleTint = Theme.textSec
        gearBtn.hoverTint = Theme.textPri
        gearBtn.contentTintColor = Theme.textSec
        gearBtn.toolTip = "Settings"
        gearBtn.target = self
        gearBtn.action = #selector(showSettingsPopover(_:))
        gearBtn.frame = NSRect(x: cv.bounds.width - 170, y: 15, width: 28, height: 26)
        gearBtn.autoresizingMask = [.minXMargin]
        header.addSubview(gearBtn)

        // Import button — HIG-compliant borderedProminent style
        let importBtn = NSButton(title: "  Import", target: self, action: #selector(importVideo))
        importBtn.bezelStyle = .rounded
        if #available(macOS 11.0, *) {
            importBtn.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
            importBtn.imagePosition = .imageLeading
            importBtn.imageScaling = .scaleProportionallyDown
        }
        importBtn.controlSize = .regular
        importBtn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if #available(macOS 11.0, *) {
            importBtn.bezelColor = Theme.accent
        }
        importBtn.contentTintColor = .white
        importBtn.frame = NSRect(x: cv.bounds.width - 130, y: 16, width: 110, height: 26)
        importBtn.autoresizingMask = [.minXMargin]
        header.addSubview(importBtn)

        // Bottom bar — translucent material + separator
        let bottomH: CGFloat = 36
        let bottomBar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: cv.bounds.width, height: bottomH))
        bottomBar.autoresizingMask = [.width, .maxYMargin]
        bottomBar.material = .titlebar
        bottomBar.blendingMode = .withinWindow
        bottomBar.state = .active
        cv.addSubview(bottomBar)

        let bottomSep = NSBox(frame: NSRect(x: 0, y: bottomH - 1, width: cv.bounds.width, height: 1))
        bottomSep.boxType = .custom
        bottomSep.borderWidth = 0
        bottomSep.fillColor = NSColor.separatorColor
        bottomSep.autoresizingMask = [.width]
        bottomBar.addSubview(bottomSep)

        // Engine status: semantic SF Symbol (green/red).
        statusIcon.frame = NSRect(x: 14, y: 10, width: 14, height: 14)
        bottomBar.addSubview(statusIcon)

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = Theme.textSec
        statusLabel.frame = NSRect(x: 32, y: 10, width: 130, height: 14)
        bottomBar.addSubview(statusLabel)

        activeInfoLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        activeInfoLabel.textColor = Theme.textTer
        activeInfoLabel.alignment = .center
        // Reserve room at the far right for the note + more menu.
        activeInfoLabel.frame = NSRect(x: 170, y: 10, width: cv.bounds.width - 440, height: 14)
        activeInfoLabel.autoresizingMask = [.width]
        bottomBar.addSubview(activeInfoLabel)

        // Placeholder note — far right of the bottom bar. Anchored right via .minXMargin.
        let comingSoon = NSTextField(labelWithString: "Wally")
        comingSoon.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        comingSoon.textColor = Theme.textTer
        comingSoon.alignment = .right
        comingSoon.lineBreakMode = .byTruncatingTail
        comingSoon.frame = NSRect(x: cv.bounds.width - 240, y: 10, width: 200, height: 14)
        comingSoon.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(comingSoon)

        // "More" menu — puts Uninstall/Quit inside the window so they're reachable
        // without the menu-bar icon (which dies if you quit from the Dock).
        let moreBtn = IconButton()
        moreBtn.title = ""
        moreBtn.isBordered = false
        moreBtn.imagePosition = .imageOnly
        if let img = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "More") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            moreBtn.image = img.withSymbolConfiguration(cfg)
        }
        moreBtn.contentTintColor = Theme.textSec
        moreBtn.idleTint = Theme.textSec
        moreBtn.hoverTint = Theme.textPri
        moreBtn.toolTip = "More — Uninstall, Quit"
        moreBtn.target = self
        moreBtn.action = #selector(showMoreMenu(_:))
        moreBtn.frame = NSRect(x: cv.bounds.width - 30, y: 8, width: 22, height: 22)
        moreBtn.autoresizingMask = [.minXMargin]
        bottomBar.addSubview(moreBtn)

        // Scroll + Grid (between header and bottom)
        scrollView.frame = NSRect(x: 0, y: bottomH, width: cv.bounds.width, height: cv.bounds.height - headerH - bottomH)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        gridView.frame = NSRect(x: 0, y: 0, width: scrollView.contentView.bounds.width, height: 800)
        scrollView.documentView = gridView
        cv.addSubview(scrollView)

        // Make the documentView follow the clipView's width — without this, in
        // fullscreen the grid keeps its initial width and leaves dead space on
        // the right instead of fitting more columns.
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(syncGridWidth),
            name: NSView.frameDidChangeNotification,
            object: scrollView.contentView
        )

        reloadLibrary()
        // Correct initial width even if the window started larger than the
        // design frame.
        DispatchQueue.main.async { [weak self] in self?.syncGridWidth() }
    }

    @objc private func syncGridWidth() {
        let w = scrollView.contentView.bounds.width
        guard w > 0, abs(gridView.frame.width - w) > 0.5 else { return }
        var f = gridView.frame
        f.size.width = w
        gridView.frame = f
        gridView.layoutCards()
    }

    @objc func searchChanged() {
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        gridView.cards.forEach { $0.removeFromSuperview() }
        let filtered = q.isEmpty ? allCards : allCards.filter { $0.videoName.lowercased().contains(q) }
        gridView.cards = filtered
        filtered.forEach { gridView.addSubview($0) }
        gridView.layoutCards()
    }

    func reloadLibrary() {
        // Read active name and power save
        let cfgPath = appSupportURL.appendingPathComponent("config.json").path
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["activeName"] as? String {
                activeName = name
            }
            if let ps = json["powerSavingMode"] as? Bool {
                powerSaveBtn.state = ps ? .on : .off
            }
        }

        // Clear
        gridView.cards.forEach { $0.removeFromSuperview() }
        gridView.cards.removeAll()
        allCards.removeAll()
        gridView.bannerView?.removeFromSuperview()
        gridView.bannerView = nil

        let libPath = appSupportURL.appendingPathComponent("library").path
        let files = (try? FileManager.default.contentsOfDirectory(atPath: libPath)) ?? []
        let movFiles = files.filter { $0.hasSuffix(".mov") }.sorted()

        // Engine status — SF Symbol with semantic color
        let engineRunning = engineIsRunning()
        let symbolName = engineRunning ? "circle.fill" : "exclamationmark.circle.fill"
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            statusIcon.image = img.withSymbolConfiguration(cfg)
            statusIcon.contentTintColor = engineRunning ? NSColor.systemGreen : NSColor.systemRed
        }
        statusLabel.stringValue = engineRunning ? "Engine running" : "Engine stopped"

        // Active video info in bottom bar
        if !activeName.isEmpty {
            let vp = (libPath as NSString).appendingPathComponent(activeName + ".mov")
            if FileManager.default.fileExists(atPath: vp) {
                Task { [weak self] in
                    let asset = AVURLAsset(url: URL(fileURLWithPath: vp))
                    var width = 0, height = 0, seconds = 0.0
                    if let track = try? await asset.loadTracks(withMediaType: .video).first,
                       let sz = try? await track.load(.naturalSize) {
                        width = Int(sz.width); height = Int(sz.height)
                    }
                    if let d = try? await asset.load(.duration) {
                        seconds = CMTimeGetSeconds(d)
                    }
                    let bytes = (try? FileManager.default.attributesOfItem(atPath: vp)[.size] as? Int) ?? 0
                    // Finalize into an immutable string so the main-actor hop
                    // captures no mutable state (Swift 6 concurrency clean).
                    let info = "\(width)×\(height)  ·  HEVC  ·  \(bytes / (1024 * 1024))MB  ·  \(Int(seconds))s"
                    await MainActor.run { [weak self] in
                        guard let self = self else { return }
                        self.activeInfoLabel.stringValue = "▶ \(self.activeName)  ·  " + info
                    }
                }
            }
        } else {
            activeInfoLabel.stringValue = ""
        }

        // Cards
        for file in movFiles {
            let name = (file as NSString).deletingPathExtension
            let path = (libPath as NSString).appendingPathComponent(file)
            let card = WallpaperCard(path: path, name: name)
            card.isActive = (name == activeName)
            card.onClick = { [weak self] in self?.useWallpaper(name) }
            card.onSetDesktop = { [weak self] in self?.setDesktopWallpaper(name) }
            card.onSetLock = { [weak self] in self?.setLockWallpaper(name) }
            card.onDelete = { [weak self] in self?.deleteWallpaper(name) }
            gridView.addSubview(card)
            gridView.cards.append(card)
            allCards.append(card)
        }
        // Reapply the current search filter over the new cards
        let q = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            let visible = allCards.filter { $0.videoName.lowercased().contains(q) }
            allCards.filter { !visible.contains($0) }.forEach { $0.removeFromSuperview() }
            gridView.cards = visible
        }

        // Check if aerial is set up
        let aerialsDir = NSString(string: "~/Library/Application Support/com.apple.wallpaper/aerials/videos").expandingTildeInPath
        var hasAerial = false
        if let afiles = try? FileManager.default.contentsOfDirectory(atPath: aerialsDir) {
            hasAerial = afiles.contains(where: { $0.hasSuffix(".mov") && !$0.contains("backup") && !$0.contains("tmp") })
        }

        if !hasAerial {
            // Modal overlay with a blurred background: visually blocks the app
            // until the user sets up the aerial. The inline banner was too
            // timid and people ignored it.
            showAerialSetupOverlay()
        } else {
            hideAerialSetupOverlay()
        }
        if hasAerial && movFiles.isEmpty {
            let emptyBanner = makeBanner(
                symbol: "tray.fill",
                tint: Theme.accent,
                title: "Your library is empty",
                body: "Import a video (.mp4, .mov, .gif) to use it as an animated wallpaper.",
                buttonTitle: "Import Video",
                buttonSymbol: "plus",
                action: #selector(importVideo)
            )
            gridView.bannerView = emptyBanner
            gridView.addSubview(emptyBanner)
        }

        gridView.layoutCards()
    }

    private func makeBanner(symbol: String, tint: NSColor, title: String, body: String, buttonTitle: String, buttonSymbol: String?, action: Selector) -> NSView {
        let banner = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 168))
        banner.wantsLayer = true
        banner.layer?.backgroundColor = Theme.cardBg.cgColor
        banner.layer?.cornerRadius = 14
        banner.layer?.borderWidth = 1
        banner.layer?.borderColor = tint.withAlphaComponent(0.35).cgColor

        // Symbol pill on the left
        let symbolBg = NSView()
        symbolBg.wantsLayer = true
        symbolBg.layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
        symbolBg.layer?.cornerRadius = 10
        symbolBg.frame = NSRect(x: 18, y: 116, width: 36, height: 36)
        banner.addSubview(symbolBg)

        let symView = NSImageView()
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            symView.image = img.withSymbolConfiguration(cfg)
            symView.contentTintColor = tint
        }
        symView.frame = NSRect(x: 26, y: 124, width: 22, height: 22)
        banner.addSubview(symView)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = Theme.textPri
        titleLabel.frame = NSRect(x: 64, y: 128, width: 600, height: 20)
        banner.addSubview(titleLabel)

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = NSFont.systemFont(ofSize: 12)
        bodyLabel.textColor = Theme.textSec
        bodyLabel.frame = NSRect(x: 18, y: 40, width: 700, height: 80)
        bodyLabel.maximumNumberOfLines = 10
        bodyLabel.usesSingleLineMode = false
        banner.addSubview(bodyLabel)

        let btn = NSButton(title: buttonSymbol == nil ? buttonTitle : "  " + buttonTitle,
                           target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if #available(macOS 11.0, *) {
            if let s = buttonSymbol, let img = NSImage(systemSymbolName: s, accessibilityDescription: nil) {
                btn.image = img
                btn.imagePosition = .imageLeading
            }
            btn.bezelColor = Theme.accent
        }
        btn.contentTintColor = .white
        btn.frame = NSRect(x: 18, y: 8, width: 200, height: 28)
        banner.addSubview(btn)

        return banner
    }

    // MARK: - Aerial setup overlay (modal with blurred backdrop)

    private func showAerialSetupOverlay() {
        if aerialSetupOverlay != nil { return }
        FileHandle.standardError.write("[hud] aerial setup overlay shown\n".data(using: .utf8)!)
        let cv = window.contentView!

        // Translucent backdrop covering the whole window — the .fullScreenUI
        // material triggers macOS's idiomatic aggressive blur.
        let overlay = NSVisualEffectView(frame: cv.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.material = .fullScreenUI
        overlay.blendingMode = .withinWindow
        overlay.state = .active
        overlay.wantsLayer = true

        // Click eater: prevents interaction with the grid behind.
        let eater = NSView(frame: overlay.bounds)
        eater.autoresizingMask = [.width, .height]
        overlay.addSubview(eater)

        // Central card
        let cardW: CGFloat = 480
        let cardH: CGFloat = 380
        let card = NSView(frame: NSRect(
            x: (overlay.bounds.width - cardW) / 2,
            y: (overlay.bounds.height - cardH) / 2,
            width: cardW, height: cardH))
        card.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin, .maxYMargin]
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.layer?.shadowColor = NSColor.black.cgColor
        card.layer?.shadowOpacity = 0.35
        card.layer?.shadowRadius = 32
        card.layer?.shadowOffset = CGSize(width: 0, height: -8)
        card.layer?.masksToBounds = false
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
        overlay.addSubview(card)

        // Symbol pill
        let symbolBgSize: CGFloat = 64
        let symbolBg = NSView(frame: NSRect(
            x: (cardW - symbolBgSize) / 2,
            y: cardH - 92,
            width: symbolBgSize, height: symbolBgSize))
        symbolBg.wantsLayer = true
        symbolBg.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        symbolBg.layer?.cornerRadius = 16
        card.addSubview(symbolBg)

        let symView = NSImageView()
        if let img = NSImage(systemSymbolName: "moon.stars.fill", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 30, weight: .medium)
            symView.image = img.withSymbolConfiguration(cfg)
            symView.contentTintColor = NSColor.systemYellow
        }
        symView.frame = NSRect(x: (cardW - 36) / 2, y: cardH - 78, width: 36, height: 36)
        card.addSubview(symView)

        // Title
        let title = NSTextField(labelWithString: "Set up your lock screen")
        title.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        title.textColor = Theme.textPri
        title.alignment = .center
        title.frame = NSRect(x: 24, y: cardH - 134, width: cardW - 48, height: 26)
        card.addSubview(title)

        // Subtitle
        let subtitle = NSTextField(labelWithString: "To sync the video with your lock screen, macOS needs an aerial wallpaper downloaded.")
        subtitle.font = NSFont.systemFont(ofSize: 13)
        subtitle.textColor = Theme.textSec
        subtitle.alignment = .center
        subtitle.maximumNumberOfLines = 3
        subtitle.usesSingleLineMode = false
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.frame = NSRect(x: 32, y: cardH - 188, width: cardW - 64, height: 44)
        card.addSubview(subtitle)

        // Numbered steps
        let steps: [(String, String)] = [
            ("1", "Open System Settings → Wallpaper"),
            ("2", "Find an animated wallpaper (e.g. \"Tahoe Day\")"),
            ("3", "Tap the download icon (☁︎)"),
            ("4", "Turn on \"Show as screen saver\""),
        ]
        var stepY = cardH - 215
        for (num, text) in steps {
            stepY -= 26

            // Bullet with the number
            let bullet = NSTextField(labelWithString: num)
            bullet.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            bullet.textColor = Theme.accent
            bullet.alignment = .center
            bullet.frame = NSRect(x: 36, y: stepY, width: 18, height: 18)
            card.addSubview(bullet)

            let stepLabel = NSTextField(labelWithString: text)
            stepLabel.font = NSFont.systemFont(ofSize: 12.5)
            stepLabel.textColor = Theme.textPri
            stepLabel.frame = NSRect(x: 60, y: stepY, width: cardW - 80, height: 18)
            card.addSubview(stepLabel)
        }

        // Primary button
        let btn = NSButton(title: "  Open System Settings", target: self, action: #selector(openWallpaperSettings))
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        if #available(macOS 11.0, *) {
            btn.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
            btn.imagePosition = .imageLeading
            btn.bezelColor = Theme.accent
        }
        btn.contentTintColor = .white
        btn.frame = NSRect(x: (cardW - 260) / 2, y: 24, width: 260, height: 32)
        card.addSubview(btn)

        cv.addSubview(overlay, positioned: .above, relativeTo: nil)
        aerialSetupOverlay = overlay
    }

    private func hideAerialSetupOverlay() {
        guard aerialSetupOverlay != nil else { return }
        FileHandle.standardError.write("[hud] aerial setup overlay hidden\n".data(using: .utf8)!)
        aerialSetupOverlay?.removeFromSuperview()
        aerialSetupOverlay = nil
    }

    @objc func openWallpaperSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension")!)
    }

    // MARK: - Settings popover (Liquid Glass)

    @objc func showSettingsPopover(_ sender: NSButton) {
        let pop = settingsPopover ?? buildSettingsPopover()
        settingsPopover = pop
        if pop.isShown { pop.performClose(sender); return }
        refreshSettingsStates()
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private let settingsW: CGFloat = 320
    private let settingsH: CGFloat = 448

    private func buildSettingsPopover() -> NSPopover {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: settingsW, height: settingsH))
        content.autoresizingMask = [.width, .height]
        let innerX: CGFloat = 16
        let innerW = settingsW - innerX * 2

        // Lay out top-down. fromTop(offset,h) converts a top-anchored offset to
        // an AppKit (bottom-left origin) y, matching the manual-frame style used
        // throughout this file.
        func fromTop(_ top: CGFloat, _ h: CGFloat) -> CGFloat { settingsH - top - h }

        content.addSubview(makeSectionHeader("STARTUP", frame: NSRect(x: innerX, y: fromTop(16, 16), width: innerW, height: 16)))
        content.addSubview(makeSwitchRow("Launch at login", "Open Wally automatically",
            control: loginSwitch, action: #selector(toggleLoginItem),
            frame: NSRect(x: innerX, y: fromTop(38, 42), width: innerW, height: 42)))

        content.addSubview(makeSectionHeader("ENGINE", frame: NSRect(x: innerX, y: fromTop(90, 16), width: innerW, height: 16)))
        content.addSubview(makeSwitchRow("Wallpaper engine", "Play the animated wallpaper",
            control: engineSwitch, action: #selector(toggleEngine),
            frame: NSRect(x: innerX, y: fromTop(112, 42), width: innerW, height: 42)))

        content.addSubview(makeSectionHeader("POWER", frame: NSRect(x: innerX, y: fromTop(164, 16), width: innerW, height: 16)))
        content.addSubview(makeSwitchRow("Pause on battery", "Stop when unplugged",
            control: batterySwitch, action: #selector(toggleBattery),
            frame: NSRect(x: innerX, y: fromTop(186, 42), width: innerW, height: 42)))
        content.addSubview(makeSwitchRow("Power save", "Show a static frame",
            control: powerSaveBtn, action: #selector(togglePowerSaveHUD),
            frame: NSRect(x: innerX, y: fromTop(232, 42), width: innerW, height: 42)))

        content.addSubview(makeActionButton("Sync to lock screen", symbol: "arrow.triangle.2.circlepath",
            destructive: false, action: #selector(syncLockScreenFromSettings),
            frame: NSRect(x: innerX, y: fromTop(286, 32), width: innerW, height: 32)))
        content.addSubview(makeActionButton("Restore original lock screen", symbol: "arrow.uturn.backward",
            destructive: false, action: #selector(restoreLockScreenFromSettings),
            frame: NSRect(x: innerX, y: fromTop(326, 32), width: innerW, height: 32)))
        content.addSubview(makeActionButton("Uninstall Wally…", symbol: "trash",
            destructive: true, action: #selector(uninstallFromSettings),
            frame: NSRect(x: innerX, y: fromTop(366, 32), width: innerW, height: 32)))

        settingsStatusLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        settingsStatusLabel.textColor = Theme.textTer
        settingsStatusLabel.lineBreakMode = .byTruncatingTail
        settingsStatusLabel.maximumNumberOfLines = 2
        settingsStatusLabel.frame = NSRect(x: innerX, y: fromTop(406, 28), width: innerW, height: 28)
        content.addSubview(settingsStatusLabel)

        let vc = NSViewController()
        // Genuine Liquid Glass backing (macOS 26+); graceful on older systems.
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: content.bounds)
            glass.cornerRadius = 20
            glass.contentView = content
            vc.view = glass
        } else {
            vc.view = content
        }

        let pop = NSPopover()
        pop.contentViewController = vc
        pop.contentSize = NSSize(width: settingsW, height: settingsH)
        pop.behavior = .transient
        pop.animates = true
        return pop
    }

    private func makeSectionHeader(_ text: String, frame: NSRect) -> NSView {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = Theme.textTer
        l.frame = frame
        return l
    }

    private func makeSwitchRow(_ title: String, _ subtitle: String, control: NSSwitch, action: Selector, frame: NSRect) -> NSView {
        let row = NSView(frame: frame)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = Theme.textPri
        titleLabel.frame = NSRect(x: 0, y: 21, width: frame.width - 54, height: 17)
        row.addSubview(titleLabel)

        let subLabel = NSTextField(labelWithString: subtitle)
        subLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        subLabel.textColor = Theme.textSec
        subLabel.frame = NSRect(x: 0, y: 4, width: frame.width - 54, height: 15)
        row.addSubview(subLabel)

        control.target = self
        control.action = action
        control.frame = NSRect(x: frame.width - 42, y: (frame.height - 22) / 2, width: 40, height: 22)
        row.addSubview(control)
        return row
    }

    private func makeActionButton(_ title: String, symbol: String, destructive: Bool, action: Selector, frame: NSRect) -> NSView {
        let btn = NSButton(title: "  " + title, target: self, action: action)
        btn.bezelStyle = .rounded
        btn.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        btn.frame = frame
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            btn.image = img
            btn.imagePosition = .imageLeading
        }
        if destructive {
            btn.contentTintColor = NSColor.systemRed
        }
        return btn
    }

    private func refreshSettingsStates() {
        // Config-backed toggles
        let cfgPath = appSupportURL.appendingPathComponent("config.json").path
        var battery = false, powerSave = false
        if let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            battery = (json["pauseOnBattery"] as? Bool) ?? false
            powerSave = (json["powerSavingMode"] as? Bool) ?? false
        }
        batterySwitch.state = battery ? .on : .off
        powerSaveBtn.state = powerSave ? .on : .off

        // Engine running?
        let running = engineIsRunning()
        engineSwitch.state = running ? .on : .off

        // Login item
        if #available(macOS 13.0, *) {
            loginSwitch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }

        settingsStatusLabel.stringValue = running
            ? "Engine running\(activeName.isEmpty ? "" : " · ▶ \(activeName)")"
            : "Engine stopped"
    }

    private func engineIsRunning() -> Bool {
        (try? String(contentsOfFile: appSupportURL.appendingPathComponent("logs/engine.pid").path, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { kill(Int32($0), 0) == 0 } ?? false
    }

    @objc func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if loginSwitch.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSSound.beep()
            let a = NSAlert()
            a.messageText = "Couldn't update login item"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        refreshSettingsStates()
    }

    @objc func toggleEngine() {
        let on = (engineSwitch.state == .on)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCommand("bin/wallpaper", args: [on ? "start" : "stop"])
            DispatchQueue.main.async {
                self?.reloadLibrary()
                self?.refreshSettingsStates()
            }
        }
    }

    @objc func toggleBattery() {
        let on = (batterySwitch.state == .on)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCommand("bin/wallpaper", args: ["battery", on ? "on" : "off"])
        }
    }

    // Push the active wallpaper onto the lock screen.
    @objc func syncLockScreenFromSettings() {
        settingsPopover?.performClose(nil)
        runLockScreenCommand(["lockscreen"], title: "Sync to lock screen",
                             successText: "The lock screen was updated. Lock your screen (⌃⌘Q) to see it.")
    }

    // Revert the lock screen to Apple's original aerial (undo the sync).
    @objc func restoreLockScreenFromSettings() {
        settingsPopover?.performClose(nil)
        runLockScreenCommand(["lockscreen-restore"], title: "Restore original lock screen",
                             successText: "The lock screen was reverted to the original aerial.")
    }

    // Run a lock-screen CLI command and report the outcome, so the action isn't
    // silent (the lock screen only changes what you see once you actually lock).
    private func runLockScreenCommand(_ args: [String], title: String, successText: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.runCommandResult("bin/wallpaper", args: args)
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                let ok = (result.code == 0)
                alert.messageText = ok ? "✓ \(title)" : "\(title) didn’t complete"
                alert.informativeText = ok ? successText
                                           : Self.extractError(from: result.output)
                alert.alertStyle = ok ? .informational : .warning
                alert.runModal()
            }
        }
    }

    // Pull the CLI's `error:` message (plus its indented continuation lines) out
    // of the combined output, ignoring interleaved `··` progress lines.
    private static func extractError(from output: String) -> String {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.hasPrefix("error:") }) else {
            return "No active wallpaper to sync — set one first."
        }
        var msg = [String(lines[start].dropFirst("error:".count)).trimmingCharacters(in: .whitespaces)]
        var i = start + 1
        while i < lines.count, lines[i].first == " " {
            msg.append(lines[i].trimmingCharacters(in: .whitespaces))
            i += 1
        }
        return msg.joined(separator: "\n")
    }

    @objc func uninstallFromSettings() {
        settingsPopover?.performClose(nil)
        (NSApp.delegate as? AppDelegate)?.uninstallApp()
    }

    @objc func showMoreMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let uninstall = NSMenuItem(title: "Uninstall Wally…",
                                   action: #selector(AppDelegate.uninstallApp), keyEquivalent: "")
        uninstall.target = NSApp.delegate
        menu.addItem(uninstall)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // Left-click / "Both": desktop + lock screen.
    private func useWallpaper(_ name: String) {
        activeName = name
        gridView.cards.forEach { $0.isActive = ($0.videoName == name) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCommand("bin/wallpaper", args: ["use", name])
        }
        // Force refresh active info
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reloadLibrary() }
    }

    // "Desktop only": animated desktop wallpaper, lock screen untouched.
    private func setDesktopWallpaper(_ name: String) {
        activeName = name
        gridView.cards.forEach { $0.isActive = ($0.videoName == name) }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCommand("bin/wallpaper", args: ["desktop", name])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.reloadLibrary() }
    }

    // "Lock Screen only": sync this video to the lock screen, desktop untouched.
    private func setLockWallpaper(_ name: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCommand("bin/wallpaper", args: ["lockscreen", name])
        }
    }

    @objc func togglePowerSaveHUD() {
        let isPowerSave = (powerSaveBtn.state == .on)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runCommand("bin/wallpaper", args: ["powersave", isPowerSave ? "on" : "off"])
        }
    }

    private func deleteWallpaper(_ name: String) {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(name)\"?"
        alert.informativeText = "It will be removed from your library."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.runCommand("bin/wallpaper", args: ["remove", name])
                DispatchQueue.main.async { self?.reloadLibrary() }
            }
        }
    }

    @objc func importVideo() {
        // Accessory (LSUIElement) apps must be activated first, otherwise the
        // open panel can open behind the window and the click looks ignored.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        // Match the formats the CLI accepts. Build from extensions and drop any
        // the system can't resolve rather than force-unwrapping (a nil crashes).
        let types = ["mp4", "mov", "m4v", "gif", "webm"].compactMap { UTType(filenameExtension: $0) }
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.allowsMultipleSelection = true
        panel.title = "Select videos to import"
        panel.prompt = "Import"

        let handle: ([URL]) -> Void = { [weak self] urls in
            for url in urls {
                DispatchQueue.global(qos: .userInitiated).async {
                    self?.runCommand("bin/wallpaper", args: ["set", url.path])
                    DispatchQueue.main.async { self?.reloadLibrary() }
                }
            }
        }

        // Present as a sheet on the HUD so it's always frontmost and attached.
        if window.isVisible {
            panel.beginSheetModal(for: window) { resp in
                if resp == .OK { handle(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            handle(panel.urls)
        }
    }

    func runCommand(_ executable: String, args: [String]) {
        let process = Process()
        process.executableURL = bundleResourcesURL.appendingPathComponent(executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["APP_BUNDLE_RESOURCES"] = bundleResourcesURL.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env
        do { try process.run(); process.waitUntilExit() }
        catch { print("Error: \(error)") }
    }

    // Like runCommand but captures the exit code and combined output, so
    // callers can report success/failure to the user.
    func runCommandResult(_ executable: String, args: [String]) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = bundleResourcesURL.appendingPathComponent(executable)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["APP_BUNDLE_RESOURCES"] = bundleResourcesURL.path
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}

// MARK: - App Delegate (Menu Bar + Window)
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var statusItem: NSStatusItem!
    var mainController: MainController!

    func applicationDidFinishLaunching(_ n: Notification) {
        mainController = MainController()
        mainController.window.delegate = self

        // Menu bar icon — monochrome SF Symbol, adapts to the light/dark menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            if #available(macOS 11.0, *),
               let img = NSImage(systemSymbolName: "play.square.stack.fill", accessibilityDescription: "Wally") {
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                let configured = img.withSymbolConfiguration(cfg) ?? img
                configured.isTemplate = true
                btn.image = configured
            } else {
                btn.title = "🎬"
            }
            btn.action = #selector(statusItemClicked(_:))
            btn.target = self
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Start minimized — only menu bar icon visible, no dock icon
        // (window stays hidden until user clicks 🎬)

        // Check dependencies, then start engine
        checkDependencies {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.mainController.runCommand("bin/wallpaper", args: ["start"])
            }
        }
    }

    private func ffmpegPath() -> String? {
        for p in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func brewPath() -> String? {
        for p in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
    }

    private func checkDependencies(then onReady: @escaping () -> Void) {
        if ffmpegPath() != nil { onReady(); return }

        // ffmpeg not found — ask to install
        let alert = NSAlert()
        alert.messageText = "ffmpeg required"
        alert.informativeText = "Wally needs ffmpeg to convert videos.\n\nWould you like it installed automatically?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install ffmpeg")
        alert.addButton(withTitle: "Later")

        if alert.runModal() != .alertFirstButtonReturn { onReady(); return }

        if let brew = brewPath() {
            installFFmpeg(brew: brew, then: onReady)
        } else {
            installHomebrew(then: onReady)
        }
    }

    private func installFFmpeg(brew: String, then onReady: @escaping () -> Void) {
        let progress = NSAlert()
        progress.messageText = "Installing ffmpeg…"
        progress.informativeText = "This may take a couple of minutes.\nDon't close this window."
        progress.addButton(withTitle: "Waiting…")
        progress.buttons[0].isEnabled = false

        // Show non-modal
        DispatchQueue.main.async { progress.beginSheetModal(for: self.mainController.window) { _ in } }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: brew)
            proc.arguments = ["install", "ffmpeg"]
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "")
            proc.environment = env
            try? proc.run()
            proc.waitUntilExit()

            DispatchQueue.main.async {
                self?.mainController.window.endSheet(self?.mainController.window.attachedSheet ?? NSWindow())
                if self?.ffmpegPath() != nil {
                    let ok = NSAlert()
                    ok.messageText = "✓ ffmpeg installed"
                    ok.informativeText = "All set! You can now import and use your videos."
                    ok.runModal()
                } else {
                    let fail = NSAlert()
                    fail.messageText = "Couldn't install ffmpeg"
                    fail.informativeText = "Open Terminal and run:\nbrew install ffmpeg"
                    fail.alertStyle = .warning
                    fail.runModal()
                }
                onReady()
            }
        }
    }

    private func installHomebrew(then onReady: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Homebrew required"
        alert.informativeText = "Homebrew is the macOS package manager.\nTerminal will open to install it.\n\nAfter installing Homebrew, run:\nbrew install ffmpeg"
        alert.addButton(withTitle: "Open Terminal")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            // Open Terminal with the Homebrew install script
            let script = "/bin/bash -c \\\"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\\\" && brew install ffmpeg"
            let appleScript = "tell application \"Terminal\" to do script \"\(script)\""
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScript]
            try? proc.run()
        }
        onReady()
    }

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent!
        if event.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(NSMenuItem(title: "Open HUD", action: #selector(toggleWindow), keyEquivalent: ""))

            let pSave = NSMenuItem(title: "Power Save (static frame)", action: #selector(togglePowerSaveMenu), keyEquivalent: "")
            let cfgPath = mainController.appSupportURL.appendingPathComponent("config.json").path
            if let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let ps = json["powerSavingMode"] as? Bool, ps {
                pSave.state = .on
            } else {
                pSave.state = .off
            }
            menu.addItem(pSave)
            
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Uninstall…", action: #selector(uninstallApp), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // remove so left click works natively
        } else {
            toggleWindow()
        }
    }

    @objc func togglePowerSaveMenu() {
        let cfgPath = mainController.appSupportURL.appendingPathComponent("config.json").path
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: cfgPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        
        let current = json["powerSavingMode"] as? Bool ?? false
        let newState = !current
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.mainController.runCommand("bin/wallpaper", args: ["powersave", newState ? "on" : "off"])
            DispatchQueue.main.async {
                self?.mainController.reloadLibrary()
            }
        }
    }

    @objc func uninstallApp() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Uninstall Wally?"
        alert.informativeText = """
        This will:
          1. Stop the wallpaper engine
          2. Restore your original lock screen
          3. Remove the login auto-start
          4. Delete app data (~/Library/Application Support/WallpaperSync)
          5. Move the app to the Trash, then quit

        Your imported wallpaper library is inside the app data, so it will be removed too.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.setActivationPolicy(.accessory)
            return
        }

        // 1–4: reverse everything the app changed.
        mainController.runCommand("bin/wallpaper", args: ["uninstall"])

        // 5: move this .app bundle to the Trash. The running process keeps going
        // until we terminate below, so this is safe.
        let appBundleURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appBundleURL]) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    @objc func toggleWindow() {
        if mainController.window.isVisible {
            hideWindow()
        } else {
            showWindow()
        }
    }

    private func showWindow() {
        NSApp.setActivationPolicy(.regular)  // Show in dock
        mainController.reloadLibrary()
        mainController.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func hideWindow() {
        mainController.window.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)  // Hide from dock
    }

    // Quitting the menu app must also stop the detached WallpaperEngine —
    // otherwise the overlay keeps rendering and the wallpaper stays on screen.
    // runCommand is synchronous (waitUntilExit); stop is fast (SIGTERM).
    func applicationWillTerminate(_ n: Notification) {
        mainController.runCommand("bin/wallpaper", args: ["stop"])
    }

    // When user clicks the red X, hide to menu bar instead of quitting
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideWindow()
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }
}

// MARK: - Main
let app = NSApplication.shared
app.setActivationPolicy(.accessory)  // Start as menu bar only (no dock icon)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
