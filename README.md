# trimlab 2

A native Mac app for cutting multi-clip Instagram Reels. Drop a shoot folder on the window, trim each clip,
reorder, split, add cuts or soft crossfades, keep an eye on Instagram's 3:00 limit, and export a 1080x1920 Reel.
It is SwiftUI and AVFoundation end to end: one gapless preview of the whole Reel, one Core Image compositor shared
by preview and export, and no ffmpeg in the export path. A DCV Applied Technology tool.

trimlab 2 is the rewrite of [trimlab](https://github.com/dcvappliedtechnologyllc/trimlab) (v1), which trims one
clip at a time. v2 keeps v1's look and key bindings and adds the Reel: many clips, one timeline. It installs next
to v1 (bundle id `com.dcv.trimlab2`, `trimlab2.app`, its own preferences, cache and logs).

## What it does

- Open clips by dropping files or a folder, File > Open (several at once), Finder Open With, or a Dock drop.
  Clips are ordered by capture date.
- Reel strip: thumbnails sized by trimmed length, select, drag to reorder, split at the playhead, delete,
  a cut or a short/long crossfade at each join, zoom, and a running total against 3:00.
- Trim deck for the selected clip, with In/Out handles and per-clip framing (Fill, or Fit over a blurred copy).
- Undo and redo across the whole Reel, and a key map overlay.
- The edit list autosaves as a `.trimlab` file next to the clips and reopens from Finder.
- Export sheet: Reel or Original, Exact or Quick, Standard or High quality, HDR to SDR, remove audio, name and
  folder, progress and cancel. The done view reveals the file in Finder, opens it in QuickTime, or AirDrops it.
- `.mkv` and `.avi` clips are remuxed to `.mov` with ffmpeg when it is installed (optional).

The specification, with the reasoning behind each choice, is in [SPEC.md](SPEC.md). Decisions made while building
are in [docs/rulings.md](docs/rulings.md).

## What you need

| | |
|---|---|
| Mac | Apple silicon (the build is arm64 only) |
| macOS | 26 or later |
| Xcode | 26.4 or later (Swift 6 language mode, strict concurrency) |
| XcodeGen | `brew install xcodegen` (the Xcode project is generated from `project.yml`) |
| ffmpeg | optional at runtime, for `.mkv`/`.avi` import; required to generate the test fixtures. `brew install ffmpeg-full` (the app looks in `/opt/homebrew/opt/ffmpeg-full/bin`, `/opt/homebrew/bin` and `/usr/local/bin`) |

## Build

```bash
./App/build.sh
```

This runs `xcodegen generate`, builds the Release configuration with `xcodebuild`, and copies the result to
`dist/trimlab2.app`. Quit a running copy first; the script refuses otherwise.

Signing: if a code-signing identity named `trimlab dev` exists in your login keychain the app is signed with it,
otherwise it is signed ad hoc and still runs. An ad hoc signature changes with every build, so macOS asks again
for folder access after each rebuild. To avoid that, run `./App/make-signing-identity.sh` once; it creates a
self-signed certificate in your login keychain (nothing leaves the machine). The app is not notarized.

## Run

```bash
open dist/trimlab2.app
```

Then drag a folder of clips onto the window. Logs go to `~/Library/Logs/trimlab 2/trimlab.log`.

## Test

Generate the media fixtures once (needs `ffmpeg-full`), then run the two schemes:

```bash
scripts/make-fixtures.sh
xcodegen generate
xcodebuild test -project trimlab.xcodeproj -scheme TrimlabKit -destination 'platform=macOS' -derivedDataPath build
xcodebuild test -project trimlab.xcodeproj -scheme trimlab -destination 'platform=macOS' -derivedDataPath build
```

The `trimlab` scheme runs a UI smoke test, which needs permission to control the app. A longer by-hand
checklist for a built app is in [docs/bench-checklist.md](docs/bench-checklist.md).

## Layout

```
App/                      macOS app target: the only place AppKit is imported; build.sh, Info.plist
Packages/TrimlabKit/      local Swift package, no AppKit or UIKit
  Sources/TrimlabModel/     edit list, rational time, planner, project file codec, key map
  Sources/TrimlabMedia/     composition, compositor, preview, export, importer, HDR to SDR LUTs
  Sources/TrimlabEditor/    EditorModel, views and the design system (tokens, controls)
  Tests/                    Swift Testing suites for each target
Resources/                Bundled fonts (Inter, Bodoni Moda; SIL OFL) and the logo
assets/                   Brand CSS, icon, web fonts used by the design mockup
design/                   HTML mockup the native UI was matched against
docs/                     Rulings, screen captures, design addendum and build plan
scripts/                  Fixture generation, HDR LUT generation, font fetch, mockup tooling
UITests/                  UI smoke test; UITests-Bench/ holds the slower bench tests
project.yml               XcodeGen project definition
SPEC.md                   Full specification
```

## Licence

MIT. Copyright (c) 2026 DCV Applied Technology. See [LICENSE](LICENSE). The bundled fonts keep their own
SIL Open Font Licence texts (`Resources/Fonts/OFL-*.txt`).
