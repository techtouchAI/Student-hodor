#!/usr/bin/env python3
"""Fetch Tajawal (Arabic) fonts from the npm registry (@fontsource), convert
woff2 -> ttf and merge arabic+latin subsets into single TTF files committed to
assets/fonts/. Keeps the build reproducible offline: resulting TTFs + licenses
are vendored in-repo. Run only when fonts need refreshing.
"""
import io
import json
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

from fontTools import merge
from fontTools.ttLib import TTFont

ROOT = Path(__file__).resolve().parents[1]
FONTS_OUT = ROOT / "assets" / "fonts"
SRC = ROOT / "tools" / "fonts_src"
PKG = "@fontsource/tajawal"

WEIGHTS = {400: "Tajawal-Regular.ttf", 700: "Tajawal-Bold.ttf"}


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=60) as r:
        return r.read()


def woff2_to_ttfont(data: bytes) -> TTFont:
    f = TTFont(io.BytesIO(data))
    if f.flavor == "woff2":
        f.flavor = None
    return f


def main() -> None:
    SRC.mkdir(parents=True, exist_ok=True)
    FONTS_OUT.mkdir(parents=True, exist_ok=True)

    packument = json.loads(fetch(f"https://registry.npmjs.org/{PKG}"))
    version = packument["dist-tags"]["latest"]
    tarball = packument["versions"][version]["dist"]["tarball"]
    print(f"fetching {PKG}@{version}")
    raw = fetch(tarball)
    with tarfile.open(fileobj=io.BytesIO(raw)) as tf:
        members = [m for m in tf.getmembers() if m.isfile()]
        tf.extractall(SRC)
        names = [m.name for m in members]
    for weight, out_name in WEIGHTS.items():
        part_paths = []
        for subset in ("arabic", "latin"):
            cand = [
                n
                for n in names
                if n.endswith(f"{subset}-{weight}-normal.woff2")
            ]
            if not cand:
                raise SystemExit(f"missing {subset} {weight} in {names[:20]}...")
            data = (SRC / cand[0]).read_bytes()
            font = woff2_to_ttfont(data)
            tmp = SRC / f"{out_name}.{subset}.tmp.ttf"
            font.save(str(tmp))
            part_paths.append(tmp)
        merger = merge.Merger()
        merged = merger.merge([str(p) for p in part_paths])
        out = FONTS_OUT / out_name
        merged.save(str(out))
        for p in part_paths:
            p.unlink(missing_ok=True)
        check = TTFont(str(out))
        cmap = check.getBestCmap()
        for cp, label in ((0x0623, "arabic alef"), (0x0041, "latin A"), (0x0030, "digit 0")):
            assert cp in cmap, f"{out_name} missing {label}"
        print(f"ok {out} glyphs={len(cmap)}")

    for lic in (SRC / "package").glob("LICENSE*"):
        target = FONTS_OUT / f"LICENSE-OFL-Tajawal.txt"
        target.write_bytes(lic.read_bytes())
        print(f"license -> {target.name}")
    print("fonts ready")


if __name__ == "__main__":
    sys.exit(main())
