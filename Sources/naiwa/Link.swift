import AppKit

/// 命令行和桌面上那只奶蛙之间的通道：一个具名 CFMessagePort。
/// 端口能连上 = 奶蛙在；同一个名字只能注册一次，顺带保证只有一只。
enum Link {
    enum Message: Int32 {
        case laugh = 1
        case quit = 2
    }

    static let portName = "com.nwverse.naiwa" as CFString
    private static var handler: ((Message) -> Void)?
    private static var port: CFMessagePort?

    /// 发给正在跑的奶蛙；没有在跑就返回 false。
    static func send(_ msg: Message) -> Bool {
        guard let remote = CFMessagePortCreateRemote(nil, portName) else { return false }
        return CFMessagePortSendRequest(remote, msg.rawValue, nil, 1, 0, nil, nil) == kCFMessagePortSuccess
    }

    /// 注册端口；名字被占了（已经有一只）返回 false。
    static func listen(handler: @escaping (Message) -> Void) -> Bool {
        self.handler = handler
        var ctx = CFMessagePortContext()
        guard let local = CFMessagePortCreateLocal(nil, portName, { _, id, _, _ in
            if let msg = Link.Message(rawValue: id) {
                DispatchQueue.main.async { Link.handler?(msg) }
            }
            return nil
        }, &ctx, nil) else { return false }
        port = local
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMessagePortCreateRunLoopSource(nil, local, 0), .commonModes)
        return true
    }
}

enum CLI {
    static func laugh() {
        if Link.send(.laugh) { exit(0) }
        // 用户从菜单里让它走了，就别被下一个任务又叫回来
        if Prefs.dismissed { exit(0) }
        launch(["run", "--laugh"])
        exit(0)
    }

    /// 在后台起一只奶蛙。打包成 .app 时走 open（交给 LaunchServices，跟调用方脱离关系），
    /// 开发时直接把自己拉起来，并脱离当前会话。
    static func launch(_ arguments: [String]) {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" {
            run("/usr/bin/open", ["-g", "-a", bundle.path, "--args"] + arguments)
            return
        }
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        for fd: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(&actions, fd, "/dev/null", fd == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let argv = ([exe.path] + arguments).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        posix_spawn(&pid, exe.path, &actions, &attr, argv, environ)
        argv.forEach { free($0) }
    }

    private static func run(_ path: String, _ arguments: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = arguments
        try? p.run()
        p.waitUntilExit()
    }
}

enum Prefs {
    // 在 Naiwa.app 里 standard 就是 com.nwverse.naiwa 这个域（拿自己的 bundle id 当 suite 名会返回 nil）；
    // 不在 .app 里跑（开发时、或者经过软链被找不到 bundle）时显式指定同一个域
    private static let d: UserDefaults = Bundle.main.bundleIdentifier == "com.nwverse.naiwa"
        ? .standard : UserDefaults(suiteName: "com.nwverse.naiwa")!

    static var dismissed: Bool {
        get { d.bool(forKey: "dismissed") }
        set { d.set(newValue, forKey: "dismissed") }
    }
    static var sound: Bool {
        get { d.object(forKey: "sound") as? Bool ?? true }
        set { d.set(newValue, forKey: "sound") }
    }
    static var size: CGFloat {
        get { d.object(forKey: "size") as? CGFloat ?? 110 }
        set { d.set(newValue, forKey: "size") }
    }
    static var origin: NSPoint? {
        get {
            guard let a = d.array(forKey: "origin") as? [CGFloat], a.count == 2 else { return nil }
            return NSPoint(x: a[0], y: a[1])
        }
        set { d.set(newValue.map { [$0.x, $0.y] }, forKey: "origin") }
    }
}
