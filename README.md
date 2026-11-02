# naiwa-pet

桌面上的一只奶蛙。平时面无表情地站着；摸它一下，或者 Claude Code 做完一个任务，它就捧腹大笑一次，带笑声。

- 原生 Swift，没有 Electron，没有 Dock 图标。整个 App 约 700KB
- 站着不动时不跑任何定时器，CPU 0%；笑的那 4 秒用系统硬件解码视频
- 画面和笑声就是原版奶蛙捧腹大笑
- 透明的地方鼠标直接穿过去，不挡你点后面的窗口；点它不会抢走焦点
- 一个 `naiwa` 命令：既是桌宠本体，也是命令行开关

## 安装

需要 macOS 13+ 和 Command Line Tools（`xcode-select --install`），不需要 Xcode。

```bash
git clone git@github.com:nwverse/naiwa-pet.git && cd naiwa-pet
scripts/install.sh          # 装到 ~/Applications/Naiwa.app，命令链接到 ~/.local/bin/naiwa，登录时自动出现
naiwa hooks install         # 接入 Claude Code：每次任务做完它就笑
```

## 用法

| 操作 | 效果 |
|---|---|
| 点一下，或者在它身上来回蹭几下 | 捧腹大笑 |
| 拖动 | 换位置（会记住） |
| 右键 | 笑一下 / 笑声开关 / 大小 / 让它走 |
| `naiwa laugh` | 笑一下；没开着会自动打开（从菜单里让它走过就不会） |
| `naiwa quit` | 关掉 |

### 接入 Claude Code

`naiwa hooks install` 会在 `~/.claude/settings.json` 的 `hooks.Stop` 里加一条 `naiwa laugh`，Claude 每做完一轮它就笑。只插入这一条，不重排你的配置，原文件备份为 `settings.json.bak-naiwa`；`naiwa hooks uninstall` 撤掉。

### 接入 Codex 和其他命令

Codex 在 `~/.codex/config.toml` 最上面加 `notify = ["/Users/你/.local/bin/naiwa", "laugh"]`（Codex 只认一个 notify，已经有的话要自己串起来）。

其他任何长任务，后面接一句就行：`make build; naiwa laugh`。`naiwa hooks` 会打印这几段配置。

## 素材怎么做的

直接用原版《奶蛙大笑》的画面和声音，不自己建模、不重画。

```
scripts/fetch_source.sh    从 B 站下载《奶蛙大笑（额外扩展版）》（BV1JBuB6PEMF，480P）
scripts/make_assets.py     截 2.0–6.2 秒 → rembg 抠白底 → 统一裁成方形 320px
                           → 预乘透明度编成带透明通道的 HEVC（assets/laugh.mov，约 200KB）
                           → 同一段原声（assets/laugh.m4a，口型和笑声天然对齐）
```

- 这一段是：侧身面无表情地站着 → 0.1 秒后突然眯眼张嘴爆笑 → 仰头笑、弯腰笑、正面捧着肚子笑，4.2 秒。
- 笑完硬切回第一帧（站姿）。原片开笑就是硬切，「突然笑、突然停」；淡出会把两个姿势叠出重影。
- 视频第一帧兼作平时的站姿图，和笑的时候走同一条解码路径，开始笑时颜色不会跳。
- 抠图用 rembg 的 `isnet-general-use`：侧身时奶白肚皮正好在轮廓边上、颜色又接近白底，按颜色泛洪会把肚皮一起吃掉。
- 试过的弯路：视频模型（Seedance）会因为奶蛙造型被内容审核拦掉；自己拿 3D 模型做动作，笑起来不像原梗。

画面和笑声都来自网络上的奶蛙梗视频（上传者注明「视频与音频源于网络」），不是本仓库原创，仅供团队内部使用，不要商用。

## 开发

```bash
swift build -c release
NAIWA_ASSETS=$PWD/assets .build/release/naiwa      # 直接跑，不用打包
scripts/build_app.sh                               # 打包 build/Naiwa.app（Intel + Apple 芯片通用）
```

代码在 `Sources/naiwa/`：`Pet.swift` 是窗口、播放和鼠标交互；`Link.swift` 是命令行和桌宠之间的通道（具名 CFMessagePort，同时保证只有一只）和偏好设置；`Hooks.swift` 管 Claude Code 接入。

灵感来自 [dsh-pet](https://github.com/PC2005-cloud/dsh-pet)（没有使用它的代码和素材）。
