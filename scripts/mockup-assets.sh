#!/bin/zsh
# Build the stills, filmstrip sprites and waveform peaks that design/mockup.html shows.
#
#   scripts/mockup-assets.sh [--still SPEC] [--wide SPEC] [--peaks CLIP] SPEC…
#
# SPEC is  <clip>@<t0>-<t1>@<fx>,<fy>,<fw>[,wide]
#   t0-t1     the part of the clip to sample, in seconds
#   fx,fy,fw  a crop of the upright frame, as fractions of its width/height (fx, fw of width, fy of height);
#             the crop height follows from fw and the aspect (9:16, or 16:9 with ",wide")
# Each SPEC becomes one strip clip, sprite-NN.jpg (40 frames, 8x5, 2x of the 64 px deck strip:
# 72x128 cells, or 228x128 with ",wide"). The crops keep people out of frame (v1 ruling: no likeness).
#   --still SPEC  portrait still (720x1280, the midpoint of t0-t1); default: the first SPEC
#   --wide SPEC   landscape still (1600x900); default: the first ",wide" SPEC
#   --peaks CLIP  waveform source (whole clip, 20 ms max-abs); default: the --still clip
# saved-thumb.jpg (144x256) is the first SPEC at t0, the Reel's first frame.
# Clips are only read, never written. Every ffmpeg call is an argv array.
# Writes design/mockup-assets/{still-portrait,still-landscape,saved-thumb,sprite-NN}.jpg, peaks.json, peaks.js.
set -euo pipefail

ROOT="${0:A:h:h}"
OUT="$ROOT/design/mockup-assets"
BIN=/opt/homebrew/opt/ffmpeg-full/bin
FF=("$BIN/ffmpeg" -hide_banner -loglevel error -nostdin -y)
[[ -x "$BIN/ffmpeg" ]] || { echo "ffmpeg not found at $BIN" >&2; exit 1; }

still="" wide="" peaks=""
specs=()
while (( $# )); do
  case "$1" in
    --still) still="$2"; shift 2 ;;
    --wide)  wide="$2";  shift 2 ;;
    --peaks) peaks="$2"; shift 2 ;;
    *) specs+=("$1"); shift ;;
  esac
done
(( ${#specs} )) || { echo "usage: $0 [--still SPEC] [--wide SPEC] [--peaks CLIP] SPEC…" >&2; exit 2; }
[[ -n "$still" ]] || still="${specs[1]}"
if [[ -z "$wide" ]]; then for s in "${specs[@]}"; do [[ "$s" == *,wide ]] && { wide="$s"; break; }; done; fi

# parse SPEC → clip t0 t1 fx fy fw aspect   (reply array)
parse() {
  local s="$1" geo
  local clip="${s%%@*}" rest="${s#*@}"
  local span="${rest%%@*}"; geo="${rest#*@}"
  local -a g; g=("${(@s:,:)geo}")
  [[ -f "$clip" ]] || { echo "No such clip: $clip" >&2; exit 1; }
  reply=("$clip" "${span%-*}" "${span#*-}" "${g[1]}" "${g[2]}" "${g[3]}" "${g[4]:-tall}")
}
# crop filter for the upright frame (ffmpeg autorotates): width fw*iw, height from the aspect
cropvf() {  # fx fy fw aspect
  local ratio="16/9"; [[ "$4" == wide ]] && ratio="9/16"
  print -r -- "crop=w='trunc(iw*$3/2)*2':h='trunc(iw*$3*$ratio/2)*2':x='iw*$1':y='ih*$2'"
}
half() { python3 -I -c 'import sys; a,b=map(float,sys.argv[1:]); print(f"{(a+b)/2:.3f}")' "$1" "$2"; }

mkdir -p "$OUT"
rm -f "$OUT"/sprite-*.jpg(N)

n=0
for s in "${specs[@]}"; do
  n=$((n + 1)); parse "$s"; local -a p; p=("${reply[@]}")
  dur=$(python3 -I -c 'import sys; a,b=map(float,sys.argv[1:]); print(f"{b-a:.3f}")' "${p[2]}" "${p[3]}")
  fps=$(python3 -I -c 'import sys; print(f"{40/float(sys.argv[1]):.6f}")' "$dur")
  cell="72:128"; [[ "${p[7]}" == wide ]] && cell="228:128"
  "${FF[@]}" -ss "${p[2]}" -t "$dur" -i "${p[1]}" -an \
    -vf "fps=$fps,$(cropvf "${p[4]}" "${p[5]}" "${p[6]}" "${p[7]}"),scale=${cell}:flags=lanczos,tile=8x5" \
    -frames:v 1 -q:v 5 "$OUT/sprite-$(printf %02d $n).jpg"
done

parse "$still"; p=("${reply[@]}")
"${FF[@]}" -ss "$(half "${p[2]}" "${p[3]}")" -i "${p[1]}" -frames:v 1 \
  -vf "$(cropvf "${p[4]}" "${p[5]}" "${p[6]}" tall),scale=720:1280:flags=lanczos" -q:v 4 "$OUT/still-portrait.jpg"
[[ -n "$peaks" ]] || peaks="${p[1]}"

if [[ -n "$wide" ]]; then
  parse "$wide"; p=("${reply[@]}")
  "${FF[@]}" -ss "$(half "${p[2]}" "${p[3]}")" -i "${p[1]}" -frames:v 1 \
    -vf "$(cropvf "${p[4]}" "${p[5]}" "${p[6]}" wide),scale=1600:900:flags=lanczos" -q:v 5 "$OUT/still-landscape.jpg"
fi

parse "${specs[1]}"; p=("${reply[@]}")
"${FF[@]}" -ss "${p[2]}" -i "${p[1]}" -frames:v 1 \
  -vf "$(cropvf "${p[4]}" "${p[5]}" "${p[6]}" tall),scale=144:256:flags=lanczos" -q:v 4 "$OUT/saved-thumb.jpg"

# Peaks: mono max-abs, one value per 20 ms, normalised to the loudest value.
"${FF[@]}" -i "$peaks" -vn -ac 1 -ar 8000 -f f32le - | python3 -I -c '
import json, struct, sys
raw = sys.stdin.buffer.read()
n = len(raw) // 4
s = struct.unpack(f"<{n}f", raw[: n * 4])
win = 160  # 20 ms at 8 kHz
p = [max(abs(v) for v in s[i:i + win]) for i in range(0, n, win)] or [0.0]
top = max(p) or 1.0
json.dump({"rate": 50, "peaks": [round(v / top, 3) for v in p]}, sys.stdout, separators=(",", ":"))
' > "$OUT/peaks.json"
# Same data as a script: WebKit refuses fetch() of file:// URLs and the mockup is opened from disk.
{ printf 'window.MOCKUP_PEAKS = '; cat "$OUT/peaks.json"; printf ';\n'; } > "$OUT/peaks.js"

for f in "$OUT"/*; do
  sz=$(stat -f %z "$f")
  (( sz < 300000 )) || { echo "Too large (${sz} B): $f" >&2; exit 1; }
done
ls -l "$OUT"
