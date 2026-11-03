import AppKit

/// 桌面上那只奶蛙：一个透明、置顶、不抢焦点的小窗。画面全部来自原版《奶蛙大笑》的几段片段，没有声音：
///   空闲：全身侧身站着，一动不动（不跑任何定时器）
///   干活：镜头慢慢推近到侧脸和眼睛的特写（惊鸿一瞥），隔几秒眨一下眼
///   等你：特写里一下子转过来直勾勾看着你，头顶冒「项目 等你批准 Bash」
///   做完：拉回全身，干完一个活捧腹大笑，超长任务笑到倒地打滚，头顶冒「项目 做完了 · 时长」；摸它、点它也会笑
/// 优先级：笑 > 等你 > 干活 > 空闲。笑不会被打断，笑完再回到当时该有的状态。
final class Pet {
    static var shared: Pet?

    /// 取景：全身 / 侧脸特写 / 转头看你的特写
    enum Shot { case full, side, look }

    let panel: PetPanel
    let view: PetView
    private let clips: [String: ClipPlayer]
    private let closeups: [Shot: CGRect]
    private let sessions = Sessions()
    private let bubble = Bubble()
    private var playing: (name: String, player: ClipPlayer, important: Bool, start: CFTimeInterval)?
    private var celebrating = false
    private var frameTimer: Timer?
    private var blinkTimer: Timer?
    private var shot = Shot.full
    private var bubbleIsWaiting = false

