"""Seedance 出的原片 → assets/ 下每段带透明通道的 HEVC + assets.json（不带声音）。

  python3 scripts/make_art.py <原片目录> [片段名 ...]

原片：拿原画（裁成以奶蛙为中心的方图）当第一帧，用豆包 Seedance 2.5 图生视频出的 5 秒 1:1 1080p 片子，
放在原片目录里叫 <src>.mp4；每段用哪张画、提示词是什么见 art/pets.json。处理：

  1. 逐帧抠图：rembg isnet-general-use，结果缓存在 build/cut/<src>/；背景是一整片纯色的片段（"key": true）再按背景色补一刀
  2. 清理透明度：去掉和主体不连着的零碎小块（没抠干净的栏杆、阴影；"islands": true 的片段不去，比如身边一圈小鱼）；
     身体里面补成不透明（rembg 会把反光的肚皮当成半透明，深色桌面上发灰）；
     个别片段按 pets.json 手工擦掉一块（erase）、底部渐隐（fade_bottom）；身体基本不动、泡在水里的片段（"matte": "first"）整段用开头几帧的轮廓；
     再在时间上做 3 帧平均：抠图边缘逐帧会抖，平均一下就稳了（奶蛙动作慢，不会拖影）
  3. loop 的片段首尾叠化：最后 0.5 秒在预乘空间里叠化进开头，片长少 0.5 秒，播完从头接上看不出来
  4. 裁剪：同一个 group 的片段（同一只的空闲、看着你、做完）用同一个框，切换时奶蛙不跳；
     框是所有帧里奶蛙出现过的范围的并集，放进方形画布，底边对齐、水平居中。
     组里既有静图做的空闲、又有 Seedance 出的片子时，先把静图那段按第一帧主体的高度和脚底中点挪进片子的坐标。
     只点名重做某一段时，同组的别的片段也一起重做
  5. 预乘透明度后编成 HEVC（VideoToolbox，hvc1）。HEVC 透明视频按预乘解释，不预乘边缘会发白

豆包内容审核不让生成的画（安睡、听歌、封闭、孤独），pets.json 里写 "still"：原片目录里放裁好的原画 <src>.png，
用 animate() 在原画上做呼吸、漂浮、小鱼来回转这类轻微的动作。

每段顺手更新 docs/pets/<片段>.webp（README 里的透明动图）。没出原片的片段跳过；assets.json 只写有素材的片段，idle 时段里一个片段都没有的时段也跳过（App 会顺延用前一个时段的）。
需要：ffmpeg、rembg（pip install "rembg[cpu]"，会带上 numpy、scipy、Pillow）。
"""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parent.parent
XFADE = 12  # 帧


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *map(str, args)], check=True)


def keyed(rgb: np.ndarray, alpha: np.ndarray, rows: bool = False) -> np.ndarray:
    """背景是一整片纯色的（晾衣奶蛙的蓝天）：离背景色远的像素也算前景，只在身体附近 80 像素内生效（漏掉的肚皮有六七十像素高）。
    rembg 会隔几十帧把蓝天前面的白肚皮当成背景漏掉，按颜色补回来。
    rows=True（"key": "rows"）：背景是上下渐变的干净天空（安睡奶蛙），每一行拿这一行左右两边的颜色当背景，整幅画面都补——
    rembg 会把蓝天前的白云当成背景抠掉，云又伸得比 80 像素远"""
    if rows:
        bg = np.median(np.concatenate([rgb[:, :6], rgb[:, -6:]], axis=1), axis=1)[:, None, :]
        return np.maximum(alpha, np.clip((np.linalg.norm(rgb - bg, axis=-1) - 0.12) / 0.15, 0, 1))
    edge = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    dist = np.linalg.norm(rgb - np.median(edge, axis=0), axis=-1)
    key = np.clip((dist - 0.25) / 0.2, 0, 1)
    near = ndimage.binary_dilation(alpha > 0.5, iterations=80)
    return np.maximum(alpha, key * near)


