import AppKit
import AVFoundation

/// 桌面上那只奶蛙：一个透明、置顶、不抢焦点的小窗。
/// 平时就是一张静止的站姿图（不跑定时器，不占 CPU）。笑的时候播一遍带透明通道的 HEVC 视频：
/// 系统硬件解码，这边只在播放的几秒里按帧取出来贴到图层上，播完换回站姿。
final class Pet {
    static var shared: Pet?

    let assets: Assets
    let panel: PetPanel
    let view: PetView
    private var idle: CGImage?
    private let video: AVPlayer
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    private var sound: AVAudioPlayer?
    private var timer: Timer?
    private var laughStart: CFTimeInterval?
    private var duration: Double = 4

    init(assets: Assets) {
        self.assets = assets
        let item = AVPlayerItem(url: assets.video)
        item.add(output)
        video = AVPlayer(playerItem: item)
        video.actionAtItemEnd = .pause
        video.preventsDisplaySleepDuringVideoPlayback = false
        video.isMuted = true
        panel = PetPanel(size: Prefs.size)
        view = PetView(frame: NSRect(x: 0, y: 0, width: Prefs.size, height: Prefs.size))
        view.pet = self
        panel.contentView = view
        if let url = assets.sound {
            sound = try? AVAudioPlayer(contentsOf: url)
            sound?.volume = 0.8
            sound?.prepareToPlay()
        }
        Task { [weak self] in
            if let d = try? await item.asset.load(.duration), d.seconds > 0 { self?.duration = d.seconds }
        }
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.finishLaugh()
        }
        // 透明的地方要让鼠标穿过去：窗口默认不接鼠标，指针移到奶蛙身上才接
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.updatePassThrough() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.placeOnScreen() }
    }

    /// 站姿用视频第一帧，和笑的时候走同一条解码路径（单独存 PNG 的话两边颜色会差几个色阶，开始笑时会跳一下）
    func show() {
        Task { @MainActor in
            idle = await Self.firstFrame(of: assets.video)
            view.image = idle
            placeOnScreen()
            panel.orderFrontRegardless()
        }
    }

    private static func firstFrame(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        defer { reader.cancelReading() }
        guard let sample = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else { return nil }
        return image(from: pb)
    }

    func handle(_ msg: Link.Message) {
        switch msg {
        case .laugh: laugh()
        case .quit: NSApp.terminate(nil)
        }
    }

    // MARK: 笑

    func laugh() {
        // 正在笑就不打断，快笑完了再来一次就从头笑
        if let s = laughStart, CACurrentMediaTime() - s < duration * 0.8 { return }
        laughStart = CACurrentMediaTime()
        video.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in self?.video.play() }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        if Prefs.sound, let p = sound {
            p.stop()
            p.currentTime = 0
            p.play(atTime: p.deviceCurrentTime + assets.audioDelay)
        }
    }

    private func tick() {
        let t = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: t),
              let pb = output.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil),
              let img = Self.image(from: pb) else { return }
        view.show(img)
    }

    private func finishLaugh() {
        timer?.invalidate()
        timer = nil
        laughStart = nil
        view.show(idle)  // 和原片开笑一样硬切回站姿：淡入会把两个姿势叠出重影
        video.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// 解码出来的 BGRA 帧（预乘 alpha）→ CGImage。复制一份，像素缓冲马上还给解码器
    private static func image(from pb: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        guard let provider = CGDataProvider(data: Data(bytes: base, count: bpr * h) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: 位置和鼠标

    func updatePassThrough() {
        guard !view.dragging else { return }
        let m = NSEvent.mouseLocation
        let over = panel.frame.contains(m) && view.isOpaque(atScreen: m)
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
    }

    func placeOnScreen() {
        let size = Prefs.size
        var origin = Prefs.origin
        if let o = origin, !NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -size / 2, dy: -size / 2).contains(NSRect(origin: o, size: CGSize(width: size, height: size))) }) {
            origin = nil  // 原来的屏幕没了
        }
        if origin == nil, let vf = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: vf.maxX - size - 24, y: vf.minY)
        }
        panel.setFrame(NSRect(origin: origin ?? .zero, size: CGSize(width: size, height: size)), display: true)
    }

    func resize(to size: CGFloat) {
        // 脚底中点不动
        let f = panel.frame
        let origin = NSPoint(x: f.midX - size / 2, y: f.minY)
        Prefs.size = size
        Prefs.origin = origin
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("笑一下") { [weak self] in self?.laugh() })
        let sound = item("笑声") { Prefs.sound.toggle() }
        sound.state = Prefs.sound ? .on : .off
        m.addItem(sound)
        let sizes = NSMenu()
        for (name, s) in [("小", 72.0), ("中", 110.0), ("大", 160.0), ("特大", 220.0)] {
            let it = item(name) { [weak self] in self?.resize(to: s) }
            it.state = abs(Prefs.size - s) < 1 ? .on : .off
            sizes.addItem(it)
        }
        let size = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        size.submenu = sizes
        m.addItem(size)
        m.addItem(.separator())
        m.addItem(item("让它走（naiwa 叫回来）") {
            Prefs.dismissed = true
            NSApp.terminate(nil)
        })
        return m
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let it = ClosureMenuItem(title: title, action: #selector(ClosureMenuItem.fire), keyEquivalent: "")
        it.target = it
        it.closure = action
        return it
    }
}

