# 奶蛙桌宠 naiwa-pet

一只住在 Mac 桌面角落、跟着 Claude Code 干活的奶蛙：Claude 一开工，它推近成「惊鸿一瞥」的侧脸特写；Claude 要你批准时，它转过来直勾勾盯着你；活干完了，它拉回全身捧腹大笑。

原生 Swift，整个 App 1.8MB，没有声音，不抢焦点，不花 token。

<p align="center"><img src="docs/demo.gif" width="280" alt="空闲 → 惊鸿一瞥 → 眨眼 → 等你批准 → 捧腹大笑"></p>

## 各种样子

![五种样子](docs/states.png)

| 什么时候 | 奶蛙 |
|---|---|
| 没有会话在跑 | 全身侧身站着，一动不动 |
| Claude 在干活 | **惊鸿一瞥**：镜头慢慢推近到侧脸和眼睛的特写，隔几秒眨一下眼 |
| Claude 等你批准（要权限、MCP 弹窗问你） | 一下子转过来直勾勾看着你，头顶「my-repo 等你批准 Bash」，你处理完它转回去 |
| 干完一个活（这一轮跑满 1 分钟，且读写过文件或跑过命令） | 拉回全身**捧腹大笑**，头顶「my-repo 做完了 · 4 分 12 秒」 |
| 超长任务（跑满 10 分钟） | 笑到**倒地打滚** |
| 只聊了几句 / 说完话没理它 | 不打扰 |
| 你摸它、点它 | 也笑 |

## 特色

- **小**：原生 Swift + AppKit，没有 Electron、没有第三方依赖。App 1.8MB；空闲时不跑任何定时器，CPU 0%；Claude 干活时约 3%（只有眨眼）。
- **原汁原味**：画面全部来自原版《奶蛙大笑》视频，没有重画、没有自己建模。头部特写用 Real-ESRGAN 超分过，推近也不糊。
- **懂 Claude Code**：给每个会话单独记账，只有真干完一个活才笑，大活捧腹、超长任务打滚，聊两句不打扰；同时开好几个会话，气泡会标出是哪个项目。判断全在本地，不调模型、不花 token，每次钩子约 5 毫秒。
- **不打扰**：没有声音，没有 Dock 图标，点它不会抢走焦点，透明的地方鼠标直接穿过去，不挡你点后面的窗口。
- **只动它该动的配置**：接入 Claude Code 时只往 `settings.json` 里插几条，写之前逐字段核对其他内容完全不变，一条命令就能撤掉。

## 安装

需要 macOS 13 以上，以及 Command Line Tools（没装的话运行 `xcode-select --install`）。不需要 Xcode。

```bash
git clone git@github.com:nwverse/naiwa-pet.git
cd naiwa-pet
scripts/install.sh       # 编译并装好：~/Applications/Naiwa.app，命令 ~/.local/bin/naiwa，登录时自动出现
naiwa hooks install      # 接入 Claude Code
naiwa demo               # 演示一遍所有样子
```

- 奶蛙默认待在屏幕右下角、Dock 上方，拖动可以换位置，它会记住。
- 如果提示 `~/.local/bin` 不在 PATH 里，按提示把那一行加进 `~/.zshrc`。
- 接入后对新的 Claude Code 会话生效；已经开着的会话一般也会马上生效，没反应就重开一下。
- 是从源码本地编译的，不经过下载，所以不会被 macOS 的「无法验证开发者」拦住。

卸载：`scripts/uninstall.sh`。它会撤掉 Claude Code 接入、关掉奶蛙，并删掉 App、命令、登录自启和偏好设置。

## 用法

| 操作 | 效果 |
|---|---|
| 点一下，或者在它身上来回蹭几下 | 捧腹大笑 |
| 拖动 | 换位置 |
| 右键 | 笑一下 / 笑到打滚 / 大小（小、中、大、特大）/ 让它走 |
| `naiwa demo` | 演示：干活 → 等你批准 → 干完大笑 → 超长任务打滚 |
| `naiwa laugh` / `naiwa play roll` | 笑一下 / 笑到打滚 |
| `naiwa` | 把它叫出来（右键「让它走」之后，`naiwa laugh` 不会再把它叫回来） |
| `naiwa quit` | 关掉 |
| `naiwa hooks install` / `uninstall` | 接入 / 撤掉 Claude Code |

改「干完一个活」的门槛（默认 60 秒、超长任务 600 秒）：

```bash
defaults write com.nwverse.naiwa bigSeconds -float 30
defaults write com.nwverse.naiwa hugeSeconds -float 300
```

## 和 Claude Code 怎么对上的

`naiwa hooks install` 在 `~/.claude/settings.json` 的六个事件里各加一条 `naiwa hook`，每次触发时把事件转给奶蛙：