    init(assets: Assets) {
        clips = assets.clips.mapValues { ClipPlayer($0, fps: assets.fps) }
        var c: [Shot: CGRect] = [:]
        c[.side] = assets.closeups["focus"]
        c[.look] = assets.closeups["glance"]
        closeups = c
        panel = PetPanel(size: Prefs.size)
        view = PetView(frame: NSRect(x: 0, y: 0, width: Prefs.size, height: Prefs.size))
        view.pet = self
        panel.contentView = view
        // 透明的地方要让鼠标穿过去：窗口默认不接鼠标，指针移到奶蛙身上才接
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in self?.updatePassThrough() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.placeOnScreen() }
    }

    func show() {
        Task { @MainActor in
            await clips["focus"]?.loadStills()
            await clips["glance"]?.loadStills()
            placeOnScreen()
            panel.orderFrontRegardless()
            render()
        }
    }

    func handle(_ msg: Link.Message, _ data: Data?) {
        switch msg {
        case .laugh: laugh()
        case .quit: NSApp.terminate(nil)
        case .play: celebrate(data.flatMap { String(data: $0, encoding: .utf8) } ?? "laugh", text: nil)
        case .hook: hook(data)
        }
    }

    func laugh() { celebrate("laugh", text: nil) }

    private func hook(_ data: Data?) {
        guard let data, let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let f = sessions.handle(e), f.tier != .none {
            celebrate(f.tier == .huge ? "roll" : "laugh", text: "\(f.project) 做完了 · \(Sessions.duration(f.seconds))")
        }
        render()
    }

    // MARK: 片段

    /// 笑：先拉回全身，再播
    private func celebrate(_ name: String, text: String?) {
        guard let c = clips[name] else { return }
        if celebrating {
            // 正在拉回全身马上就笑；正在笑就不打断，快笑完了再来一次就从头笑
            guard let p = playing, CACurrentMediaTime() - p.start >= p.player.duration * 0.8 else { return }
        }
        celebrating = true
        stopMinorClip()
        blinkTimer?.invalidate()
        blinkTimer = nil
        if let text {
            bubbleIsWaiting = false
            bubble.show(text, above: panel.frame, for: c.duration + 1.5)
        }
        frame(.full, animated: true) { [weak self] in
            self?.play(name, important: true) {
                self?.celebrating = false
                self?.render()
            }
        }
    }

    private func play(_ name: String, important: Bool, then: (() -> Void)? = nil) {
        guard let c = clips[name] else { return }
        playing?.player.stop()
        blinkTimer?.invalidate()
        blinkTimer = nil
        playing = (name, c, important, CACurrentMediaTime())
        if frameTimer == nil {
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                if let img = self?.playing?.player.nextFrame() { self?.view.show(img) }
            }
            RunLoop.main.add(t, forMode: .common)
            frameTimer = t
        }
        c.play { [weak self] in
            guard let self, self.playing?.player === c else { return }
            self.playing = nil
            self.frameTimer?.invalidate()
            self.frameTimer = nil
            if let then { then() } else { self.render() }
        }
    }

    /// 停掉眨眼这种可以随时打断的小片段
    private func stopMinorClip() {
        guard let p = playing, !p.important else { return }
        p.player.stop()
        playing = nil
        frameTimer?.invalidate()
        frameTimer = nil
    }

    /// 按当前状态摆好奶蛙。正在笑就等笑完（笑完会再调一次）
    private func render() {
        if celebrating { return }
        let mood = sessions.mood
        if mood == .waiting {
            if let t = sessions.waitingText, bubble.text != t || !bubbleIsWaiting {
                bubbleIsWaiting = true
                bubble.show(t, above: panel.frame)
            }
            blinkTimer?.invalidate()
            blinkTimer = nil
            stopMinorClip()
            // 和原片一样一刀切：侧脸特写 → 转过来直勾勾看着你
            view.show(clips["glance"]?.last)
            frame(.look, animated: false)
            return
        }
        if bubbleIsWaiting {
            bubbleIsWaiting = false
            bubble.hide()
        }
        if mood == .working {
            if shot != .side {
                stopMinorClip()
                view.show(clips["focus"]?.first)
                frame(.side, animated: shot == .full)   // 从全身慢慢推近；从转头特写一刀切回侧脸
            }
            scheduleBlink()
        } else {
            blinkTimer?.invalidate()
            blinkTimer = nil
            stopMinorClip()
            view.show(clips["focus"]?.first)
            if shot != .full { frame(.full, animated: true) }
        }
    }

    /// 干活的时候隔几秒眨一下眼（片段在当前取景里播，还是侧脸特写）
    private func scheduleBlink() {
        guard blinkTimer == nil else { return }
        blinkTimer = Timer.scheduledTimer(withTimeInterval: .random(in: 2.5...5.5), repeats: false) { [weak self] _ in
            guard let self else { return }
            self.blinkTimer = nil
            if self.playing == nil, !self.celebrating, self.sessions.mood == .working {
                self.play("focus", important: false)
            } else {
                self.render()
            }
        }
    }

    // MARK: 取景（惊鸿一瞥）

    private func frame(_ shot: Shot, animated: Bool, then: (() -> Void)? = nil) {
        let changed = self.shot != shot
        self.shot = shot
        let rect = closeups[shot] ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        view.setCrop(rect, duration: animated && changed ? (shot == .full ? 0.3 : 0.8) : 0, then: then)
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

    func savePosition() { Prefs.origin = panel.frame.origin }

    func followBubble() { bubble.follow(panel.frame, animated: false) }

    func resize(to size: CGFloat) {
        // 脚底中点不动
        let f = panel.frame
        let origin = NSPoint(x: f.midX - size / 2, y: f.minY)
        Prefs.size = size
        Prefs.origin = origin
        panel.setFrame(NSRect(origin: origin, size: CGSize(width: size, height: size)), display: true)
        followBubble()
    }

    func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(item("笑一下") { [weak self] in self?.laugh() })
        m.addItem(item("笑到打滚") { [weak self] in self?.celebrate("roll", text: nil) })
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

    /// 只显示画面里的这一块（0–1 的比例，原点在左上），duration > 0 时像镜头推拉一样过去
    func setCrop(_ r: CGRect, duration: Double, then: (() -> Void)? = nil) {
        guard let layer else { then?(); return }
        // contentsRect 的原点在图片左下角
        let target = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        CATransaction.begin()
        CATransaction.setCompletionBlock { then?() }
        if duration > 0 {
            let a = CABasicAnimation(keyPath: "contentsRect")
            a.fromValue = NSValue(rect: (layer.presentation() ?? layer).contentsRect)
            a.toValue = NSValue(rect: target)
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(a, forKey: "crop")
        } else {
            CATransaction.setDisableActions(true)
            layer.removeAnimation(forKey: "crop")
        }
        layer.contentsRect = target
        CATransaction.commit()
    }

    /// 屏幕坐标这一点上奶蛙是不是实心的（透明处让鼠标穿过去）
    func isOpaque(atScreen p: NSPoint) -> Bool {
        guard let win = window, let img = image, let crop = layer?.contentsRect else { return false }
        let local = convert(win.convertPoint(fromScreen: p), from: nil)
        let u = crop.minX + local.x / bounds.width * crop.width
        let v = crop.minY + local.y / bounds.height * crop.height   // 从下往上
        let x = Int(u * CGFloat(img.width)), y = Int((1 - v) * CGFloat(img.height))
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
        pet?.followBubble()
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            pet?.savePosition()
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
