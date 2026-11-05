# AGENTS.md

naiwa-pet：macOS 桌面上的奶蛙。空闲时按一天的时段换一只慢慢地动，Claude Code 干活时沉溺在水里、等你时睁眼转过来看你、干完惊鸿一瞥（镜头推近，斜着瞥你一眼）。用法和素材流程见 [README.md](README.md)。

## 约定

- `[必须]` 保持小：不引入第三方依赖，只用系统框架（AppKit、AVFoundation）。只有在播片段时才开取帧定时器；空闲和干活的循环只在窗口看得见时播，被挡住、锁屏、屏幕睡了、切走用户要停（`Pet.updateVisibility`）。锁屏时窗口遮挡状态仍是「看得见」，要听 `com.apple.screenIsLocked` / `screenIsUnlocked`，启动时也要先查一次。改播放相关代码后用 `top -pid` 量 CPU：现在播放约 3–4%（release），锁屏 0%。
- `[必须]` `naiwa hook` 必须快（现在约 5 毫秒）、不输出任何东西、永远返回 0。理由：Claude 每调一次工具都会先跑它。
- `[禁止]` 用模型判断「做完没有」：按时长和有没有调工具在本地算，不花 token。
- `[必须]` 透明的地方让鼠标穿过去，点奶蛙不抢焦点（`nonactivatingPanel` + 按当前帧的像素切换 `ignoresMouseEvents`）。改窗口或鼠标逻辑后，要在真机上确认点它背后的窗口还能点到。
- `[必须]` `naiwa hooks install` 只做文本插入，写之前确认新旧 settings.json 除了这一条以外完全一致。理由：这是别人的全局配置，不能重排、不能丢字段。
- `[禁止]` 仓库里出现内网地址、主机名、个人路径和 key。
- `[禁止]` 仓库里（代码、注释、README、配置、素材说明）出现原画作者的名字、主页或者「画：某某」之类的署名：用户 11-05 明确要求不署名、不声明。
- `[必须]` 奶蛙保持原梗的样子：不穿衣戴帽、不换脸；用户看过整幅画版本（戴帽子背吉他）说「不像奶娃」。换新画先给用户看静帧。`[禁止]` 用《蛙笑江湖》之类自建的 3D 模型或手写动作代替，笑起来不像。
- `[禁止]` 加声音：用户嫌吵。
- `[禁止]` README 里写参考了哪个项目、用了哪些工具和服务、素材是怎么做出来的：用户不想让别人知道思路。这些细节写在本文件和 `scripts/make_art.py` 里。
- README 里的动图是 `docs/pets/*.webp` 和 `docs/demo.webp`：带透明通道的动态 WebP（240px，GitHub 浅色、深色主题都干净；GIF 只有 1 位透明，边缘有锯齿）。加了新奶蛙要补一张。
- 悬停换只：空闲时指针停在奶蛙不透明处 0.7 秒换下一只（`Pet.pickNext`），离开整个窗口才能再来一次（换了形状以后指针可能落在透明处，不能算离开）；换出来的只管到下个时段。播放器只留当前这只和干活 / 等你 / 做完要用的。
- `[必须]` 哪个时段出来哪几只、干活时是哪只要能让用户自己换：默认安排写在 `art/pets.json`（打进 assets.json），用户的在 `~/.config/naiwa/config.json`（右键菜单读写、手改自动生效）。理由：用户说现在这套只是他自己的想法，别人可能喜欢别的。新加的奶蛙进 `art/pets.json` 的 clips 就会出现在菜单里，不要在代码里写死名字。
- 整个仓库（代码和素材）都是 MIT，见 LICENSE（用户 11-05 定的）。公开仓库是 nwverse/naiwa-pet，不放素材制作脚本和提示词（`scripts/make_art.py`、`art/`），也不放本文件里讲素材怎么做的部分。

## 踩过的坑

