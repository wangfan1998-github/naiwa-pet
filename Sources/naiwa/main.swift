import AppKit

let usage = """
naiwa — 桌面上的奶蛙：Claude 干活时推近成侧脸特写（惊鸿一瞥），等你批准时转过来盯着你，干完一个活捧腹大笑。

用法：
  naiwa                 把奶蛙放到桌面上（已经在了就什么都不做）
  naiwa laugh           让它笑一下；没开着会自动打开（你从菜单退出过就不会）
  naiwa demo            演示一遍：干活（惊鸿一瞥）→ 等你批准 → 干完大笑 → 超长任务笑到打滚
  naiwa play roll       笑到倒地打滚（也可以 play laugh）
  naiwa quit            让它离开
  naiwa hooks install   接入 Claude Code
  naiwa hooks uninstall 撤掉接入
  naiwa hooks           打印 Claude Code / Codex 的接入配置
  naiwa hook            （给 Claude Code 的 hook 调用，从 stdin 读事件）

在奶蛙身上：点一下或来回摸几下 = 笑；拖动 = 换位置；右键 = 菜单。
一轮跑满 60 秒且动过工具才笑，满 10 分钟笑到打滚：defaults write com.nwverse.naiwa bigSeconds -float 30
"""

let args = Array(CommandLine.arguments.dropFirst())

switch args.first ?? "run" {
case "run":
    runPet(laughOnStart: args.contains("--laugh"))
case "laugh":
    // Codex 的 notify 会在最后追加一个 JSON 参数，这里不用它
    CLI.laugh()
case "quit":
    exit(Link.send(.quit) ? 0 : 1)
case "play":
    CLI.play(args.dropFirst().first ?? "laugh")
case "hook":
    CLI.hook()
case "demo":
    CLI.demo()
case "hooks":
    Hooks.main(Array(args.dropFirst()))
case "-h", "--help", "help":
    print(usage)
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}

func runPet(laughOnStart: Bool) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    guard Link.listen(handler: { msg, data in Pet.shared?.handle(msg, data) }) else {
        // 已经有一只在桌面上了
        if laughOnStart { _ = Link.send(.laugh) }
        exit(0)
    }
    Prefs.dismissed = false
    guard let assets = Assets.load() else {
        FileHandle.standardError.write(Data("naiwa: 找不到素材目录（设置 NAIWA_ASSETS 或用打包好的 Naiwa.app）\n".utf8))
        exit(1)
    }
    Pet.shared = Pet(assets: assets)
    Pet.shared?.show()
    if laughOnStart {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { Pet.shared?.laugh() }
    }
    app.run()
}
