#!/usr/bin/env bash
# Assemble the SUBSECOND motion video: crop the no-sandbox bar, mux ElevenLabs
# narration at MEASURED scene times (contact-sheet derived). Captions are in-page.
set -euo pipefail
S=/home/ubuntu/.hermes/cache/scratch
N=$S/mn
RAW=/tmp/subsecond-motion-raw.mp4
OUT=/home/ubuntu/subsecond/assets/subsecond-motion.mp4

ffmpeg -y -i "$RAW" -i "$N/n0.mp3" -i "$N/n1.mp3" -i "$N/n2.mp3" -i "$N/n3.mp3" -i "$N/n4.mp3" -i "$N/n5.mp3" -i "$N/n6.mp3" \
-filter_complex "\
[0:v]crop=1600:856:0:44[v];\
[1:a]adelay=3400|3400[a0];[2:a]adelay=16500|16500[a1];[3:a]adelay=23500|23500[a2];[4:a]adelay=31000|31000[a3];\
[5:a]adelay=45500|45500[a4];[6:a]adelay=55500|55500[a5];[7:a]adelay=63500|63500[a6];\
[a0][a1][a2][a3][a4][a5][a6]amix=inputs=7:duration=longest:normalize=0[mix];[mix]apad,atrim=0:72[a]" \
-map "[v]" -map "[a]" -c:v libx264 -pix_fmt yuv420p -crf 19 -preset medium -c:a aac -b:a 160k "$OUT" -loglevel error

echo "OUT=$OUT"; ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"; ls -la "$OUT"