- Seedance：原画大约一半能过（沉溺、悠闲、云幻、缠线、晾衣、气球、漂浮、涟漪），其余被内容审核拒绝（安睡、听歌、封闭、孤独、花海，错误码 710092006「禁止该内容生成，不允许重试」，不花额度）。`[禁止]` 改图、换裁法去绕审核：被拒的用原画做轻微动作（`make_art.py` 的 `still`）。要了 1080p 实际还是 720×720，所以原画要先裁成奶蛙占满画面的方图再交。
- B 站：没有访客 cookie（buvid3/buvid4）的请求回 412。拿原画用 opus 接口（`x/polymer/web-dynamic/v1/opus/feed/space` 列动态、`opus/detail?id=` 拿全部图，原图 1536×2752 / 5504×3072）；旧的 `web-dynamic/v1/feed/space` 签了 WBI 也是 412。图片 URL 后面加 `@240w.jpg` 是缩略图，别用 `_1e_1c` 那种裁剪参数。
- 抠图用 rembg `isnet-general-use`（`birefnet` 效果差不多但慢 7 倍），不要按颜色抠：奶白肚皮在轮廓边上，会被一起吃掉。rembg 会把反光的肚皮当成半透明（深色桌面上发灰），也会留下栏杆、阴影的零碎小块：`make_art.py` 里补实身体、去掉不连着的小块；身边本来就有分开的东西（封闭奶蛙那圈小鱼）的片段要设 `islands`。rembg 逐帧不稳：晾衣奶蛙蓝天前面的白肚皮隔几十帧就漏一段，3 帧平均补不回来；背景是纯色的片段设 `key` 按背景色补。新片段处理完要逐帧看（或者算每帧透明面积的波动），别只看一帧。
- 带透明通道的 HEVC 按预乘 alpha 解释，PNG 是非预乘的：编码前必须预乘（`make_art.py` 在预乘空间里处理、直接把预乘值交给编码器），否则边缘发白。
- 显示：`AVPlayerItemVideoOutput` 取 IOSurface 做底的 BGRA 帧，直接设成图层的 `contents`（`PetView.show`），并给 IOSurface 标上 sRGB。原来复制成 CGImage 再贴，空闲循环多占 6–8% CPU。命中测试直接读这一帧的像素缓冲。不要用 `AVPlayerLayer`：画面由系统单独合成，没法验证。
- 看不到屏幕时（沙箱、锁屏）验证画面：截窗口（`CGWindowListCreateImage`）在锁屏或没有录屏权限时全是透明的；`layer.render(in:)` 不画 IOSurface 内容。用 `CARenderer(mtlTexture:)` 把一个以当前 IOSurface 为内容的图层离屏合成到 Metal 纹理再读回（先 `CATransaction.flush()`；读回来是上下颠倒的，放个标记块判断方向）。
- 在 Naiwa.app 里拿自己的 bundle id 当 `UserDefaults(suiteName:)` 会返回 nil。
- CFMessagePort 回调给的 CFData 只在回调期间有效：必须当场复制再丢到主线程，直接桥接成 `Data` 会读到垃圾。
- 「等你」只看 `Notification` 的 `notification_type`（`permission_prompt` 等），不要按提示语猜：`idle_prompt` 和别的提醒文案不止一种，按文字过滤漏过一次，奶蛙在没人要权限时显示了「等你确认」。
- 状态之间硬切：两个透明画面叠化会出重影。干活 / 等你是同一只（沉溺奶蛙），用同一个裁剪框，切过去不跳。
- 做完原来是捧腹大笑，用户嫌丑，换成了惊鸿一瞥（沉溺奶蛙，镜头推近、斜着瞥一眼）。推得太近（头占满画面）以后 rembg 认不出主体、只抠出碎块，所以只用到第 99 帧、停在瞥过来那一刻（`trim` + `hold_end`）。主体伸出原片画面的地方，`make_art.py` 在四边做了渐隐。
- bash 里变量后面直接跟中文标点要写成 `${VAR}`，否则会被当成变量名的一部分。

## 分支与提交

- `main` 只通过 PR 合入，squash 合并。PR 标题和正文、commit 信息用英文；文档和 issue 用中文。
