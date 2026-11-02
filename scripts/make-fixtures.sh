#!/bin/zsh
# Generate the media test fixtures into Packages/TrimlabKit/Tests/Fixtures/ (git-ignored),
# then assert each fixture's probed properties with ffprobe. Exits non-zero on any mismatch.
#   scripts/make-fixtures.sh [--force]
# Uses ffmpeg-full only. Writes .recipe-sha (SHA-256 of this script) last.
set -euo pipefail

BIN=/opt/homebrew/opt/ffmpeg-full/bin
FFMPEG="$BIN/ffmpeg"
FFPROBE="$BIN/ffprobe"
for tool in "$FFMPEG" "$FFPROBE"; do
  if [[ ! -x "$tool" ]]; then
    print -u2 "ffprobe not found at /opt/homebrew/opt/ffmpeg-full/bin"
    exit 1
  fi
done

ROOT="${0:A:h:h}"
OUT="$ROOT/Packages/TrimlabKit/Tests/Fixtures"
SHA="$(shasum -a 256 "${0:A}" | cut -d' ' -f1)"
FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

NAMES=(portrait_hevc.mov rotated.mov landscape.mp4 hlg.mov noaudio.mp4 vfr.mp4 odd.mp4 over3.mp4
       "spaced é/clip é 1.mov" sixty.mp4 mono44k.mov sample.mkv sample.avi theora.mkv
       keyframes.mp4 tiny.mp4 corrupt.mov notes.txt still.jpg dark.mp4 bright.mp4 tone660.mov shortaudio.mp4 lateaudio.mp4 bright60.mp4 grain.mp4 hlgbright.mov hlgramp.mov pqramp.mov)

if (( ! FORCE )) && [[ -f "$OUT/.recipe-sha" && "$(cat "$OUT/.recipe-sha")" == "$SHA" ]]; then
  fresh=1
  for n in $NAMES; do [[ -e "$OUT/$n" ]] || fresh=0; done
  if (( fresh )); then exit 0; fi
fi

rm -rf "$OUT"
mkdir -p "$OUT"

ff() { "$FFMPEG" -loglevel error -y "$@"; }
X265Q="log-level=error"

# ---- recipes ------------------------------------------------------------------------------
ff -f lavfi -i "testsrc2=s=1080x1920:r=30000/1001:d=5" -f lavfi -i "sine=f=440:d=5" \
  -c:v libx265 -tag:v hvc1 -x265-params "$X265Q" -c:a aac -shortest "$OUT/portrait_hevc.mov"

ff -f lavfi -i "testsrc2=s=1920x1080:r=30:d=3" -c:v libx264 -preset ultrafast "$OUT/_base.mp4"
ff -display_rotation:v:0 90 -i "$OUT/_base.mp4" -c copy "$OUT/rotated.mov"
rm "$OUT/_base.mp4"

ff -f lavfi -i "testsrc2=s=3840x2160:r=30:d=5" -f lavfi -i "sine=f=440:d=5" \
  -c:v libx264 -preset ultrafast -g 30 -c:a aac -shortest "$OUT/landscape.mp4"

ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=3" -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params "${X265Q}:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" "$OUT/hlg.mov"
# Flat bright HLG grey (signal ~0.83, above reference white): the HDR-kept thumbnail must be tone-mapped to match.
ff -f lavfi -i "color=c=0xE0E0E0:s=1080x1920:r=30:d=2" -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params "${X265Q}:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" "$OUT/hlgbright.mov"
# Neutral HLG ramp: 12 vertical bands 90 px wide, band k at HLG signal k/12 (10-bit Y' 64 + 73k), lossless, so the
# SDR conversion of neutral tones can be checked band by band against v1's ffmpeg chain.
ff -f lavfi -i "nullsrc=s=1080x1920:r=30:d=2,format=yuv420p10le,geq=lum='64+73*floor(X/90)':cb=512:cr=512" \
  -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc \
  -x265-params "${X265Q}:lossless=1:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" "$OUT/hlgramp.mov"
