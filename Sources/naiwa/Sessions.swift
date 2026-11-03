import Foundation

/// 根据 Claude Code 的 hook 事件给每个会话记账，判断奶蛙该是什么状态、一轮结束时值不值得笑。
/// 全在本地算，不调模型。
final class Sessions {
    enum Mood { case idle, working, waiting }
    enum Tier { case none, big, huge }

    struct Session {
        var cwd: String
        var start: Date?          // 这一轮开始干活的时间（用户发消息，或者第一次调工具）
        var tools = 0             // 这一轮调了几次工具
        var waiting: String?      // 在等你批准什么
        var seen = Date()
    }

    struct Finished {
        let tier: Tier
        let project: String
        let seconds: TimeInterval
    }

    private(set) var all: [String: Session] = [:]

    var mood: Mood {
        prune()
        if all.values.contains(where: { $0.waiting != nil }) { return .waiting }
        if all.values.contains(where: { $0.start != nil }) { return .working }
        return .idle
    }

    /// 等你的那个会话：项目名和在等什么
    var waitingText: String? {
        guard let s = all.values.filter({ $0.waiting != nil }).max(by: { $0.seen < $1.seen }) else { return nil }
        return "\(Self.project(s.cwd)) \(s.waiting!)"
    }

    /// 处理一条 hook 事件；一轮结束时返回这一轮的结果
    func handle(_ e: [String: Any]) -> Finished? {
        guard let event = e["hook_event_name"] as? String, let id = e["session_id"] as? String else { return nil }
        let now = Date()
        var s = all[id] ?? Session(cwd: e["cwd"] as? String ?? "")
        if let cwd = e["cwd"] as? String { s.cwd = cwd }
        s.seen = now
        var finished: Finished?
        switch event {
        case "UserPromptSubmit":
            s.start = now
            s.tools = 0
            s.waiting = nil
        case "PreToolUse":
            s.waiting = nil
            s.tools += 1
            if s.start == nil { s.start = now }
        case "PostToolUse", "PostToolUseFailure":
            s.waiting = nil
        case "Notification":
            s.waiting = Self.waitingReason(e["message"] as? String ?? "")
        case "Stop":
            // naiwa_seconds：`naiwa demo` 用来假装这一轮跑了多久
            let seconds = e["naiwa_seconds"] as? Double ?? s.start.map { now.timeIntervalSince($0) } ?? 0
            finished = Finished(tier: Self.tier(seconds: seconds, tools: s.tools), project: Self.project(s.cwd), seconds: seconds)
            s.start = nil
            s.tools = 0
            s.waiting = nil
        case "SessionEnd":
            all[id] = nil
            return nil
        default:
            break
        }
        all[id] = s
        return finished
    }

    /// 跑满 bigSeconds 且动过工具才算干完一个活；跑满 hugeSeconds 算超长任务。只聊了几句不算
    static func tier(seconds: TimeInterval, tools: Int) -> Tier {
        guard tools > 0, seconds >= Prefs.bigSeconds else { return .none }
        return seconds >= Prefs.hugeSeconds ? .huge : .big
    }

    /// Claude 闲着等你回话 60 秒后也会发 Notification（「waiting for your input」），那不算在等你确认，不然
    /// 做完的会话放着不管，奶蛙会一直放大盯着你
    static func waitingReason(_ message: String) -> String? {
        if message.localizedCaseInsensitiveContains("waiting for your input") { return nil }
        if let r = message.range(of: #"permission to use (\S+)"#, options: .regularExpression) {
            let tool = message[r].split(separator: " ").last.map(String.init) ?? ""
            return "等你批准 \(tool)"
        }
        return "等你确认"
    }

    static func project(_ cwd: String) -> String {
        if cwd.isEmpty { return "Claude" }
        if cwd == FileManager.default.homeDirectoryForCurrentUser.path { return "~" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分 \(s % 60) 秒" }
        return "\(s / 3600) 小时 \(s % 3600 / 60) 分"
    }

    /// 会话没收到 Stop 就没了（Claude 被杀掉之类），半小时没动静就不算它还在干活
    private func prune() {
        let now = Date()
        for (id, s) in all where (s.start != nil || s.waiting != nil) && now.timeIntervalSince(s.seen) > 1800 {
            all[id]?.start = nil
            all[id]?.waiting = nil
        }
    }
}
