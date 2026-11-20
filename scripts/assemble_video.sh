#!/usr/bin/env bash
# Assemble the SUBSECOND demo video: crop the no-sandbox bar, title/outro cards,
# burned captions on the FINAL timeline, and per-action narration clips muxed in.
set -euo pipefail
S=/home/ubuntu/.hermes/cache/scratch
RAW=/tmp/subsecond-raw.mp4
OUT=/home/ubuntu/subsecond/assets/subsecond-demo.mp4
FONT=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
BOLD=/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf
W=1600; BH=856   # body height after cropping the 44px top bar

# 1) crop the body (remove the --no-sandbox infobar)
ffmpeg -y -i "$RAW" -vf "crop=${W}:${BH}:0:44" -r 24 -c:v libx264 -pix_fmt yuv420p -crf 20 "$S/body.mp4" -loglevel error

# 2) title card (4s)
ffmpeg -y -f lavfi -i "color=c=0x0a0e14:s=${W}x${BH}:d=4:r=24" -vf "\
drawtext=fontfile=$BOLD:text='SUBSECOND':fontcolor=0x22d3ee:fontsize=104:x=(w-tw)/2:y=(h-th)/2-70,\
drawtext=fontfile=$FONT:text='A sub-second arbitrage reflex on Reactive Omni':fontcolor=0xe6edf5:fontsize=34:x=(w-tw)/2:y=(h-th)/2+70,\
drawtext=fontfile=$FONT:text='Base Sepolia 200ms origin blocks  ·  Reactive Lasna ~1s finality':fontcolor=0x8595a8:fontsize=24:x=(w-tw)/2:y=(h-th)/2+130" \
-c:v libx264 -pix_fmt yuv420p "$S/title.mp4" -loglevel error

# 3) outro card (4.83s)
ffmpeg -y -f lavfi -i "color=c=0x0a0e14:s=${W}x${BH}:d=4.83:r=24" -vf "\
drawtext=fontfile=$BOLD:text='5 / 5 captured  ·  1.4s avg full-loop  ·  +2,197 sUSDC':fontcolor=0x34d399:fontsize=40:x=(w-tw)/2:y=(h-th)/2-70,\
drawtext=fontfile=$FONT:text='Reactive Omni Buildathon  ·  Every Second Counts':fontcolor=0xe6edf5:fontsize=30:x=(w-tw)/2:y=(h-th)/2+10,\
drawtext=fontfile=$BOLD:text='github.com/Zerxxz/subsecond':fontcolor=0x22d3ee:fontsize=34:x=(w-tw)/2:y=(h-th)/2+80" \
-c:v libx264 -pix_fmt yuv420p "$S/outro.mp4" -loglevel error

# 4) concat title + body + outro
printf "file '%s'\nfile '%s'\nfile '%s'\n" "$S/title.mp4" "$S/body.mp4" "$S/outro.mp4" > "$S/list.txt"
ffmpeg -y -f concat -safe 0 -i "$S/list.txt" -c copy "$S/combined.mp4" -loglevel error

# 5) captions burned on the final timeline + narration muxed at action timestamps
ffmpeg -y -i "$S/combined.mp4" -i "$S/narr1.ogg" -i "$S/narr2.ogg" -i "$S/narr3.ogg" -i "$S/narr4.ogg" -i "$S/narr5.ogg" \
-filter_complex "\
[0:v]drawtext=fontfile=$BOLD:text='Two Base Sepolia pools drift apart for a fraction of a second':fontcolor=white:fontsize=30:box=1:boxcolor=black@0.6:boxborderw=16:x=(w-tw)/2:y=h-th-42:enable='between(t,5,14)'[v1];\
[v1]drawtext=fontfile=$BOLD:text='A reactive contract on Lasna rebuilds both prices from the logs and fires in ~1s':fontcolor=white:fontsize=30:box=1:boxcolor=black@0.6:boxborderw=16:x=(w-tw)/2:y=h-th-42:enable='between(t,14,26)'[v2];\
[v2]drawtext=fontfile=$BOLD:text='Five of five loops executed - each in 1 to 2 seconds':fontcolor=white:fontsize=30:box=1:boxcolor=black@0.6:boxborderw=16:x=(w-tw)/2:y=h-th-42:enable='between(t,26,40)'[v3];\
[v3]drawtext=fontfile=$BOLD:text='At legacy ~7s these windows would already be closed':fontcolor=white:fontsize=30:box=1:boxcolor=black@0.6:boxborderw=16:x=(w-tw)/2:y=h-th-42:enable='between(t,40,56)'[v4];\
[v4]drawtext=fontfile=$BOLD:text='SUBSECOND - Every Second Counts - github.com/Zerxxz/subsecond':fontcolor=white:fontsize=30:box=1:boxcolor=black@0.6:boxborderw=16:x=(w-tw)/2:y=h-th-42:enable='between(t,56,64.8)'[v];\
[1:a]adelay=4500|4500[a1];[2:a]adelay=14000|14000[a2];[3:a]adelay=26000|26000[a3];[4:a]adelay=40000|40000[a4];[5:a]adelay=56000|56000[a5];\
[a1][a2][a3][a4][a5]amix=inputs=5:duration=longest:normalize=0[mix];[mix]apad,atrim=0:70[a]" \
-map "[v]" -map "[a]" -c:v libx264 -pix_fmt yuv420p -crf 20 -c:a aac -b:a 128k "$OUT" -loglevel error

echo "OUT=$OUT"
ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT"
ls -la "$OUT"