# The same ramp in PQ (band k at PQ signal k/12).
ff -f lavfi -i "nullsrc=s=1080x1920:r=30:d=2,format=yuv420p10le,geq=lum='64+73*floor(X/90)':cb=512:cr=512" \
  -c:v libx265 -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "${X265Q}:lossless=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" "$OUT/pqramp.mov"

ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=3" -c:v libx264 -preset ultrafast "$OUT/noaudio.mp4"

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=4" -vf "select='lt(t\,2)+not(mod(n\,3))'" \
  -fps_mode vfr -c:v libx264 -preset ultrafast "$OUT/vfr.mp4"

ff -f lavfi -i "testsrc=s=1079x1917:r=30:d=1" -pix_fmt yuv444p -c:v libx264 -preset ultrafast "$OUT/odd.mp4"

ff -f lavfi -i "testsrc2=s=320x568:r=30:d=181" -f lavfi -i "sine=f=440:d=181" \
  -c:v libx264 -preset ultrafast -g 30 -c:a aac -shortest "$OUT/over3.mp4"

mkdir -p "$OUT/spaced é"
cp "$OUT/noaudio.mp4" "$OUT/spaced é/clip é 1.mov"

ff -f lavfi -i "testsrc2=s=1920x1080:r=60:d=3" -f lavfi -i "sine=f=440:d=3" \
  -c:v libx264 -preset ultrafast -c:a aac -shortest "$OUT/sixty.mp4"

ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=3" -f lavfi -i "sine=f=440:d=3:r=44100" \
  -c:v libx264 -preset ultrafast -c:a aac -ac 1 -ar 44100 -shortest "$OUT/mono44k.mov"

ff -f lavfi -i "testsrc2=s=1280x720:r=30:d=3" -f lavfi -i "sine=f=440:d=3" \
  -c:v libx264 -preset ultrafast -c:a aac -shortest "$OUT/sample.mkv"

ff -f lavfi -i "testsrc2=s=640x360:r=30:d=3" -f lavfi -i "sine=f=440:d=3" \
  -c:v mpeg4 -c:a libmp3lame -shortest "$OUT/sample.avi"

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=1" -c:v libtheora "$OUT/theora.mkv"

ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=6" -c:v libx264 -preset ultrafast \
  -g 30 -keyint_min 30 -sc_threshold 0 "$OUT/keyframes.mp4"

ff -f lavfi -i "testsrc2=s=320x240:r=30:d=0.4" -c:v libx264 -preset ultrafast "$OUT/tiny.mp4"

# Flat grey clips at clearly different luma, for crossfade blend checks.
ff -f lavfi -i "color=c=0x303030:s=1080x1920:r=30:d=3" -pix_fmt yuv420p -c:v libx264 -preset ultrafast "$OUT/dark.mp4"
ff -f lavfi -i "color=c=0xC0C0C0:s=1080x1920:r=30:d=3" -pix_fmt yuv420p -c:v libx264 -preset ultrafast "$OUT/bright.mp4"
# Flat bright grey at 60 fps with a tone: a 60 fps crossfade target whose luma clearly differs from testsrc2's.
ff -f lavfi -i "color=c=0xC0C0C0:s=1920x1080:r=60:d=3" -f lavfi -i "sine=f=440:d=3" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -c:a aac -shortest "$OUT/bright60.mp4"

# Moving grain over testsrc2: content that needs the full export bitrate (flat testsrc2 undershoots it).
ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=6,noise=alls=12:allf=t+u" -f lavfi -i "sine=f=440:d=6" -pix_fmt yuv420p \
  -c:v libx264 -preset ultrafast -crf 26 -c:a aac -shortest "$OUT/grain.mp4"

# A 660 Hz tone, to tell apart from the 440 Hz fixtures in crossfade audio checks.
ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=3" -f lavfi -i "sine=f=660:d=3:r=48000" \
  -c:v libx264 -preset ultrafast -c:a aac -ac 2 -ar 48000 -shortest "$OUT/tone660.mov"

# Audio shorter than the video (2.5 s of 3 s), and audio that starts late (0.5 s in, to 3 s).
ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=3" -f lavfi -i "sine=f=440:d=2.5:r=48000" \
  -c:v libx264 -preset ultrafast -c:a aac -ac 2 -ar 48000 "$OUT/shortaudio.mp4"