def cutout(src: Path, fps: int, key: bool | str = False) -> list[np.ndarray]:
    """原片逐帧抠图，返回非预乘的 RGBA（float 0–1）"""
    cache = ROOT / "build" / "cut" / (src.stem + ("_key" if key is True else f"_key{key}" if key else ""))
    if not cache.exists() or not any(cache.glob("*.png")):
        from rembg import new_session, remove

        raw = cache.with_name(cache.name + "_raw")
        shutil.rmtree(raw, ignore_errors=True)
        raw.mkdir(parents=True)
        ffmpeg("-i", src, "-vf", f"fps={fps}", raw / "%04d.png")
        cache.mkdir(parents=True, exist_ok=True)
        session = new_session("isnet-general-use", providers=["CPUExecutionProvider"])
        for p in sorted(raw.glob("*.png")):
            im = Image.open(p).convert("RGB")
            out = remove(im, session=session)
            if key:
                rgb = np.asarray(im, dtype=np.float32) / 255
                a = keyed(rgb, np.asarray(out, dtype=np.float32)[..., 3] / 255, rows=key == "rows")
                out = Image.fromarray((np.dstack([rgb, a]) * 255 + 0.5).astype(np.uint8), "RGBA")
            out.save(cache / p.name)
        shutil.rmtree(raw)
    return [np.asarray(Image.open(p).convert("RGBA"), dtype=np.float32) / 255 for p in sorted(cache.glob("*.png"))]


def solid(alpha: np.ndarray, islands: bool) -> np.ndarray:
    """清理一帧的透明度：
    - 和主体不连着的零碎小块（没抠干净的栏杆、阴影）去掉：只留面积不小于最大一块 3% 的块，外面 6 像素以外清零。
      islands=True 时不清（封闭奶蛙身边那圈小鱼本来就是一个个分开的）
    - 身体里面补成不透明：原画是反光的软胶，rembg 会把亮面（尤其肚皮）当成半透明，放在深色桌面上发灰。
      轮廓里面往里缩 3 像素、原本半透明的地方补满，边缘还是 rembg 给的柔边"""
    body = alpha > 0.5
    lab, n = ndimage.label(body)
    if n == 0:
        return alpha
    if not islands:
        sizes = ndimage.sum(body, lab, range(1, n + 1))
        body = np.isin(lab, 1 + np.nonzero(sizes >= sizes.max() * 0.03)[0])
        alpha = np.where(ndimage.binary_dilation(body, iterations=6), alpha, 0)
    # 只补原本半透明的地方；完全透明的洞是真洞（缠线奶蛙身上绕的线圈里是背景），补了会冒出黑块
    inner = ndimage.binary_erosion(ndimage.binary_fill_holes(body), iterations=3) & (alpha > 0.05)
    return np.maximum(alpha, inner.astype(np.float32))


def shaped(alpha: np.ndarray, c: dict) -> np.ndarray:
    """画面四边渐隐，再按 pets.json 里的手工参数修透明度（比例坐标，原点在左上）：
    erase        [[x0, y0, x1, y1], …] 这些框里清零（云幻右边的电线杆）
    fade_bottom  从这个高度往下渐隐到 0（云幻的云和下面的云连在一起，硬切是一条平边，渐隐像云散开）"""
    h, w = alpha.shape
    alpha = alpha.copy()
    ys, xs = np.mgrid[0:h, 0:w]
    # 原片四边 3% 内渐隐：主体伸出画面的地方（推近后的身体、晾衣绳两头）不留直边
    edge = 0.03 * min(h, w)
    alpha *= np.clip(np.minimum.reduce([xs, w - 1 - xs, ys, h - 1 - ys]) / edge, 0, 1)
    for x0, y0, x1, y1 in c.get("erase", []):
        # 框边上 3% 画面宽度内渐变，不留直边
        f = 0.03 * w
        d = np.minimum.reduce([xs - x0 * w, x1 * w - xs, ys - y0 * h, y1 * h - ys])
        alpha *= 1 - np.clip(d / f, 0, 1)
    if "fade_bottom" in c:
        top = int(c["fade_bottom"] * h)
        alpha[top:] *= np.linspace(1, 0, h - top, dtype=np.float32)[:, None]
    return alpha


