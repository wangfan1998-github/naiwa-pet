# AGENTS.md

naiwa-pet：macOS 桌面上的奶蛙，摸它或者 Claude Code 任务做完它就捧腹大笑。用法和素材流程见 [README.md](README.md)。

## 约定

- `[必须]` 保持小：不引入第三方依赖，只用系统框架（AppKit、AVFoundation）。站着不动时不能有定时器在跑；笑的时候才开一个取帧的定时器，笑完就停。
- `[必须]` 透明的地方让鼠标穿过去，点奶蛙不抢焦点（`nonactivatingPanel` + 按当前帧的像素切换 `ignoresMouseEvents`）。改窗口或鼠标逻辑后，要在真机上确认点它背后的窗口还能点到。
- `[必须]` `naiwa hooks install` 只做文本插入，写之前确认新旧 settings.json 除了这一条以外完全一致。理由：这是别人的全局配置，不能重排、不能丢字段。
- `[禁止]` 仓库里出现内网地址、主机名、个人路径和 key。
- `[必须]` 奶蛙的样子和笑法以原梗为准：素材直接取原版视频（`scripts/fetch_source.sh` + `scripts/make_assets.py`）。`[禁止]` 用《蛙笑江湖》之类自建的 3D 模型或手写动作代替，笑起来不像。
- 画面和笑声不是原创也不是 CC0，见 README「素材怎么做的」，不要商用。

## 踩过的坑

- 视频模型（Seedance）会因为奶蛙造型被内容审核拦掉，换图、换提示词都没用。
- B 站网页和接口对没有访客 cookie 的请求回 412；部分 CDN 节点回 567，要换 backupUrl。不登录最高 480P。
- 抠白底别用颜色泛洪：侧身时奶白肚皮在轮廓边上，会被一起吃掉。用 rembg `isnet-general-use`（`birefnet` 效果差不多但慢 7 倍）。
- 带透明通道的 HEVC 按预乘 alpha 解释，PNG 是非预乘的：编码前必须预乘（`make_assets.py` 在预乘空间里处理、直接把预乘值交给编码器），否则边缘发白。
- 不要用 `AVPlayerLayer` 直接显示：它的画面由系统单独合成，截窗口抓不到，没法验证。现在用 `AVPlayerItemVideoOutput` 取帧贴到普通图层上。
- 看不到屏幕时（沙箱、锁屏）验证画面：把 `view.layer` 用 `render(in:)` 画进离屏位图再存 PNG；截窗口在锁屏时是全透明的。
- 在 Naiwa.app 里拿自己的 bundle id 当 `UserDefaults(suiteName:)` 会返回 nil。
- bash 里变量后面直接跟中文标点要写成 `${VAR}`，否则会被当成变量名的一部分。

## 分支与提交

- `main` 只通过 PR 合入，squash 合并。PR 标题和正文、commit 信息用英文；文档和 issue 用中文。
