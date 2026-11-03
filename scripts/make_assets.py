"""原版《奶蛙大笑》视频 → assets/ 下几段带透明通道的 HEVC 和对应原声。

  python scripts/make_assets.py <源视频.mp4> [--size 320]

片段全部取自同一个原片（scripts/fetch_source.sh 下载的 BV1JBuB6PEMF）：

  focus   0.00–1.10   专注：侧身一本正经地盯着前方，中间眨一下眼（干活时隔几秒播一次）
  glance  1.90–2.13   惊鸿一瞥：侧身盯着前方，原片在 2.08 秒一刀切成四分之三正面、直直看着你（等你确认时放大播，停在最后一帧）
  laugh   2.15–6.20   捧腹大笑：毫无征兆地爆笑，仰头笑、弯腰笑、正面捧着肚子笑（大活做完）
  roll    2.15–3.90 + 72.0–77.6   笑到倒地打滚：开笑后剪到原片结尾的仰面摔倒、躺地打滚（超长任务做完）

处理：rembg（isnet-general-use）逐帧抠白底，结果缓存在 build/cut/；所有片段用同一个方形裁剪框（全部帧里
奶蛙出现过的范围的并集，脚底贴着框底），切换状态时奶蛙不会跳；预乘透明度后编成 HEVC（VideoToolbox；HEVC 透明
视频按预乘解释，不预乘边缘会发白）；有声音的片段截同一段原声，结尾淡出。

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
FPS = 30
CLIPS = {
    "focus": {"parts": [(0.00, 1.10)], "sound": False},
    "glance": {"parts": [(1.90, 2.13)], "sound": False},
    "laugh": {"parts": [(2.15, 6.20)], "sound": True},
    "roll": {"parts": [(2.15, 3.90), (72.0, 77.6)], "sound": True},
}


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


def premultiplied(path: Path) -> np.ndarray:
    a = np.asarray(Image.open(path).convert("RGBA"), dtype=np.float32) / 255
    a[..., :3] *= a[..., 3:]
    return a


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("--size", type=int, default=320)
    o = ap.parse_args()
    src = Path(o.src).resolve()

    frames = {name: [premultiplied(p) for a, b in c["parts"] for p in segment(src, a, b)] for name, c in CLIPS.items()}

    union = np.zeros(frames["laugh"][0].shape[:2], bool)
    for fs in frames.values():
        for f in fs:
            union |= f[..., 3] > 0.5
    ys, xs = np.nonzero(union)
    top, bottom, left, right = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    side = max(bottom - top, right - left) + 8
    cx = (left + right) // 2
    box = (int(cx - side // 2), int(bottom + 4 - side), int(cx - side // 2 + side), int(bottom + 4))

    assets = ROOT / "assets"
    shutil.rmtree(assets, ignore_errors=True)
    assets.mkdir()
    meta = {"fps": FPS, "clips": {}}
    for name, fs in frames.items():
        with tempfile.TemporaryDirectory() as tmp:
            for i, f in enumerate(fs):
                # 已经是预乘的：按 RGBa 缩放，再把预乘值原样写进 PNG 交给编码器
                px = (f * 255 + 0.5).astype(np.uint8)
                im = Image.frombytes("RGBa", (px.shape[1], px.shape[0]), px.tobytes()).crop(box).resize((o.size, o.size), Image.LANCZOS)
                Image.frombytes("RGBA", im.size, im.tobytes()).save(Path(tmp) / f"{i:04d}.png")
            ffmpeg("-framerate", FPS, "-i", Path(tmp) / "%04d.png",
                   "-c:v", "hevc_videotoolbox", "-alpha_quality", "0.8", "-q:v", "60", "-tag:v", "hvc1", "-pix_fmt", "bgra",
                   assets / f"{name}.mov")
        entry = {"video": f"{name}.mov", "frames": len(fs)}
        if CLIPS[name]["sound"]:
            parts = CLIPS[name]["parts"]
            dur = len(fs) / FPS
            # 多段拼接：每段两头各 15 毫秒淡入淡出，接缝不爆音；整段结尾 0.25 秒淡出
            chains = "".join(f"[0:a]atrim={a}:{b},asetpts=N/SR/TB,afade=t=in:d=0.015,afade=t=out:st={b - a - 0.015:.3f}:d=0.015[a{i}];"
                             for i, (a, b) in enumerate(parts))
            graph = chains + "".join(f"[a{i}]" for i in range(len(parts))) + f"concat=n={len(parts)}:v=0:a=1,afade=t=out:st={max(0, dur - 0.25):.2f}:d=0.25[out]"
            ffmpeg("-i", src, "-filter_complex", graph, "-map", "[out]", "-ac", 1, "-c:a", "aac", "-b:a", "64k", assets / f"{name}.m4a")
            entry["sound"] = f"{name}.m4a"
        meta["clips"][name] = entry
        print(f"{name}: {len(fs)} 帧 {len(fs) / FPS:.2f} 秒，{(assets / f'{name}.mov').stat().st_size // 1024}KB")
    (assets / "assets.json").write_text(json.dumps(meta, ensure_ascii=False, indent=1) + "\n")
    print("裁剪框", box)


if __name__ == "__main__":
    main()
