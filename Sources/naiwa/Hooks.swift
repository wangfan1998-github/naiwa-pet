import Foundation

/// 接入 Claude Code：在 ~/.claude/settings.json 的 hooks.Stop 里加一条 `naiwa laugh`。
///
/// 只在原文里插入一小段文本，不整体重写，免得把用户的格式和键顺序打乱；
/// 写之前解析新旧两份，确认除了这一条以外完全一样才落盘，并留一份备份。
enum Hooks {
    static func main(_ args: [String]) {
        do {
            switch args.first {
            case "install": try install()
            case "uninstall": try uninstall()
            default: printSnippets()
            }
        } catch {
            FileHandle.standardError.write(Data("naiwa: \(error)\n".utf8))
            exit(1)
        }
    }

    static var settings: URL {
        if let path = ProcessInfo.processInfo.environment["NAIWA_CLAUDE_SETTINGS"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// 写进钩子里的命令：优先用 PATH 上的 naiwa，找不到就用当前可执行文件的绝对路径
    static var command: String {
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("naiwa").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let quoted = path.contains(" ") ? "'\(path)'" : path
        return "\(quoted) laugh"
    }

    static var entry: String {
        let cmd = String(data: try! JSONSerialization.data(withJSONObject: [command], options: [.withoutEscapingSlashes]), encoding: .utf8)!
            .dropFirst().dropLast()
        return #"{"hooks": [{"type": "command", "command": \#(cmd)}]}"#
    }

    static func install() throws {
        let fm = FileManager.default
        let text = (try? String(contentsOf: settings, encoding: .utf8)) ?? "{}\n"
        let old = try parse(text)
        if isInstalled(old) {
            print("已经接入过了：\(settings.path)")
            return
        }
        guard let new = insert(into: text) else { throw Failure("没找到能插入的位置，请手动加，见 `naiwa hooks`") }
        var expected = old
        var hooks = expected["hooks"] as? [String: Any] ?? [:]
        hooks["Stop"] = [try parse(entry)] + (hooks["Stop"] as? [Any] ?? [])
        expected["hooks"] = hooks
        guard NSDictionary(dictionary: try parse(new)).isEqual(to: expected) else {
            throw Failure("插入后内容和预期不一致，没有写入。请手动加，见 `naiwa hooks`")
        }
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settings.path) {
            let backup = settings.path + ".bak-naiwa"
            try? fm.removeItem(atPath: backup)
            try fm.copyItem(atPath: settings.path, toPath: backup)
        }
        try new.write(to: settings, atomically: true, encoding: .utf8)
        print("已接入 Claude Code：每次任务做完，奶蛙捧腹大笑。\n  \(settings.path) → hooks.Stop 加了 `\(command)`（原文件备份在 .bak-naiwa）")
    }

    static func uninstall() throws {
        let text = try String(contentsOf: settings, encoding: .utf8)
        let old = try parse(text)
        guard isInstalled(old) else {
            print("没有接入过")
            return
        }
        for candidate in [entry + ",", entry] where text.contains(candidate) {
            let new = text.replacingOccurrences(of: candidate, with: "")
            if let parsed = try? parse(new), !isInstalled(parsed) {
                try new.write(to: settings, atomically: true, encoding: .utf8)
                print("已撤掉：\(settings.path)")
                return
            }
        }
        throw Failure("settings.json 被重新排版过，找不到原样那一段。请手动删掉 hooks.Stop 里含 `naiwa laugh` 的那条")
    }

    /// 在 hooks.Stop 数组开头插入；没有 Stop 就在 hooks 里加；没有 hooks 就在最外层加
    static func insert(into text: String) -> String? {
        func sep(after i: String.Index, close: Character) -> String {
            text[i...].first { !$0.isWhitespace } == close ? "" : ","
        }
        if let hooks = text.range(of: #""hooks"\s*:\s*\{"#, options: .regularExpression) {
            if let stop = text.range(of: #""Stop"\s*:\s*\["#, options: .regularExpression, range: hooks.upperBound..<text.endIndex) {
                return text.replacingCharacters(in: stop.upperBound..<stop.upperBound, with: entry + sep(after: stop.upperBound, close: "]"))
            }
            return text.replacingCharacters(in: hooks.upperBound..<hooks.upperBound,
                                            with: #""Stop": ["# + entry + "]" + sep(after: hooks.upperBound, close: "}"))
        }
        guard let brace = text.firstIndex(of: "{") else { return nil }
        let at = text.index(after: brace)
        return text.replacingCharacters(in: at..<at, with: #""hooks": {"Stop": ["# + entry + "]}" + sep(after: at, close: "}"))
    }

    static func isInstalled(_ settings: [String: Any]) -> Bool {
        let stop = (settings["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]] ?? []
        return stop.contains { group in
            (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains("naiwa") == true && ($0["command"] as? String)?.hasSuffix(" laugh") == true }
        }
    }

    static func parse(_ text: String) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw Failure("settings.json 不是一个 JSON 对象")
        }
        return obj
    }

    static func printSnippets() {
        print("""
        Claude Code（~/.claude/settings.json，或者直接 `naiwa hooks install`）：
          "hooks": { "Stop": [ \(entry) ] }

        Codex（~/.codex/config.toml 最上面，[xxx] 表之前；已经有 notify 的话只能留一个）：
          notify = ["\(command.replacingOccurrences(of: " laugh", with: "").replacingOccurrences(of: "'", with: ""))", "laugh"]

        其他任何命令行：长任务后面接一句
          make build; naiwa laugh
        """)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ s: String) { description = s }
    }
}
