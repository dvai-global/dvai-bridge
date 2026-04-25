#!/usr/bin/env bash
# Generates 1-second 16kHz mono test audio fixtures using macOS's built-in afconvert.
# No third-party deps required — afconvert is part of CoreAudio.
# Run on Mac. Output: fixtures/audio/.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p fixtures/audio

# Step 1: generate raw PCM16 (1 second @ 16kHz mono = 32000 bytes) using Python's wave module
python3 - << 'PY'
import math, struct, os
os.makedirs("fixtures/audio", exist_ok=True)
sr = 16000
duration = 1.0
freq = 440.0  # A4 sine wave
n = int(sr * duration)

# Raw PCM16 little-endian
with open("fixtures/audio/pcm16-1s-16khz-mono.bin", "wb") as f:
    for i in range(n):
        sample = int(0.3 * 32767 * math.sin(2 * math.pi * freq * i / sr))
        f.write(struct.pack("<h", sample))

# WAV (RIFF wrapper around the same PCM)
import wave
with wave.open("fixtures/audio/wav-1s-16khz-mono.wav", "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(sr)
    with open("fixtures/audio/pcm16-1s-16khz-mono.bin", "rb") as src:
        w.writeframes(src.read())
PY

# Step 2: convert WAV to M4A using afconvert (built-in).
# Note: afconvert's AAC encoder rejects -b 64000 at 16kHz mono on some macOS
# builds with 'Couldn't set audio converter property (!dat)'. Letting afconvert
# pick the default bitrate produces a valid AAC-in-MP4 file (~6 KB / 1s mono).
afconvert -f m4af -d aac fixtures/audio/wav-1s-16khz-mono.wav fixtures/audio/m4a-1s.m4a

echo "Audio fixtures generated:"
ls -lh fixtures/audio/
