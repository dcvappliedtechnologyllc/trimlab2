#!/bin/zsh
# Fetch the bundled TTFs into Resources/Fonts/ and pin them by SHA-256 (SPEC §2).
#   Inter 4.1            github.com/rsms/inter release zip (static TTFs + LICENSE.txt)
#   Bodoni Moda variable github.com/google/fonts at a pinned commit (+ OFL.txt)
# First run writes SHA256SUMS. Every later run re-downloads and FAILS if any hash differs.
set -euo pipefail

INTER_VERSION="4.1"
INTER_URL="https://github.com/rsms/inter/releases/download/v${INTER_VERSION}/Inter-${INTER_VERSION}.zip"
GF_COMMIT="6ce172f74aa355ea43eb964fa4a91570a4d3064d"
GF_RAW="https://raw.githubusercontent.com/google/fonts/${GF_COMMIT}/ofl/bodonimoda"

ROOT="${0:A:h:h}"
OUT="$ROOT/Resources/Fonts"
mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "$INTER_URL" -o "$WORK/inter.zip"
unzip -q "$WORK/inter.zip" -d "$WORK/inter"
for w in Regular Medium SemiBold Bold; do
  cp "$WORK/inter/extras/ttf/Inter-$w.ttf" "$WORK/Inter-$w.ttf"
done
cp "$WORK/inter/LICENSE.txt" "$WORK/OFL-Inter.txt"

curl -fsSL "$GF_RAW/BodoniModa%5Bopsz%2Cwght%5D.ttf" -o "$WORK/BodoniModa[opsz,wght].ttf"
curl -fsSL "$GF_RAW/BodoniModa-Italic%5Bopsz%2Cwght%5D.ttf" -o "$WORK/BodoniModa-Italic[opsz,wght].ttf"
curl -fsSL "$GF_RAW/OFL.txt" -o "$WORK/OFL-BodoniModa.txt"

FILES=(Inter-Regular.ttf Inter-Medium.ttf Inter-SemiBold.ttf Inter-Bold.ttf
       'BodoniModa[opsz,wght].ttf' 'BodoniModa-Italic[opsz,wght].ttf'
       OFL-Inter.txt OFL-BodoniModa.txt)

( cd "$WORK" && shasum -a 256 "${FILES[@]}" > SHA256SUMS.new )

if [[ -f "$OUT/SHA256SUMS" ]]; then
  if ! diff -q "$OUT/SHA256SUMS" "$WORK/SHA256SUMS.new" >/dev/null; then
    echo "PINNED HASH MISMATCH; refusing to overwrite Resources/Fonts:" >&2
    diff "$OUT/SHA256SUMS" "$WORK/SHA256SUMS.new" >&2 || true
    exit 1
  fi
  # The downloads match the pin; the committed files must too (catches a deleted or edited TTF).
  ( cd "$OUT" && shasum -a 256 -c SHA256SUMS --quiet ) || { echo "committed Resources/Fonts differ from SHA256SUMS" >&2; exit 1; }
  echo "fonts match the pinned SHA256SUMS"
else
  for f in "${FILES[@]}"; do cp "$WORK/$f" "$OUT/$f"; done
  cp "$WORK/SHA256SUMS.new" "$OUT/SHA256SUMS"
  echo "wrote ${#FILES} files and SHA256SUMS to $OUT"
fi
