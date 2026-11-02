import AppKit

/// 素材目录：
///   laugh.json  {"audioDelay": 0.28}
///   laugh.mov   捧腹大笑，带透明通道的 HEVC；第一帧和最后一帧都是平时站着的样子
///   laugh.m4a   笑声
struct Assets {
    let dir: URL
    let audioDelay: Double
    var video: URL { dir.appendingPathComponent("laugh.mov") }
    var sound: URL? {
        let u = dir.appendingPathComponent("laugh.m4a")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static func load() -> Assets? {
        for dir in candidates() where FileManager.default.fileExists(atPath: dir.appendingPathComponent("laugh.mov").path) {
            let meta = (try? Data(contentsOf: dir.appendingPathComponent("laugh.json")))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return Assets(dir: dir, audioDelay: meta["audioDelay"] as? Double ?? 0)
        }
        return nil
    }

    /// NAIWA_ASSETS → Naiwa.app/Contents/Resources/assets → 从可执行文件往上找仓库里的 assets/
    private static func candidates() -> [URL] {
        var out: [URL] = []
        if let env = ProcessInfo.processInfo.environment["NAIWA_ASSETS"] {
            out.append(URL(fileURLWithPath: env))
        }
        if let res = Bundle.main.resourceURL {
            out.append(res.appendingPathComponent("assets"))
        }
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        for _ in 0..<5 {
            out.append(dir.appendingPathComponent("assets"))
            dir.deleteLastPathComponent()
        }
        return out
    }
}