ff -f lavfi -i "testsrc2=s=1080x1920:r=30:d=3" -itsoffset 0.5 -f lavfi -i "sine=f=440:d=2.5:r=48000" \
  -c:v libx264 -preset ultrafast -c:a aac -ac 2 -ar 48000 "$OUT/lateaudio.mp4"

# portrait_hevc.mov is not faststart (moov at the end), so its first 64 KB has no moov.
head -c 65536 "$OUT/portrait_hevc.mov" > "$OUT/corrupt.mov"

print "trimlab2 fixture: not a video\n" > "$OUT/notes.txt"
ff -f lavfi -i "testsrc2=s=640x360:d=1" -frames:v 1 "$OUT/still.jpg"

# ---- assertions ---------------------------------------------------------------------------
fail=0
bad() { print -u2 "FIXTURE MISMATCH: $*"; fail=1; }

# expect <file> <stream selector> <key=value,key=value,...>   (order-independent)
expect() {
  local f="$OUT/$1" sel="$2" pair got
  got="$("$FFPROBE" -v error -select_streams "$sel" -show_entries stream -of default=nw=1 "$f")"
  for pair in ${(s:,:)3}; do
    print -r -- "$got" | grep -qx -- "$pair" || bad "$1 [$sel] want $pair; probed: $(print -r -- "$got" | grep -E "^${pair%%=*}=" | head -1)"
  done
}
# expect_dur <file> <min> <max>  (container duration, seconds)
expect_dur() {
  local d
  d="$("$FFPROBE" -v error -show_entries format=duration -of csv=p=0 "$OUT/$1")"
  awk -v d="$d" -v lo="$2" -v hi="$3" 'BEGIN{exit !(d>=lo && d<=hi)}' || bad "$1 duration $d not in [$2,$3]"
}
expect portrait_hevc.mov v:0 "codec_name=hevc,codec_tag_string=hvc1,width=1080,height=1920,avg_frame_rate=30000/1001"
expect portrait_hevc.mov a:0 "codec_name=aac"
expect_dur portrait_hevc.mov 4.9 5.2

expect rotated.mov v:0 "codec_name=h264,width=1920,height=1080,r_frame_rate=30/1"
rot="$("$FFPROBE" -v error -select_streams v:0 -show_entries stream_side_data=rotation -of csv=p=0 "$OUT/rotated.mov" | head -1)"
[[ "${rot%.*}" == "90" || "${rot%.*}" == "-90" ]] || bad "rotated.mov rotation: got '$rot'"
expect_dur rotated.mov 2.9 3.2

expect landscape.mp4 v:0 "codec_name=h264,width=3840,height=2160,r_frame_rate=30/1"
expect landscape.mp4 a:0 "codec_name=aac"
expect_dur landscape.mp4 4.9 5.2

expect hlg.mov v:0 "codec_name=hevc,pix_fmt=yuv420p10le,width=1080,height=1920,color_space=bt2020nc,color_transfer=arib-std-b67,color_primaries=bt2020,r_frame_rate=30/1"
expect_dur hlg.mov 2.9 3.2
expect hlgbright.mov v:0 "codec_name=hevc,pix_fmt=yuv420p10le,width=1080,height=1920,color_transfer=arib-std-b67,r_frame_rate=30/1"
expect hlgramp.mov v:0 "codec_name=hevc,pix_fmt=yuv420p10le,width=1080,height=1920,color_space=bt2020nc,color_transfer=arib-std-b67,color_primaries=bt2020,r_frame_rate=30/1"
expect_dur hlgramp.mov 1.9 2.2
# Each band's 10-bit Y' at its centre column, row 960 of the first frame.
ramp="$("$FFMPEG" -v error -i "$OUT/hlgramp.mov" -frames:v 1 -vf "extractplanes=y,crop=1080:1:0:960" -pix_fmt gray10le \
  -f rawvideo - | od -An -v -tu2 | tr -s ' ' '\n' | grep . | awk 'NR % 90 == 46 {printf "%d ", $1}')"