def despill(f: np.ndarray) -> np.ndarray:
    """背景是一整片纯色的片段（"key": true）：半透明的边缘和动作拖影里混着背景色（晾衣奶蛙荡起来时腿上一圈蓝），
    按 颜色 = 透明度 × 前景 + (1 − 透明度) × 背景 反算出前景色。背景色取这一帧完全透明处的中位数"""
    a = f[..., 3]
    bg = a < 0.02
    if bg.sum() < 1000:
        return f[..., :3]
    b = np.median(f[..., :3][bg], axis=0)
    aa = np.clip(a, 0.08, 1)[..., None]
    fg = np.clip((f[..., :3] - (1 - aa) * b) / aa, 0, 1)
    edge = ((a > 0.02) & (a < 0.98))[..., None]
    return np.where(edge, fg, f[..., :3])


def original_rgb(src: Path, fps: int) -> list[np.ndarray]:
    """原片逐帧的原色（0–1）。抠图工具在它认为是背景的地方把颜色也清成了黑色，套固定轮廓时要用原色"""
    with tempfile.TemporaryDirectory() as t:
        ffmpeg("-i", src, "-vf", f"fps={fps}", Path(t) / "%04d.png")
        return [np.asarray(Image.open(q).convert("RGB"), dtype=np.float32) / 255 for q in sorted(Path(t).glob("*.png"))]


def steady(fs: list[np.ndarray], c: dict, src: Path | None = None, fps: int = 24) -> list[np.ndarray]:
    """清理每帧的透明度，再在时间上做 3 帧平均（首尾帧只和一边平均）；纯色背景的片段再去掉边缘混进来的背景色"""
    a = np.stack([shaped(solid(f[..., 3], c.get("islands", False)), c) for f in fs])
    if c.get("matte") == "first":
        # 身体基本不动的片段（泡在水里的侧眼、花瓣落在肚子上）：逐帧抠图会把水下的身体当成水抠掉，
        # 拿开头 6 帧（和空闲第一帧一样、抠得准）的中位数当轮廓，套到每一帧上
        a = np.repeat(np.median(a[:6], axis=0)[None], len(a), axis=0)
        rgb = original_rgb(src, fps) if src else None
        if rgb and len(rgb) >= len(fs):
            fs = [np.dstack([rgb[i], f[..., 3]]) for i, f in enumerate(fs)]
    sm = a.copy()
    sm[1:-1] = (a[:-2] + a[1:-1] + a[2:]) / 3
    out = []
    for f, al in zip(fs, sm):
        g = f.copy()
        if c.get("key") is True:  # 只对纯色背景反算；渐变天空前的白云反算出来是橙的
            g[..., :3] = despill(f)
        g[..., 3] = al
        out.append(g)
    return out


def animate(still: np.ndarray, m: dict, fps: int) -> list[np.ndarray]:
    """豆包审核不让生成的画，用原画本身做轻微的动作（Wallpaper Engine 上那些动态壁纸也是这么动的），周期正好一圈，首尾自然接上：
    breathe   呼吸：以脚底为基准纵向伸缩这么多（比例），横向跟着收一点
    float     漂浮：上下浮动的幅度（画面高度的比例），比呼吸慢半拍
    sway      身边分开的小块（封闭奶蛙那圈小鱼）绕身体中心来回转的角度（度）
    period    一圈几秒"""
    n = round(m.get("period", 4.5) * fps)
    h, w = still.shape[:2]
    pm = still.copy()
    pm[..., :3] *= pm[..., 3:]
    body = pm[..., 3] > 0.5
    lab, k = ndimage.label(body)
    sizes = ndimage.sum(body, lab, range(1, k + 1))
    main = lab == 1 + int(np.argmax(sizes))
    ys, xs = np.nonzero(main)
    base, cx, cy = ys.max(), xs.mean(), ys.mean()
    # 小块单独一层：离主体超过 4 像素的部分
    sat = ~ndimage.binary_dilation(main, iterations=4) & (pm[..., 3] > 0.02) if m.get("sway") else np.zeros_like(main)
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    out = []
    for i in range(n):
        ph = 2 * np.pi * i / n
        b = m.get("breathe", 0) * np.sin(ph)
        dy = m.get("float", 0) * h * np.sin(ph - np.pi / 2)
        # 输出像素 (x, y) 从原图哪里取：先去掉漂浮，再按呼吸反着缩回去
        sy = base - (base - (yy - dy)) / (1 + b)
        sx = cx + (xx - cx) / (1 - 0.35 * b)
        frame = np.stack([ndimage.map_coordinates(pm[..., c] * ~sat, [sy, sx], order=1, mode="constant") for c in range(4)], -1)
        if sat.any():
            a = np.deg2rad(m["sway"] * np.sin(ph))
            rx = cx + (xx - cx) * np.cos(a) + (yy - dy - cy) * np.sin(a)
            ry = cy - (xx - cx) * np.sin(a) + (yy - dy - cy) * np.cos(a)
            layer = np.stack([ndimage.map_coordinates(pm[..., c] * sat, [ry, rx], order=1, mode="constant") for c in range(4)], -1)
            frame = layer + frame * (1 - layer[..., 3:])
        rgb = np.where(frame[..., 3:] > 1e-4, frame[..., :3] / np.maximum(frame[..., 3:], 1e-4), 0)
        out.append(np.concatenate([np.clip(rgb, 0, 1), frame[..., 3:]], -1).astype(np.float32))
    return out