final class ClosureMenuItem: NSMenuItem {
    var closure: (() -> Void)?
    @objc func fire() { closure?() }
}

final class PetPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PetView: NSView {
    weak var pet: Pet?
    var image: CGImage? { didSet { layer?.contents = image } }
    private(set) var dragging = false
    private var downAt: NSPoint = .zero
    private var downOrigin: NSPoint = .zero
    private var stroke = Stroke()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ img: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        image = img
        CATransaction.commit()
    }

    /// 屏幕坐标这一点上奶蛙是不是实心的（透明处让鼠标穿过去）
    func isOpaque(atScreen p: NSPoint) -> Bool {
        guard let win = window, let img = image else { return false }
        let local = convert(win.convertPoint(fromScreen: p), from: nil)
        let x = Int(local.x / bounds.width * CGFloat(img.width))
        let y = Int((1 - local.y / bounds.height) * CGFloat(img.height))
        guard (0..<img.width).contains(x), (0..<img.height).contains(y) else { return false }
        var px = [UInt8](repeating: 0, count: 4)
        let hit = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
            return true
        }
        return hit && px[3] > 60
    }

    override func mouseMoved(with event: NSEvent) {
        pet?.updatePassThrough()
        if !(window?.ignoresMouseEvents ?? true), stroke.add(NSEvent.mouseLocation) {
            pet?.laugh()
        }
    }

    override func mouseExited(with event: NSEvent) {
        stroke = Stroke()
        pet?.updatePassThrough()
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        dragging = false
        downAt = NSEvent.mouseLocation
        downOrigin = window?.frame.origin ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        if !dragging, hypot(m.x - downAt.x, m.y - downAt.y) < 3 { return }
        dragging = true
        window?.setFrameOrigin(NSPoint(x: downOrigin.x + m.x - downAt.x, y: downOrigin.y + m.y - downAt.y))
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            Prefs.origin = window?.frame.origin
            pet?.updatePassThrough()
        } else {
            pet?.laugh()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = pet?.menu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 来回摸：1.2 秒内同一个方向上折返 3 次就算摸到了
struct Stroke {
    private var last: NSPoint?
    private var dir = (x: 0, y: 0)
    private var turns: [CFTimeInterval] = []

    mutating func add(_ p: NSPoint) -> Bool {
        defer { last = p }
        guard let l = last else { return false }
        let now = CACurrentMediaTime()
        let dx = p.x - l.x, dy = p.y - l.y
        if abs(dx) >= 2 {
            let d = dx > 0 ? 1 : -1
            if dir.x != 0 && d != dir.x { turns.append(now) }
            dir.x = d
        }
        if abs(dy) >= 2 {
            let d = dy > 0 ? 1 : -1
            if dir.y != 0 && d != dir.y { turns.append(now) }
            dir.y = d
        }
        turns.removeAll { now - $0 > 1.2 }
        if turns.count >= 3 {
            turns.removeAll()
            return true
        }
        return false
    }
}