[[ "$ramp" == "64 137 210 283 356 429 502 575 648 721 794 867 " ]] || bad "hlgramp.mov band Y': got '$ramp'"
expect pqramp.mov v:0 "codec_name=hevc,pix_fmt=yuv420p10le,width=1080,height=1920,color_space=bt2020nc,color_transfer=smpte2084,color_primaries=bt2020,r_frame_rate=30/1"
expect_dur pqramp.mov 1.9 2.2
pqr="$("$FFMPEG" -v error -i "$OUT/pqramp.mov" -frames:v 1 -vf "extractplanes=y,crop=1080:1:0:960" -pix_fmt gray10le \
  -f rawvideo - | od -An -v -tu2 | tr -s ' ' '\n' | grep . | awk 'NR % 90 == 46 {printf "%d ", $1}')"
[[ "$pqr" == "$ramp" ]] || bad "pqramp.mov band Y': got '$pqr'"

expect noaudio.mp4 v:0 "codec_name=h264,width=1080,height=1920,r_frame_rate=30/1"
expect_dur noaudio.mp4 2.9 3.2
[[ -z "$("$FFPROBE" -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 "$OUT/noaudio.mp4")" ]] || bad "noaudio.mp4 has audio"

expect odd.mp4 v:0 "codec_name=h264,pix_fmt=yuv444p,width=1079,height=1917,r_frame_rate=30/1"
expect_dur odd.mp4 0.9 1.2
expect over3.mp4 v:0 "codec_name=h264,width=320,height=568,r_frame_rate=30/1"
expect_dur over3.mp4 180.9 181.3

cmp -s "$OUT/noaudio.mp4" "$OUT/spaced é/clip é 1.mov" || bad "spaced clip differs from noaudio.mp4"

expect sixty.mp4 v:0 "codec_name=h264,width=1920,height=1080,r_frame_rate=60/1"
expect sixty.mp4 a:0 "codec_name=aac"
expect_dur sixty.mp4 2.9 3.2

expect mono44k.mov v:0 "width=1080,height=1920"
expect mono44k.mov a:0 "codec_name=aac,sample_rate=44100,channels=1"
expect_dur mono44k.mov 2.9 3.2

expect sample.mkv v:0 "codec_name=h264,width=1280,height=720"
expect sample.mkv a:0 "codec_name=aac"
expect_dur sample.mkv 2.9 3.2
expect sample.avi v:0 "codec_name=mpeg4,width=640,height=360"
expect sample.avi a:0 "codec_name=mp3"
expect theora.mkv v:0 "codec_name=theora,width=320,height=240"
expect_dur theora.mkv 0.9 1.2
expect keyframes.mp4 v:0 "width=1080,height=1920,r_frame_rate=30/1"
expect_dur keyframes.mp4 5.9 6.2
expect tiny.mp4 v:0 "codec_name=h264,r_frame_rate=30/1"
expect_dur tiny.mp4 0.35 0.5
expect still.jpg v:0 "codec_name=mjpeg,width=640,height=360"