def gesture(still: np.ndarray, g: dict, fps: int) -> list[np.ndarray]:
    """豆包怎么都不肯出片的画（孤独奶蛙：背对着站的身影一律被拦），在原画上做程序动作，脸和身体完全是原画：
    lean  往一边歪过去（angle 度，正数往右）停住，in 秒歪到位，再停 hold 秒（等你：侧身在听）
    rock  左右晃 swings 下、幅度 angle 度、越晃越小，period 秒后回到原位（做完）
    都以脚底中点为轴；整块一起转（扶着的椅子跟着歪，像靠在椅子上）"""
    pm = still.copy()
    pm[..., :3] *= pm[..., 3:]
    h, w = pm.shape[:2]
    t, b, l, r = body_box(pm[..., 3])
    py, px = b, (l + r) / 2
    if g["kind"] == "lean":
        n = round((g.get("in", 0.6) + g.get("hold", 2.4)) * fps)
        k_in = max(1, round(g.get("in", 0.6) * fps))
        angles = [g["angle"] * (1 - (1 - min(i / k_in, 1)) ** 3) for i in range(n)]
    else:  # rock
        n = round(g.get("period", 2.5) * fps)
        angles = [g["angle"] * np.sin(2 * np.pi * g.get("swings", 2) * i / n) * (1 - i / n) for i in range(n)]
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    out = []
    for a in angles:
        th = np.deg2rad(a)
        # 输出 (x, y) 取原图里绕脚底转回去的位置
        sx = px + (xx - px) * np.cos(th) + (yy - py) * np.sin(th)
        sy = py - (xx - px) * np.sin(th) + (yy - py) * np.cos(th)
        f = np.stack([ndimage.map_coordinates(pm[..., c], [sy, sx], order=1, mode="constant") for c in range(4)], -1)
        rgb = np.where(f[..., 3:] > 1e-4, f[..., :3] / np.maximum(f[..., 3:], 1e-4), 0)
        out.append(np.concatenate([np.clip(rgb, 0, 1), np.clip(f[..., 3:], 0, 1)], -1).astype(np.float32))
    return out


def jolt(fs: list[np.ndarray], g: dict, fps: int) -> list[np.ndarray]:
    """在片子每一帧上叠「被电一下」：at 里每个时刻（秒）整个画面以中心猛地放大 amp 再弹回，持续 dur 秒。
    缠线奶蛙是俯拍仰躺着的，放大读起来就是一下弹起来；片子本身的变化（屏幕闪、光线变）照旧"""
    h, w = fs[0].shape[:2]
    cy, cx = h / 2, w / 2
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    out = []
    for i, f in enumerate(fs):
        t = i / fps
        k = sum(np.sin(np.pi * (t - t0) / g.get("dur", 0.22)) for t0 in g["at"] if 0 <= t - t0 <= g.get("dur", 0.22))
        s = 1 + g.get("amp", 0.06) * k
        if s == 1:
            out.append(f)
            continue
        pm = f.copy()
        pm[..., :3] *= pm[..., 3:]
        sy, sx = cy + (yy - cy) / s, cx + (xx - cx) / s
        g2 = np.stack([ndimage.map_coordinates(pm[..., c], [sy, sx], order=1, mode="constant") for c in range(4)], -1)
        rgb = np.where(g2[..., 3:] > 1e-4, g2[..., :3] / np.maximum(g2[..., 3:], 1e-4), 0)
        out.append(np.concatenate([np.clip(rgb, 0, 1), np.clip(g2[..., 3:], 0, 1)], -1).astype(np.float32))
    return out


