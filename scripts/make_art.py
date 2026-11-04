"""Seedance 出的原片 → assets/ 下每段带透明通道的 HEVC + assets.json（不带声音）。

  python3 scripts/make_art.py <原片目录> [片段名 ...]

原片：拿防御老猫的原画（裁成以奶蛙为中心的方图）当第一帧，用豆包 Seedance 2.5 图生视频出的 5 秒 1:1 1080p 片子，
放在原片目录里叫 <src>.mp4；每段用哪张画、提示词是什么见 art/pets.json。处理：

  1. 逐帧抠图：rembg isnet-general-use，结果缓存在 build/cut/<src>/；背景是一整片纯色的片段（"key": true）再按背景色补一刀
  2. 清理透明度：去掉和主体不连着的零碎小块（没抠干净的栏杆、阴影；"islands": true 的片段不去，比如身边一圈小鱼）；
     身体里面补成不透明（rembg 会把反光的肚皮当成半透明，深色桌面上发灰）；
     个别片段按 pets.json 手工擦掉一块（erase）、底部渐隐（fade_bottom）；
     再在时间上做 3 帧平均：抠图边缘逐帧会抖，平均一下就稳了（奶蛙动作慢，不会拖影）
  3. loop 的片段首尾叠化：最后 0.5 秒在预乘空间里叠化进开头，片长少 0.5 秒，播完从头接上看不出来
  4. 裁剪：同一个 group 的片段（干活 / 等你 / 做完都是沉溺奶蛙）用同一个框，切换时奶蛙不跳；
     框是所有帧里奶蛙出现过的范围的并集，放进方形画布，底边对齐、水平居中
  5. 预乘透明度后编成 HEVC（VideoToolbox，hvc1）。HEVC 透明视频按预乘解释，不预乘边缘会发白

豆包内容审核不让生成的画（安睡、听歌、封闭、孤独），pets.json 里写 "still"：原片目录里放裁好的原画 <src>.png，
用 animate() 在原画上做呼吸、漂浮、小鱼来回转这类轻微的动作。

没出原片的片段跳过；assets.json 只写有素材的片段，idle 时段里一个片段都没有的时段也跳过（App 会顺延用前一个时段的）。
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


def keyed(rgb: np.ndarray, alpha: np.ndarray) -> np.ndarray:
    """背景是一整片纯色的（晾衣奶蛙的蓝天）：离背景色远的像素也算前景，只在身体附近 80 像素内生效（漏掉的肚皮有六七十像素高）。
    rembg 会隔几十帧把蓝天前面的白肚皮当成背景漏掉，按颜色补回来"""
    edge = np.concatenate([rgb[0], rgb[-1], rgb[:, 0], rgb[:, -1]])
    dist = np.linalg.norm(rgb - np.median(edge, axis=0), axis=-1)
    key = np.clip((dist - 0.25) / 0.2, 0, 1)
    near = ndimage.binary_dilation(alpha > 0.5, iterations=80)
    return np.maximum(alpha, key * near)


def cutout(src: Path, fps: int, key: bool = False) -> list[np.ndarray]:
    """原片逐帧抠图，返回非预乘的 RGBA（float 0–1）"""
    cache = ROOT / "build" / "cut" / (src.stem + ("_key" if key else ""))
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
                a = keyed(rgb, np.asarray(out, dtype=np.float32)[..., 3] / 255)
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
    """按 pets.json 里的手工参数修透明度（比例坐标，原点在左上）：
    erase        [[x0, y0, x1, y1], …] 这些框里清零（云幻右边的电线杆）
    fade_bottom  从这个高度往下渐隐到 0（云幻的云和下面的云连在一起，硬切是一条平边，渐隐像云散开）"""
    h, w = alpha.shape
    alpha = alpha.copy()
    ys, xs = np.mgrid[0:h, 0:w]
    for x0, y0, x1, y1 in c.get("erase", []):
        # 框边上 3% 画面宽度内渐变，不留直边
        f = 0.03 * w
        d = np.minimum.reduce([xs - x0 * w, x1 * w - xs, ys - y0 * h, y1 * h - ys])
        alpha *= 1 - np.clip(d / f, 0, 1)
    if "fade_bottom" in c:
        top = int(c["fade_bottom"] * h)
        alpha[top:] *= np.linspace(1, 0, h - top, dtype=np.float32)[:, None]
    return alpha


def steady(fs: list[np.ndarray], c: dict) -> list[np.ndarray]:
    """清理每帧的透明度，再在时间上做 3 帧平均（首尾帧只和一边平均），颜色不动"""
    a = np.stack([shaped(solid(f[..., 3], c.get("islands", False)), c) for f in fs])
    sm = a.copy()
    sm[1:-1] = (a[:-2] + a[1:-1] + a[2:]) / 3
    out = []
    for f, al in zip(fs, sm):
        g = f.copy()
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


def still_cutout(src: Path, c: dict) -> np.ndarray:
    """静态原画抠图（长边缩到 1024），结果缓存在 build/cut/<src>.png"""
    cache = ROOT / "build" / "cut" / f"{src.stem}.png"
    if not cache.exists():
        from rembg import new_session, remove

        im = Image.open(src).convert("RGB")
        im.thumbnail((1024, 1024), Image.LANCZOS)
        cache.parent.mkdir(parents=True, exist_ok=True)
        remove(im, session=new_session("isnet-general-use", providers=["CPUExecutionProvider"])).save(cache)
    f = np.asarray(Image.open(cache).convert("RGBA"), dtype=np.float32) / 255
    f = f.copy()
    f[..., 3] = shaped(solid(f[..., 3], c.get("islands", False)), c)
    return f


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


def encode(fs, box, size, fps, dst: Path):
    x0, y0, x1, y1 = box
    with tempfile.TemporaryDirectory() as tmp:
        for i, f in enumerate(fs):
            px = (np.clip(f, 0, 1) * 255 + 0.5).astype(np.uint8)
            # 裁剪框可能伸出画面：先贴到足够大的透明画布上再截
            im = Image.frombytes("RGBa", (px.shape[1], px.shape[0]), px.tobytes())
            canvas = Image.new("RGBa", (x1 - x0, y1 - y0))
            canvas.paste(im, (-x0, -y0))
            canvas = canvas.resize((size, size), Image.LANCZOS)
            # 已经是预乘的：把预乘值原样写进 PNG 交给编码器
            Image.frombytes("RGBA", canvas.size, canvas.tobytes()).save(Path(tmp) / f"{i:04d}.png")
        ffmpeg("-framerate", fps, "-i", Path(tmp) / "%04d.png",
               "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-q:v", "75", "-tag:v", "hvc1", "-pix_fmt", "bgra", dst)


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
        return raw / (f"{c['src']}.png" if "still" in c else f"{c['src']}.mp4")

    clips = {name: c for name, c in spec["clips"].items() if source(c).exists() and (not only or name in only)}
    frames = {name: animate(still_cutout(source(c), c), c["still"], fps) if "still" in c else steady(cutout(source(c), fps, c.get("key", False)), c)
              for name, c in clips.items()}
    groups: dict[str, list[str]] = {}
    for name, c in clips.items():
        groups.setdefault(c.get("group", name), []).append(name)
    for members in groups.values():
        box = box_of([frames[m] for m in members])
        for m in members:
            fs = premultiply(frames[m])
            if clips[m].get("loop") and "still" not in clips[m]:  # 静图做的动作本来就是整圈，不用叠化
                fs = crossfade_loop(fs)
            dst = assets / f"{m}.mov"
            encode(fs, box, size, fps, dst)
            have[m] = {"video": dst.name, "frames": len(fs), "loop": bool(clips[m].get("loop")),
                       "title": clips[m]["title"], "desc": clips[m].get("desc", "")}
            print(f"{m}: {len(fs)} 帧 {len(fs) / fps:.2f} 秒，{dst.stat().st_size // 1024}KB，框 {box}")

    for m, c in spec["clips"].items():  # 只重做了几段时，别的片段的名字和介绍也跟着 pets.json 走
        if m in have:
            have[m].update(title=c["title"], desc=c.get("desc", ""))
    idle = [{**s, "pets": [c for c in s["pets"] if c in have]} for s in spec["idle"]]
    meta = {"fps": fps, "credit": spec["credit"],
            "pets": [m for m in spec["clips"] if m in have],  # 菜单和 naiwa pets 里的顺序
            "clips": have,
            "idle": [s for s in idle if s["pets"]],
            **{k: spec[k] for k in ("work", "look", "laugh")}}
    (assets / "assets.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n")


if __name__ == "__main__":
    main()
