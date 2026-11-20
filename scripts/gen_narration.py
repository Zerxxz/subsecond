#!/usr/bin/env python3
"""Generate ElevenLabs narration clips for the SUBSECOND motion demo.
Reads the key from the environment (never hardcoded). One clip per scene.
"""
import json, os, sys, urllib.request, subprocess

KEY = os.environ.get("ELEVENLABS_API_KEY") or os.environ.get("EL_KEY")
if not KEY:
    sys.exit("Set ELEVENLABS_API_KEY")
VOICE = "JBFqnCBsd6RMkjVDRZzb"  # George - Warm, Captivating Storyteller
OUT = "/home/ubuntu/.hermes/cache/scratch/mn"  # motion narration
os.makedirs(OUT, exist_ok=True)

LINES = [
    "Every second counts. Two pools on Base Sepolia hold the same asset, and for a fraction of a second their prices drift apart.",
    "A bot that checks every seven seconds never sees it. A whole second of profit, gone before it can react.",
    "Subsecond runs on Reactive Omni, with one second blocks and instant finality.",
    "A reactive contract on Lasna reads both pools straight from the event log, spots the gap, and fires a callback.",
    "The callback lands on Base Sepolia in about one second, and the executor closes the gap on chain.",
    "Five live loops. Five captures. One point four seconds average, and about two thousand two hundred dollars of testnet profit.",
    "Reactive Omni. Subsecond. Every second counts.",
]

for i, text in enumerate(LINES):
    path = f"{OUT}/n{i}.mp3"
    body = json.dumps({
        "text": text,
        "model_id": "eleven_turbo_v2_5",
        "voice_settings": {"stability": 0.5, "similarity_boost": 0.75, "style": 0.3},
    }).encode()
    req = urllib.request.Request(f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE}",
                                 data=body, headers={"xi-api-key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as r:
        data = r.read()
    open(path, "wb").write(data)
    dur = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration",
                          "-of", "csv=p=0", path], capture_output=True, text=True).stdout.strip()
    print(f"n{i}: {len(data)}B  {dur}s  {text[:50]}...")
print("total chars:", sum(len(l) for l in LINES))
