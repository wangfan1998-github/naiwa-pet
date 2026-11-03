"""原版《奶蛙大笑》视频 → assets/ 下几段带透明通道的 HEVC（不带声音）。

  python scripts/make_assets.py <源视频.mp4> [--size 384]

片段全部取自同一个原片（scripts/fetch_source.sh 下载的 BV1JBuB6PEMF）：

  focus   0.55–1.15   侧身站着盯着前方，眨一下眼（只留眨眼前后这半秒，播一次的开销小）。第一帧是平时的站姿；
                      干活时推近成侧脸特写（惊鸿一瞥）隔几秒播一次
  glance  1.90–2.13   原片在 2.08 秒一刀切成四分之三正面、直直看着你；等你批准时用最后一帧的特写
  laugh   2.15–6.20   捧腹大笑：毫无征兆地爆笑，仰头笑、弯腰笑、正面捧着肚子笑（大活做完）
  roll    2.15–3.90 + 72.0–77.6   笑到倒地打滚：开笑后剪到原片结尾的仰面摔倒、躺地打滚（超长任务做完）

处理：rembg（isnet-general-use）逐帧抠白底，结果缓存在 build/cut/；所有片段用同一个方形裁剪框（全部帧里
奶蛙出现过的范围的并集，脚底贴着框底，头顶留一点空），切换状态时奶蛙不会跳；预乘透明度后编成 HEVC（VideoToolbox；
HEVC 透明视频按预乘解释，不预乘边缘会发白）。另外算出侧脸和转头两张特写的取景框写进 assets.json。

focus、glance 要推近成头部特写显示，原片只有 480P，直接放大会糊：这两段先按裁剪框截出原片，用 Real-ESRGAN
（realesrgan-x4plus，比 anime 系列少描边、保留 3D 软胶质感）放大 4 倍再抠图，存成 2 倍尺寸。取景和其他片段完全一致。

需要：macOS 上的 ffmpeg、rembg（pip install "rembg[cpu]"）、realesrgan-ncnn-vulkan（REALESRGAN 指向它所在目录，
目录里要有 models/）。
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
FPS = 30
CLIPS = {
    "focus": [(0.55, 1.15)],
    "glance": [(1.90, 2.13)],
    "laugh": [(2.15, 6.20)],
    "roll": [(2.15, 3.90), (72.0, 77.6)],
}
HIRES = {"focus", "glance"}   # 要推近成特写的片段：超分后存 2 倍尺寸
CLOSEUP = 0.38   # 特写取景框占整个画面的比例（边长）


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *map(str, args)], check=True)


def segment(src: Path, start: float, end: float) -> list[Path]:
    cache = ROOT / "build" / "cut" / f"{src.stem}_{start:.2f}_{end:.2f}"
    if not cache.exists() or not any(cache.glob("*.png")):
        from rembg import new_session, remove

        raw = cache.with_name(cache.name + "_raw")
        shutil.rmtree(raw, ignore_errors=True)
        raw.mkdir(parents=True)
        ffmpeg("-ss", start, "-t", end - start, "-i", src, "-vf", f"fps={FPS}", raw / "%04d.png")
        cache.mkdir(parents=True, exist_ok=True)
        session = new_session("isnet-general-use", providers=["CPUExecutionProvider"])
        for p in sorted(raw.glob("*.png")):
            remove(Image.open(p), session=session).save(cache / p.name)
        shutil.rmtree(raw)
    return sorted(cache.glob("*.png"))


def head_box(alpha: np.ndarray) -> dict:
    """头部特写的取景框（0–1 的比例，原点在左上）：贴着奶蛙最上面那一截，水平对准头的中心，头顶留一点空"""
    n = alpha.shape[0]
    side = round(n * CLOSEUP)
    top = int(np.nonzero(alpha.max(axis=1) > 128)[0].min())
    band = alpha[top: top + int(side * 0.8)] > 128
    cx = float(np.nonzero(band.any(axis=0))[0].mean())
    x = min(max(cx - side / 2, 0), n - side)
    y = min(max(top - n * 0.03, 0), n - side)
    return {"x": round(x / n, 4), "y": round(y / n, 4), "w": round(side / n, 4), "h": round(side / n, 4)}


def hires(src: Path, start: float, end: float, box: tuple) -> list[Path]:
    """按裁剪框截原片 → Real-ESRGAN 放大 4 倍 → 抠图。结果缓存在 build/cut/"""
    x0, y0, x1, y1 = box
    cache = ROOT / "build" / "cut" / f"{src.stem}_{start:.2f}_{end:.2f}_x4_{x0}_{y0}_{x1}_{y1}"
    if not cache.exists() or not any(cache.glob("*.png")):
        import os
        from rembg import new_session, remove

        tool = Path(os.environ.get("REALESRGAN", "/usr/local/opt/realesrgan"))
        raw, up = cache.with_name(cache.name + "_raw"), cache.with_name(cache.name + "_up")
        for d in (raw, up):
            shutil.rmtree(d, ignore_errors=True)
            d.mkdir(parents=True)
        # 裁剪框可能伸出画面（头顶留空），先用白边补齐再截
        ffmpeg("-ss", start, "-t", end - start, "-i", src,
               "-vf", f"fps={FPS},pad=iw+{x1}:ih+{y1}:{max(0, -x0)}:{max(0, -y0)}:white,crop={x1 - x0}:{y1 - y0}:{max(0, x0)}:{max(0, y0)}",
               raw / "%04d.png")
        subprocess.run([tool / "realesrgan-ncnn-vulkan", "-i", raw, "-o", up, "-n", "realesrgan-x4plus", "-s", "4", "-m", tool / "models"],
                       check=True, capture_output=True)
        cache.mkdir(parents=True, exist_ok=True)
        session = new_session("isnet-general-use", providers=["CPUExecutionProvider"])
        for p in sorted(up.glob("*.png")):
            remove(Image.open(p), session=session).save(cache / p.name)
        shutil.rmtree(raw)
        shutil.rmtree(up)
    return sorted(cache.glob("*.png"))


def premultiplied(path: Path) -> np.ndarray:
    a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32) / 255
    a[..., :3] *= a[..., 3:]
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--size", type=int, default=384)
    o = ap.parse_args()
    src = Path(o.src).resolve()

    frames = {name: [premultiplied(p) for a, b in parts for p in segment(src, a, b)] for name, parts in CLIPS.items()}

    union = np.zeros(frames["laugh"][0].shape[:2], bool)
    for fs in frames.values():
        for f in fs:
            union |= f[..., 3] > 0.5
    ys, xs = np.nonzero(union)
    top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    side = int(max(bottom - top, right - left) * 1.05) + 8   # 头顶留一点空，推近成特写时头不贴边
    cx = (left + right) // 2
    box = (int(cx - side // 2), int(bottom + 4 - side), int(cx - side // 2 + side), int(bottom + 4))

    # 特写片段换成超分后的帧：已经按裁剪框截好了，后面裁剪框就是整张
    for name in HIRES:
        frames[name] = [premultiplied(p) for a, b in CLIPS[name] for p in hires(src, a, b, box)]

    assets = ROOT / "assets"
    shutil.rmtree(assets, ignore_errors=True)
    assets.mkdir()
    meta = {"fps": FPS, "clips": {}, "closeup": {}}
    for name, fs in frames.items():
        size = o.size * 2 if name in HIRES else o.size
        crop = (0, 0, fs[0].shape[1], fs[0].shape[0]) if name in HIRES else box
        with tempfile.TemporaryDirectory() as tmp:
            for i, f in enumerate(fs):
                # 已经是预乘的：按 RGBa 缩放，再把预乘值原样写进 PNG 交给编码器
                px = (f * 255 + 0.5).astype(np.uint8)
                im = Image.frombytes("RGBa", (px.shape[1], px.shape[0]), px.tobytes()).crop(crop).resize((size, size), Image.LANCZOS)
                Image.frombytes("RGBA", im.size, im.tobytes()).save(Path(tmp) / f"{i:04d}.png")
                if (name, i) in (("focus", 0), ("glance", len(fs) - 1)):
                    meta["closeup"][name] = head_box(np.asarray(im)[..., 3])
            ffmpeg("-framerate", FPS, "-i", Path(tmp) / "%04d.png",
                   "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.9", "-q:v", "75", "-tag:v", "hvc1", "-pix_fmt", "bgra",
                   assets / f"{name}.mov")
        meta["clips"][name] = {"video": f"{name}.mov", "frames": len(fs)}
        print(f"{name}: {len(fs)} 帧 {len(fs) / FPS:.2f} 秒，{(assets / f'{name}.mov').stat().st_size // 1024}KB")
    (assets / "assets.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n")
    print("裁剪框", box)


if __name__ == "__main__":
    main()
