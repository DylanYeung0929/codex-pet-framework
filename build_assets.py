#!/usr/bin/env python3
"""Extract composited frames from the Codex pet WebP animations."""
import json
import re
import shutil
import subprocess
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "source"
OUT = ROOT / "assets"
ALPHA_MIN = 8
MARGIN = 2
DEFAULT_MS = 100

MOTIONS = [
    ("idle", "待机"),
    ("waving", "招手"),
    ("jumping", "跳跃"),
    ("review", "回看"),
    ("waiting", "等待"),
    ("running", "奔跑"),
    ("running-left", "向左奔跑"),
    ("running-right", "向右奔跑"),
    ("failed", "失败"),
    ("debug", "调试机械臂"),
]

# Codex hatch-pet V2 atlas: 8 cols x 11 rows of 192x208 cells.
# Row layout and durations follow ~/.codex/skills/hatch-pet/references/animation-rows.md
ATLAS_CELL = (192, 208)
ATLAS_ROWS = {
    "idle": (0, 6, [280, 110, 110, 140, 140, 320]),
    "running-right": (1, 8, [120] * 7 + [220]),
    "running-left": (2, 8, [120] * 7 + [220]),
    "waving": (3, 4, [140, 140, 140, 280]),
    "jumping": (4, 5, [140, 140, 140, 140, 280]),
    "failed": (5, 8, [140] * 7 + [240]),
    "waiting": (6, 6, [150] * 5 + [260]),
    "running": (7, 6, [120] * 5 + [220]),
    "review": (8, 6, [150] * 5 + [280]),
    "debug": (9, 8, [150] * 7 + [300]),
}


def build_from_atlas(path: Path) -> None:
    sheet = Image.open(path).convert("RGBA")
    cw, ch = ATLAS_CELL
    manifest = {"motions": []}

    for key, name in MOTIONS:
        row, count, durations = ATLAS_ROWS[key]
        frames = []
        boxes = []
        for i in range(count):
            frame = sheet.crop((i * cw, row * ch, (i + 1) * cw, (row + 1) * ch))
            frames.append(frame)
            boxes.append(
                frame.getchannel("A").point(lambda v: 255 if v > ALPHA_MIN else 0).getbbox()
            )
        if any(b is None for b in boxes):
            raise SystemExit(f"atlas row {row} ({key}) has an empty frame")

        x0 = max(0, min(b[0] for b in boxes) - MARGIN)
        y0 = max(0, min(b[1] for b in boxes) - MARGIN)
        x1 = min(cw, max(b[2] for b in boxes) + MARGIN)
        y1 = min(ch, max(b[3] for b in boxes) + MARGIN)

        motion_dir = OUT / key
        if motion_dir.exists():
            shutil.rmtree(motion_dir)
        motion_dir.mkdir(parents=True)

        rel_frames = []
        for i, frame in enumerate(frames):
            out = frame.crop((x0, y0, x1, y1))
            rel = f"{key}/{i:03d}.png"
            out.save(OUT / rel, optimize=True)
            rel_frames.append(rel)

        manifest["motions"].append(
            {
                "key": key,
                "name": name,
                "crop": [x0, y0, x1 - x0, y1 - y0],
                "durations": durations,
                "frames": rel_frames,
            }
        )
        print(f"{key:14} {count} frames  {x1 - x0}x{y1 - y0}")

    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"manifest -> {OUT / 'manifest.json'}")


def frame_durations(path: Path) -> list[int]:
    mux = shutil.which("webpmux")
    if not mux:
        return []
    out = subprocess.run(
        [mux, "-info", str(path)], capture_output=True, text=True, check=False
    ).stdout
    durations = []
    for line in out.splitlines():
        if re.match(r"^\s*\d+:", line):
            parts = line.split()
            durations.append(int(parts[6]))
    return durations


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)

    atlas = SRC / "atlas.webp"
    if atlas.exists():
        build_from_atlas(atlas)
        return

    manifest = {"motions": []}

    for key, name in MOTIONS:
        path = SRC / f"{key}.webp"
        im = Image.open(path)
        durations = frame_durations(path)
        if len(durations) != im.n_frames:
            durations = [DEFAULT_MS] * im.n_frames

        frames = []
        boxes = []
        for i in range(im.n_frames):
            im.seek(i)
            frame = im.convert("RGBA")
            frames.append(frame)
            boxes.append(
                frame.getchannel("A").point(lambda v: 255 if v > ALPHA_MIN else 0).getbbox()
            )

        visible = [b for b in boxes if b is not None]
        if not visible:
            raise SystemExit(f"{key} has no visible frames")
        x0 = min(b[0] for b in visible) - MARGIN
        y0 = min(b[1] for b in visible) - MARGIN
        x1 = max(b[2] for b in visible) + MARGIN
        y1 = max(b[3] for b in visible) + MARGIN
        x0 = max(0, x0)
        y0 = max(0, y0)
        x1 = min(im.width, x1)
        y1 = min(im.height, y1)
        crop = (x0, y0, x1, y1)

        motion_dir = OUT / key
        if motion_dir.exists():
            shutil.rmtree(motion_dir)
        motion_dir.mkdir(parents=True)

        rel_frames = []
        for i, frame in enumerate(frames):
            out = frame.crop(crop)
            rel = f"{key}/{i:03d}.png"
            out.save(OUT / rel, optimize=True)
            rel_frames.append(rel)

        manifest["motions"].append(
            {
                "key": key,
                "name": name,
                "crop": [x0, y0, x1 - x0, y1 - y0],
                "durations": durations,
                "frames": rel_frames,
            }
        )
        print(f"{key:14} {len(frames)} frames  {x1 - x0}x{y1 - y0}")

    (OUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    print(f"manifest -> {OUT / 'manifest.json'}")


if __name__ == "__main__":
    main()