def still_cutout(src: Path, c: dict) -> np.ndarray:
    """静态原画抠图（长边缩到 1024），结果缓存在 build/cut/<src>.png；"key" 同 cutout（安睡奶蛙的白云要按天空补）"""
    key = c.get("key", False)
    cache = ROOT / "build" / "cut" / (src.stem + ("_key" if key is True else f"_key{key}" if key else "") + ".png")
    if not cache.exists():
        from rembg import new_session, remove

        im = Image.open(src).convert("RGB")
        im.thumbnail((1024, 1024), Image.LANCZOS)
        cache.parent.mkdir(parents=True, exist_ok=True)
        out = remove(im, session=new_session("isnet-general-use", providers=["CPUExecutionProvider"]))
        if key:
            rgb = np.asarray(im, dtype=np.float32) / 255
            a = keyed(rgb, np.asarray(out, dtype=np.float32)[..., 3] / 255, rows=key == "rows")
            out = Image.fromarray((np.dstack([rgb, a]) * 255 + 0.5).astype(np.uint8), "RGBA")
        out.save(cache)
    f = np.asarray(Image.open(cache).convert("RGBA"), dtype=np.float32) / 255
    f = f.copy()
    f[..., 3] = shaped(solid(f[..., 3], c.get("islands", False)), c)
    return f


