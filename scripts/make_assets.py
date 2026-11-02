"""原版《奶蛙大笑》视频 → assets/laugh.mov（带透明通道的 HEVC）+ assets/laugh.m4a（同一段原声）。

  python scripts/make_assets.py <源视频.mp4> [--start 2.0] [--end 6.2] [--fade 0] [--size 320]

1. 截取 start–end 这一段（默认：面无表情站着的最后一刻 → 突然爆笑 → 一口气笑完）
2. rembg（isnet-general-use）逐帧抠掉白底；结果缓存在 build/cut/，换参数不用重抠
3. 最后补一帧第一帧（站姿），视频首尾相同，播完直接回到待机。默认硬切回去：原片开笑就是硬切，
   「突然笑、突然停」；淡出（--fade N）在两个姿势差得远时会有重影
4. 全部帧统一裁成方形（所有帧里奶蛙出现过的范围的并集，脚底贴着框底），缩到 size
5. 预乘透明度后编成 HEVC（VideoToolbox；HEVC 透明视频按预乘解释，不预乘边缘会发白）
6. 同一段原声截出来，结尾淡出

需要：macOS 上的 ffmpeg、rembg（pip install "rembg[cpu]"）。
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


def ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-y", *args], check=True)


def segment(src: Path, start: float, end: float, fps: float) -> list[Path]:
    cache = ROOT / "build" / "cut" / f"{src.stem}_{start:.2f}_{end:.2f}"
    if not cache.exists() or not any(cache.glob("*.png")):
        from rembg import new_session, remove

        raw = cache.with_name(cache.name + "_raw")
        shutil.rmtree(raw, ignore_errors=True)
        raw.mkdir(parents=True)
        ffmpeg("-ss", str(start), "-t", str(end - start), "-i", str(src), "-vf", f"fps={fps}", str(raw / "%04d.png"))
        cache.mkdir(parents=True, exist_ok=True)
        session = new_session("isnet-general-use", providers=["CPUExecutionProvider"])
        for p in sorted(raw.glob("*.png")):
            remove(Image.open(p), session=session).save(cache / p.name)
        shutil.rmtree(raw)
    return sorted(cache.glob("*.png"))


def premultiplied(im: Image.Image) -> np.ndarray:
    a = np.asarray(im.convert("RGBA"), dtype=np.float32) / 255
    a[..., :3] *= a[..., 3:]
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--start", type=float, default=2.0)
    ap.add_argument("--end", type=float, default=6.2)
    ap.add_argument("--fade", type=int, default=0)
    ap.add_argument("--size", type=int, default=320)
    ap.add_argument("--fps", type=float, default=30)
    o = ap.parse_args()
    src = Path(o.src).resolve()

    frames = [premultiplied(Image.open(p)) for p in segment(src, o.start, o.end, o.fps)]
    idle, last = frames[0], frames[-1]
    # 笑完淡回站姿（在预乘空间里混合，边缘不会发灰），最后一帧和第一帧相同
    frames += [(1 - k / (o.fade + 1)) * last + (k / (o.fade + 1)) * idle for k in range(1, o.fade + 1)] + [idle]

    union = np.zeros(idle.shape[:2], bool)
    for f in frames:
        union |= f[..., 3] > 0.5
    ys, xs = np.nonzero(union)
    top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    side = max(bottom - top, right - left) + 8
    cx = (left + right) // 2
    box = (cx - side // 2, bottom + 4 - side, cx - side // 2 + side, bottom + 4)

    assets = ROOT / "assets"
    assets.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for i, f in enumerate(frames):
            # 已经是预乘的，按 RGBa 存进去缩放，再直接把预乘值写成 PNG 交给编码器
            px = (f * 255 + 0.5).astype(np.uint8)
            im = Image.frombytes("RGBa", (px.shape[1], px.shape[0]), px.tobytes()).crop(box).resize((o.size, o.size), Image.LANCZOS)
            Image.frombytes("RGBA", im.size, im.tobytes()).save(Path(tmp) / f"{i:04d}.png")
        ffmpeg("-framerate", str(o.fps), "-i", str(Path(tmp) / "%04d.png"),
               "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.8", "-q:v", "60", "-tag:v", "hvc1", "-pix_fmt", "bgra",
               str(assets / "laugh.mov"))

    dur = len(frames) / o.fps
    ffmpeg("-ss", str(o.start), "-t", str(dur), "-i", str(src), "-vn",
           "-af", f"afade=t=out:st={max(0, dur - 0.25):.2f}:d=0.25", "-ac", "1", "-c:a", "aac", "-b:a", "64k", str(assets / "laugh.m4a"))
    (assets / "laugh.json").write_text(json.dumps({"audioDelay": 0}) + "\n")
    print(f"{len(frames)} 帧 {dur:.2f} 秒，裁剪框 {box}；laugh.mov {(assets / 'laugh.mov').stat().st_size // 1024}KB，"
          f"laugh.m4a {(assets / 'laugh.m4a').stat().st_size // 1024}KB")


if __name__ == "__main__":
    main()