expect dark.mp4 v:0 "codec_name=h264,pix_fmt=yuv420p,width=1080,height=1920,r_frame_rate=30/1"
expect_dur dark.mp4 2.9 3.2
expect bright.mp4 v:0 "codec_name=h264,pix_fmt=yuv420p,width=1080,height=1920,r_frame_rate=30/1"
expect_dur bright.mp4 2.9 3.2
expect bright60.mp4 v:0 "codec_name=h264,pix_fmt=yuv420p,width=1920,height=1080,r_frame_rate=60/1"
expect bright60.mp4 a:0 "codec_name=aac"
expect_dur bright60.mp4 2.9 3.2
expect grain.mp4 v:0 "codec_name=h264,pix_fmt=yuv420p,width=1080,height=1920,r_frame_rate=30/1"
expect grain.mp4 a:0 "codec_name=aac"
expect_dur grain.mp4 5.9 6.2
expect tone660.mov v:0 "codec_name=h264,width=1080,height=1920,r_frame_rate=30/1"
expect tone660.mov a:0 "codec_name=aac,sample_rate=48000,channels=2"
expect_dur tone660.mov 2.9 3.2
expect shortaudio.mp4 v:0 "codec_name=h264,width=1080,height=1920,r_frame_rate=30/1"
expect shortaudio.mp4 a:0 "codec_name=aac,sample_rate=48000,channels=2"
expect lateaudio.mp4 a:0 "codec_name=aac,sample_rate=48000,channels=2"
# expect_stream_dur <file> <stream> <min> <max>  (seconds; start_time + duration for the late-start case)
expect_stream_dur() {
  local d
  d="$("$FFPROBE" -v error -select_streams "$2" -show_entries stream=duration -of csv=p=0 "$OUT/$1")"
  awk -v d="$d" -v lo="$3" -v hi="$4" 'BEGIN{exit !(d>=lo && d<=hi)}' || bad "$1 [$2] duration $d not in [$3,$4]"
}
expect_stream_dur shortaudio.mp4 v:0 2.9 3.1
expect_stream_dur shortaudio.mp4 a:0 2.4 2.6
expect_stream_dur lateaudio.mp4 v:0 2.9 3.1
la="$("$FFPROBE" -v error -select_streams a:0 -show_entries stream=start_time -of csv=p=0 "$OUT/lateaudio.mp4")"
awk -v s="$la" 'BEGIN{exit !(s>=0.45 && s<=0.6)}' || bad "lateaudio.mp4 audio start_time $la not ~0.5"
# expect_yavg <file> <min> <max>  (signalstats YAVG of the first frame, 8-bit code values)
expect_yavg() {
  local y
  y="$("$FFPROBE" -v error -f lavfi -i "movie='$OUT/$1',signalstats" -read_intervals "%+#1" \
    -show_entries frame_tags=lavfi.signalstats.YAVG -of csv=p=0 | head -1)"
  awk -v y="$y" -v lo="$2" -v hi="$3" 'BEGIN{exit !(y>=lo && y<=hi)}' || bad "$1 YAVG '$y' not in [$2,$3]"
}
expect_yavg dark.mp4 50 64
expect_yavg bright.mp4 174 188
expect_yavg bright60.mp4 174 188

# keyframes land exactly at 0..5 s
kf="$("$FFPROBE" -v error -select_streams v:0 -show_entries frame=pts_time,key_frame -of csv=p=0 "$OUT/keyframes.mp4" \
  | awk -F, '$1==1 {printf "%d ", $2+0.5}')"
[[ "$kf" == "0 1 2 3 4 5 " ]] || bad "keyframes.mp4 keyframes: got '$kf'"

# vfr: 30 fps for the first 2 s, then every third frame (10 fps)
vfr="$("$FFPROBE" -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$OUT/vfr.mp4" \
  | awk -F, 'NR>1 && $1>2.05 {d=$1-p; if (d<0.09||d>0.11) bad++} {p=$1} END{print bad+0}')"
expect_dur vfr.mp4 3.2 4.1
vfr_tail="$("$FFPROBE" -v error -select_streams v:0 -show_entries frame=pts_time -of csv=p=0 "$OUT/vfr.mp4" | awk -F, '$1>2.05' | wc -l)"
(( vfr_tail >= 5 )) || bad "vfr.mp4: only $vfr_tail tail frames"
[[ "$vfr" == "0" ]] || bad "vfr.mp4: $vfr tail frame deltas are not 0.1 s"

# corrupt.mov: truncated at 64 KB, no moov in that prefix, and the source's moov is at the end
[[ "$(stat -f %z "$OUT/corrupt.mov")" == "65536" ]] || bad "corrupt.mov size"
if LC_ALL=C grep -q moov "$OUT/corrupt.mov"; then bad "corrupt.mov prefix contains moov (source is faststart)"; fi
LC_ALL=C grep -q moov "$OUT/portrait_hevc.mov" || bad "portrait_hevc.mov has no moov"
[[ "$(stat -f %z "$OUT/portrait_hevc.mov")" -gt 65536 ]] || bad "portrait_hevc.mov under 64 KB"
if "$FFPROBE" -v quiet -show_entries format=duration -of csv=p=0 "$OUT/corrupt.mov" >/dev/null 2>&1; then
  bad "corrupt.mov is probeable; expected unreadable"
fi

if (( fail )); then
  rm -f "$OUT/.recipe-sha"
  exit 1
fi
print -n "$SHA" > "$OUT/.recipe-sha"