| 事件 | 奶蛙记下什么 |
|---|---|
| `UserPromptSubmit` | 这一轮开始了，开始计时 |
| `PreToolUse` / `PostToolUse` | 动了工具；要是刚才在等你批准，说明你批准了 |
| `Notification` | 看 `notification_type`：`permission_prompt`、`elicitation_dialog`、`agent_needs_input` 算「等你」；`idle_prompt`（说完 60 秒你没理它）等其他提醒不算 |
| `Stop` | 这一轮结束：跑满门槛并且动过工具就笑，否则什么都不做 |
| `SessionEnd` | 会话关了，不再记它 |

已知局限：Claude 中途停下来等后台任务、或者停下来问你问题，从事件上看和「做完了」一样，只要时长够、动过工具也会笑。

**Codex**：只能接 `notify`，它只在一轮结束时通知，所以只能做到「做完就笑」，没有干活、等你这些状态。在 `~/.codex/config.toml` 最上面加 `notify = ["/Users/你/.local/bin/naiwa", "laugh"]`。Codex 只认一个 notify，已经有的话要自己串起来。

**其他命令行**：长任务后面接一句就行，比如 `make build; naiwa laugh`。

## 素材怎么来的

```
scripts/fetch_source.sh    从 B 站下载《奶蛙大笑（额外扩展版）》（BV1JBuB6PEMF，480P）
scripts/make_assets.py     切成四段 → rembg 抠白底 → 统一裁成方形
                           → 要推近成特写的两段先用 Real-ESRGAN 放大 4 倍再抠（768px），其余 384px
                           → 预乘透明度编成带透明通道的 HEVC（assets/*.mov，合计约 1.2MB）
                           → 算出侧脸、转头两张特写的取景框写进 assets.json
```

| 片段 | 原片 | 用在 |
|---|---|---|
| focus | 0.55–1.15 秒：侧身盯着前方，眨一下眼 | 第一帧是平时的全身站姿；干活时在侧脸特写里隔几秒播一次 |
| glance | 1.90–2.13 秒：原片在 2.08 秒一刀切成四分之三正面、直直看着你 | 等你批准时，用最后一帧的特写 |
| laugh | 2.15–6.20 秒：闭眼开笑，仰头笑、弯腰笑、正面捧着肚子笑 | 干完一个活 |
| roll | 2.15–3.90 + 72.0–77.6 秒：开笑后剪到片尾的仰面摔倒、躺地打滚（两段都是仰头大笑，接得上） | 超长任务 |

- 「惊鸿一瞥」这个梗，是镜头推近到奶蛙的侧脸和一只眼睛（比如 B 站「人生若只如初见，惊鸿一瞥」那条）。这里直接用原片的侧身站姿推近到头部来做，推近用的是图层的 `contentsRect` 动画，窗口大小不变。
- 四段用同一个裁剪框，高清和普通两种分辨率取景完全一致，切换状态时奶蛙不会忽大忽小。
- 状态之间除了推拉镜头都是硬切。原片开笑本来就是硬切，「突然笑、突然停」；淡出会把两个姿势叠出重影。
- 抠图用 rembg 的 `isnet-general-use`：侧身时奶白肚皮正好在轮廓边上、颜色又接近白底，按颜色抠会把肚皮一起吃掉。
- 超分用 `realesrgan-x4plus`：anime 系列会给轮廓描黑边，不像原片的软胶质感。
- 试过但放弃的路：视频模型（Seedance）会因为奶蛙造型被内容审核拦掉；自己拿 3D 模型做动作，笑起来不像原梗；带原声太吵。

### 版权

奶蛙有官方作者（设计师李想，milkyfrog.com，「保留所有权利」）。这里的画面来自网上转载的原片，不是本仓库原创，**只限团队内部使用，不要公开发布、不要商用**。

## 开发

```bash
swift build -c release
NAIWA_ASSETS=$PWD/assets .build/release/naiwa      # 直接跑，不用打包
scripts/build_app.sh                               # 打包 build/Naiwa.app（Intel + Apple 芯片通用）

# 重新生成素材（需要 ffmpeg、rembg、realesrgan-ncnn-vulkan）
scripts/fetch_source.sh
REALESRGAN=<realesrgan-ncnn-vulkan 所在目录> python3 scripts/make_assets.py build/src/laugh_ext_480.mp4
```

代码在 `Sources/naiwa/`：

- `Pet.swift`：窗口、状态机（笑 > 等你 > 干活 > 空闲）、取景推拉、鼠标交互
- `Sessions.swift`：按钩子事件给每个会话记账，判断状态和这一轮值不值得笑
- `Assets.swift`：读素材，播放片段（系统硬件解码后按帧取出贴到图层）
- `Bubble.swift`：头顶气泡
- `Link.swift`：命令行和桌宠之间的通道（具名 CFMessagePort，顺带保证只有一只），以及 `naiwa hook` / `demo` 和偏好设置
- `Hooks.swift`：`naiwa hooks install / uninstall`

灵感来自 [dsh-pet](https://github.com/PC2005-cloud/dsh-pet)（没有使用它的代码和素材）。
