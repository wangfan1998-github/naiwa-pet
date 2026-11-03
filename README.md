# naiwa-pet

桌面上的一只奶蛙，跟着 Claude Code 干活：

| Claude 在干嘛 | 奶蛙 |
|---|---|
| 没事 | 侧身站着，一动不动 |
| 在干活 | 专注：侧身盯着前方，隔几秒眨一下眼 |
| 等你批准（权限确认） | 放大，一下子转过来看着你（惊鸿一瞥），头顶「music_viking 等你批准 Bash」，你处理完缩回去 |
| 干完一个活（跑满 1 分钟且动过工具） | 捧腹大笑，带原声，头顶「music_viking 做完了 · 4 分 12 秒」 |
| 超长任务（跑满 10 分钟） | 笑到倒地打滚 |
| 只聊了几句 | 不打扰 |

摸它一下也会笑。`naiwa demo` 能把上面这些演示一遍。

- 原生 Swift，没有 Electron，没有 Dock 图标。整个 App 约 700KB
- 站着不动时不跑任何定时器，CPU 0%；动起来用系统硬件解码视频
- 画面和笑声全部来自原版《奶蛙大笑》，不自己建模、不重画
- 判断「干完了」全在本地：按每个会话的时长和有没有调工具算，不调模型、不花 token；每次 hook 约 5 毫秒
- 透明的地方鼠标直接穿过去，不挡你点后面的窗口；点它不会抢走焦点
- 一个 `naiwa` 命令：既是桌宠本体，也是命令行开关

## 安装

需要 macOS 13+ 和 Command Line Tools（`xcode-select --install`），不需要 Xcode。

```bash
git clone git@github.com:nwverse/naiwa-pet.git && cd naiwa-pet
scripts/install.sh          # 装到 ~/Applications/Naiwa.app，命令链接到 ~/.local/bin/naiwa，登录时自动出现
naiwa hooks install         # 接入 Claude Code
naiwa demo                  # 演示一遍所有状态
```

## 用法

| 操作 | 效果 |
|---|---|
| 点一下，或者在它身上来回蹭几下 | 捧腹大笑 |
| 拖动 | 换位置（会记住） |
| 右键 | 笑一下 / 笑声开关 / 大小 / 让它走 |
| `naiwa laugh` / `naiwa play roll` | 笑一下 / 笑到打滚；没开着会自动打开（从菜单里让它走过就不会） |
| `naiwa demo` | 演示：专注 → 等你批准 → 干完大笑 → 超长任务打滚 |
| `naiwa quit` | 关掉 |

### 接入 Claude Code

`naiwa hooks install` 在 `~/.claude/settings.json` 的 `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`Notification`、`Stop`、`SessionEnd` 里各加一条 `naiwa hook`。奶蛙拿到事件自己给每个会话记账：

- 一轮从你发消息算起，`Stop` 时跑满 60 秒、并且调过工具，才算干完一个活；满 600 秒算超长任务。改门槛：`defaults write com.nwverse.naiwa bigSeconds -float 30`（`hugeSeconds` 同理）
- `Notification` 里的权限请求算「等你」；Claude 闲着等你回话的提醒不算，不然做完的会话放着不管，它会一直放大盯着你
- 同时开好几个会话也没问题，气泡里写的是哪个项目

只插入这几条，不重排你的配置，原文件备份为 `settings.json.bak-naiwa`；`naiwa hooks uninstall` 撤掉。新开的 Claude Code 会话才生效。

已知局限：Claude 中途停下来等后台任务、或者停下来问你问题，从事件上看和「做完了」一样，只要时长够、动过工具也会笑。

### 接入 Codex 和其他命令

Codex 在 `~/.codex/config.toml` 最上面加 `notify = ["/Users/你/.local/bin/naiwa", "laugh"]`（Codex 只认一个 notify，已经有的话要自己串起来）。

其他任何长任务，后面接一句就行：`make build; naiwa laugh`。`naiwa hooks` 会打印这几段配置。

## 素材怎么做的

直接用原版《奶蛙大笑》的画面和声音，不自己建模、不重画。

```
scripts/fetch_source.sh    从 B 站下载《奶蛙大笑（额外扩展版）》（BV1JBuB6PEMF，480P）
scripts/make_assets.py     切成四段 → rembg 抠白底 → 统一裁成方形 320px
                           → 预乘透明度编成带透明通道的 HEVC（assets/*.mov，合计约 500KB）+ 同段原声
```

| 片段 | 原片 | 用在 |
|---|---|---|
| focus 专注 | 0.00–1.10 秒：侧身盯着前方，中间眨一下眼 | 干活中，隔几秒播一次；第一帧也是平时的站姿 |
| glance 惊鸿一瞥 | 1.90–2.13 秒：原片在 2.08 秒一刀切成四分之三正面、直直看着你 | 等你批准，放大后播，停在最后一帧 |
| laugh 捧腹大笑 | 2.15–6.20 秒：闭眼开笑，仰头笑、弯腰笑、正面捧着肚子笑 | 干完一个活 |
| roll 笑到打滚 | 2.15–3.90 + 72.0–77.6 秒：开笑后剪到片尾的仰面摔倒、躺地打滚（两段都是仰头大笑的姿势，接得上） | 超长任务 |

- 四段用同一个裁剪框，切换状态时奶蛙不会忽大忽小。
- 状态之间都是硬切：原片开笑就是硬切，「突然笑、突然停」；淡出会把两个姿势叠出重影。
- 抠图用 rembg 的 `isnet-general-use`：侧身时奶白肚皮正好在轮廓边上、颜色又接近白底，按颜色泛洪会把肚皮一起吃掉；仰面躺地时也一样。
- 「专注」不是现成的梗：原片里不笑的部分只有开头 2 秒，所以专注和空闲长得一样，区别是专注会眨眼。
- 试过的弯路：视频模型（Seedance）会因为奶蛙造型被内容审核拦掉；自己拿 3D 模型做动作，笑起来不像原梗。

奶蛙有官方作者（设计师李想，milkyfrog.com，「保留所有权利」）。这里的画面和笑声都来自网上转载的原片，不是本仓库原创，只能团队内部用，不要公开发布、不要商用。

## 开发

```bash
swift build -c release
NAIWA_ASSETS=$PWD/assets .build/release/naiwa      # 直接跑，不用打包
scripts/build_app.sh                               # 打包 build/Naiwa.app（Intel + Apple 芯片通用）
```

代码在 `Sources/naiwa/`：

- `Pet.swift`：窗口、状态机（笑 > 等你 > 专注 > 空闲）、放大、鼠标交互
- `Sessions.swift`：按 hook 事件给每个会话记账，判断状态和这一轮值不值得笑
- `Assets.swift`：读素材、片段播放（硬件解码后按帧取出贴到图层）
- `Bubble.swift`：头顶气泡
- `Link.swift`：命令行和桌宠之间的通道（具名 CFMessagePort，同时保证只有一只）、`naiwa hook` / `demo`、偏好设置
- `Hooks.swift`：`naiwa hooks install / uninstall`

灵感来自 [dsh-pet](https://github.com/PC2005-cloud/dsh-pet)（没有使用它的代码和素材）。
