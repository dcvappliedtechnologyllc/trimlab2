#!/bin/zsh
# Build trimlab 2: dist/trimlab2.app, signed with the "trimlab dev" identity when present, ad-hoc otherwise.
#   ./App/build.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# 1. refuse while the app is running (the build replaces dist/trimlab2.app)
if pgrep -f "$REPO/dist/trimlab2.app/Contents/MacOS/trimlab2" >/dev/null; then
  echo "trimlab2.app is running; quit it first (the build replaces dist/trimlab2.app)"; exit 1
fi

# 2. signing identity
IDENTITY="trimlab dev"
out=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [[ $out == *"\"$IDENTITY\""* ]]; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "No \"$IDENTITY\" identity found: signing ad-hoc (privacy grants will be asked again after every build)."
  echo "One-time fix: run ./App/make-signing-identity.sh, then build again."
fi

# 3. generate, build, copy, verify. Apple silicon only (docs/rulings.md): ARCHS on the command line reaches the
# TrimlabKit package targets too, which ignore project.yml's ARCHS and would otherwise also build x86_64, where
# Float16 doesn't exist.
xcodegen generate
xcodebuild -project trimlab.xcodeproj -scheme trimlab -configuration Release -derivedDataPath build ARCHS=arm64 \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN" DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO build

BUILT="build/Build/Products/Release/trimlab2.app"
[[ -d "$BUILT" ]] || { echo "build failed: $BUILT missing"; exit 1; }
mkdir -p dist
rm -rf dist/trimlab2.app
ditto "$BUILT" dist/trimlab2.app
codesign -vv dist/trimlab2.app
echo "built dist/trimlab2.app (signed: $SIGN)"
