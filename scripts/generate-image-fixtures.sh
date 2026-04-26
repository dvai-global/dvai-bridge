#!/usr/bin/env bash
# Generates the smoke-test image fixture used by RealModelSmokeTest.swift /
# RealModelSmokeTest.kt. The fixture is a 256x256 PNG with three primary-colour
# blocks (red / green / blue) on white — enough visual structure that a vision
# model has *something* to describe instead of immediately emitting EOS on a
# blank input. Run on any host with Python 3 + Pillow available; output goes
# to fixtures/images/.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p fixtures/images

python3 - << 'PY'
from PIL import Image, ImageDraw

# 256x256 keeps the file tiny (~ a few KB) while landing right at the patch
# resolution mtmd uses for gemma4v (16x16 patches × 16 = 256). Avoids
# extra resampling at inference time.
img = Image.new("RGB", (256, 256), color=(255, 255, 255))
d = ImageDraw.Draw(img)
# Three primary-colour squares in the top half, one large yellow circle in
# the bottom half. Picked to be unambiguous to a captioner.
d.rectangle([16, 16, 80, 80], fill=(255, 0, 0))
d.rectangle([96, 16, 160, 80], fill=(0, 200, 0))
d.rectangle([176, 16, 240, 80], fill=(0, 0, 255))
d.ellipse([64, 128, 192, 240], fill=(255, 220, 0))

img.save("fixtures/images/tiny-test.png", optimize=True)
print("wrote fixtures/images/tiny-test.png")

# Also refresh the base64 sibling so anything driving HTTP fixtures stays in
# sync with the binary asset.
import base64
with open("fixtures/images/tiny-test.png", "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")
with open("fixtures/images/tiny-test-base64.txt", "w", newline="\n") as f:
    f.write(b64)
print("wrote fixtures/images/tiny-test-base64.txt (%d chars)" % len(b64))
PY