def settled(fs: list[np.ndarray], tail: int = 8) -> int:
    """看着你：头转过来停住以后，画面基本不动（App 播完会停在最后一帧一直看着你），后面那几秒截掉省体积。
    按相邻帧的差（预乘后）找最后一段明显在动的地方，再多留 tail 帧；至少留三分之一"""
    pm = [f[..., :3] * f[..., 3:] for f in fs]
    d = np.array([np.abs(pm[i + 1] - pm[i]).mean() for i in range(len(pm) - 1)])
    sm = np.convolve(d, np.ones(5) / 5, mode="same")
    moving = np.nonzero(sm > sm.max() * 0.25)[0]
    end = moving[-1] + 1 + tail if len(moving) else len(fs)
    return int(min(len(fs), max(end, len(fs) // 3)))


def premultiply(fs):
    out = []
    for f in fs:
        g = f.copy()
        g[..., :3] *= g[..., 3:]
        out.append(g)
    return out


def crossfade_loop(fs, k=XFADE):
    """尾巴 [n-k, n) 叠化进开头 [0, k)，后面接 [k, n-k)：一共 n-k 帧，最后一帧之后正好接回第一帧（预乘空间）"""
    n = len(fs)
    head = [fs[n - k + i] * (1 - i / k) + fs[i] * (i / k) for i in range(k)]
    return head + fs[k:n - k]


def body_box(alpha: np.ndarray):
    """一帧里主体（最大的一块）的范围：上、下、左、右"""
    body = alpha > 0.5
    lab, n = ndimage.label(body)
    sizes = ndimage.sum(body, lab, range(1, n + 1))
    ys, xs = np.nonzero(lab == 1 + int(np.argmax(sizes)))
    return ys.min(), ys.max() + 1, xs.min(), xs.max() + 1


def align(fs: list[np.ndarray], ref: np.ndarray) -> list[np.ndarray]:
    """把一段挪进参考片段的画面坐标：按第一帧主体的高度缩放、脚底中点对齐，画布和参考一样大。
    静图做的空闲（原画抠图，长边 1024）和 Seedance 出的等你 / 做完（720）分辨率、裁法都不一样，同一组要先对齐才能共用一个框"""
    a, b = body_box(fs[0][..., 3]), body_box(ref[..., 3])
    s = (b[1] - b[0]) / (a[1] - a[0])
    dy, dx = b[1] - s * a[1], (b[2] + b[3]) / 2 - s * (a[2] + a[3]) / 2
    shape = ref.shape[:2]
    out = []
    for f in fs:
        pm = f.copy()
        pm[..., :3] *= pm[..., 3:]
        # 输出 (y, x) 取原图 ((y - dy) / s, (x - dx) / s)，在预乘空间里插值，边缘不发白
        g = np.stack([ndimage.affine_transform(pm[..., c], [1 / s, 1 / s], offset=[-dy / s, -dx / s],
                                               output_shape=shape, order=1, mode="constant") for c in range(4)], -1)
        rgb = np.where(g[..., 3:] > 1e-4, g[..., :3] / np.maximum(g[..., 3:], 1e-4), 0)
        out.append(np.concatenate([np.clip(rgb, 0, 1), np.clip(g[..., 3:], 0, 1)], -1).astype(np.float32))
    return out


def matched_box(first: np.ndarray, preview: Path, size: int):
    """组里的空闲片段这次不重做（静图做的、原画不在手边）：照它的预览动图（docs/pets/<名字>.webp）第一帧里主体的位置和大小，
    反推这一段的裁剪框，切过去时奶蛙落在同一个地方、一样大"""
    ref = np.asarray(Image.open(preview).convert("RGBA"), dtype=np.float32) / 255
    k = size / ref.shape[0]
    t, b, l, r = (v * k for v in body_box(ref[..., 3]))  # 换算到成片的 size
    T, B, L, R = body_box(first[..., 3])
    side = int(round((B - T) * size / (b - t)))
    s = side / size
    x0, y0 = int(round((L + R) / 2 - (l + r) / 2 * s)), int(round(B - b * s))
    return x0, y0, x0 + side, y0 + side


def box_of(groups: list[list[np.ndarray]]):
    union = None
    for fs in groups:
        for f in fs:
            m = f[..., 3] > 0.3
            union = m if union is None else union | m
    ys, xs = np.nonzero(union)
    top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    side = int(max(bottom - top, right - left) * 1.04) + 8
    cx = (left + right) // 2
    return int(cx - side // 2), int(bottom + 4 - side), int(cx - side // 2 + side), int(bottom + 4)


def encode(fs, box, size, fps, dst: Path, preview: Path | None = None):
    """编码成 assets 里的 HEVC；preview 给了就顺手存一张 README 用的动态 WebP（240px，带透明通道）"""
    x0, y0, x1, y1 = box
    thumbs = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, f in enumerate(fs):
            px = (np.clip(f, 0, 1) * 255 + 0.5).astype(np.uint8)
            # 裁剪框可能伸出画面：先贴到足够大的透明画布上再截
            im = Image.frombytes("RGBa", (px.shape[1], px.shape[0]), px.tobytes())
            canvas = Image.new("RGBa", (x1 - x0, y1 - y0))
            canvas.paste(im, (-x0, -y0))
            canvas = canvas.resize((size, size), Image.LANCZOS)
            if preview:
                thumbs.append(canvas.resize((240, 240), Image.LANCZOS).convert("RGBA"))
            # 已经是预乘的：把预乘值原样写进 PNG 交给编码器
            Image.frombytes("RGBA", canvas.size, canvas.tobytes()).save(Path(tmp) / f"{i:04d}.png")
        ffmpeg("-framerate", fps, "-i", Path(tmp) / "%04d.png",
               "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-q:v", "75", "-tag:v", "hvc1", "-pix_fmt", "bgra", dst)
    if preview:
        preview.parent.mkdir(parents=True, exist_ok=True)
        # 隔一帧取一帧（12 fps），和别的预览一样大小（几百 KB），README 一页要加载十几张
        thumbs = thumbs[::2]
        thumbs[0].save(preview, save_all=True, append_images=thumbs[1:], duration=round(2000 / fps), loop=0,
                       quality=80, method=6)


def main():
    raw = Path(sys.argv[1])
    only = set(sys.argv[2:])
    spec = json.loads((ROOT / "art" / "pets.json").read_text())
    fps, size = spec["fps"], spec["size"]
    assets = ROOT / "assets"
    assets.mkdir(exist_ok=True)
    old = json.loads((assets / "assets.json").read_text()) if (assets / "assets.json").exists() else {}
    have = {k: v for k, v in (old.get("clips") or {}).items() if (assets / v["video"]).exists()}

    def source(c):
        on_still = "still" in c or ("gesture" in c and c["gesture"]["kind"] != "jolt")
        return raw / (f"{c['src']}.png" if on_still else f"{c['src']}.mp4")

    if only:  # 同一组（同一只的空闲、等你、做完）要一起做，不然框不一样，切过去会跳
        groups_wanted = {spec["clips"][n].get("group", n) for n in only if n in spec["clips"]}
        only |= {n for n, c in spec["clips"].items() if c.get("group", n) in groups_wanted}
    clips = {name: c for name, c in spec["clips"].items() if source(c).exists() and (not only or name in only)}
    def make(c):
        if "gesture" in c and c["gesture"]["kind"] == "jolt":  # 片子上叠弹动
            return jolt(steady(cutout(source(c), fps, c.get("key", False)), c, source(c), fps), c["gesture"], fps)
        if "gesture" in c:  # 原画上的程序动作（豆包不肯出片的画）
            return gesture(still_cutout(source(c), c), c["gesture"], fps)
        if "still" in c:
            return animate(still_cutout(source(c), c), c["still"], fps)
        return steady(cutout(source(c), fps, c.get("key", False)), c, source(c), fps)

    frames = {name: make(c) for name, c in clips.items()}
    groups: dict[str, list[str]] = {}
    for name, c in clips.items():
        groups.setdefault(c.get("group", name), []).append(name)
    for gname, members in groups.items():
        # 组里有静图做的、也有 Seedance 出的：静图那段挪进片子的坐标（片子动得多，不去缩它）
        ref = next((m for m in members if "still" not in clips[m] and clips[m].get("gesture", {}).get("kind", "jolt") == "jolt"), None)
        for m in members:
            if ref and ("still" in clips[m] or ("gesture" in clips[m] and clips[m]["gesture"]["kind"] != "jolt")):  # 原画做的（静图动作、程序动作）都挪进片子坐标
                frames[m] = align(frames[m], frames[ref][0])
            if clips[m].get("settle"):  # 看着你：转过来以后的静止部分截掉
                frames[m] = frames[m][:settled(frames[m])]
        keep = ROOT / "docs" / "pets" / f"{gname}.webp"
        if gname in spec["clips"] and gname not in clips and keep.exists():  # 空闲那只这次不重做：对齐到它现在的样子
            box = matched_box(frames[members[0]][0], keep, size)
        else:
            box = box_of([frames[m][slice(*clips[m].get("trim", [None, None]))] for m in members])
        for m in members:
            fs = premultiply(frames[m])
            if "trim" in clips[m]:  # 只用这一段帧 [起, 止)：惊鸿一瞥推得太近以后 rembg 认不出主体，停在瞥过来那一刻
                fs = fs[clips[m]["trim"][0]:clips[m]["trim"][1]]
            fs += [fs[-1]] * clips[m].get("hold_end", 0)  # 最后一帧多停几帧
            if clips[m].get("loop") and "still" not in clips[m]:  # 静图做的动作本来就是整圈，不用叠化（gesture 都不循环）
                fs = crossfade_loop(fs)
            dst = assets / f"{m}.mov"
            encode(fs, box, size, fps, dst, ROOT / "docs" / "pets" / f"{m}.webp")
            have[m] = {"video": dst.name, "frames": len(fs), "loop": bool(clips[m].get("loop")),
                       "title": clips[m]["title"], "desc": clips[m].get("desc", "")}
            print(f"{m}: {len(fs)} 帧 {len(fs) / fps:.2f} 秒，{dst.stat().st_size // 1024}KB，框 {box}")

    for m, c in spec["clips"].items():  # 只重做了几段时，别的片段的名字、介绍、等你 / 做完是哪段也跟着 pets.json 走
        if m in have:
            have[m].update(title=c["title"], desc=c.get("desc", ""))
            for k in ("look", "done"):  # 这只自己的等你 / 做完：那段有素材才写，没有的 App 会退回默认
                have[m].pop(k, None)
                if c.get(k) in have:
                    have[m][k] = c[k]
    idle = [{**s, "pets": [c for c in s["pets"] if c in have]} for s in spec["idle"]]
    meta = {"fps": fps,
            "pets": [m for m in spec["clips"] if m in have],  # 菜单和 naiwa pets 里的顺序
            "clips": have,
            "idle": [s for s in idle if s["pets"]],
            **{k: spec[k] for k in ("work", "done")}}
    (assets / "assets.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    main()
