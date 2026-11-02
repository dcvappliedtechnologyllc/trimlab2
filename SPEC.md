# trimlab 2: multi-clip Reels, native

Handoff spec for trimlab 2, a native SwiftUI + AVFoundation rewrite of trimlab. It keeps everything v1
does (one clip in, trimmed Reel out) and adds **multi-clip Reels**: drop a folder's worth of clips, put them
in order, trim each one on the v1 gold-bracket deck, and export one gapless Reel. CapCut stays for text,
music and effects until v3–v5 (§1.3).

Status: direction approved by the owner 2026-10-28; spec awaits the owner's review. Open questions: §13. Build order: §12.
Owner: DCV Applied Technology, LLC. Sibling of camlab and trimlab v1: same brand and process.

Authorities, in order: this file; `../trimlab/SPEC.md` (v1) for anything about brand and feel that this file
doesn't restate; `../trimlab/docs/superpowers/specs/2026-10-27-trimlab-ui-design.md` (the v1 UI plan,
whose tokens and component specs carry over unchanged); `../trimlab/docs/rulings.md` (v1 rulings, the
ones carried forward are listed in §4.12).

---

## 0. How to build this (skills and process, required)

The builder is a Claude Code coordinating session that sends the work to subagents, as in v1. These steps
are part of the spec.

| Step | Skill | What it means here |
|---|---|---|
| Start | `superpowers:using-superpowers` | Load first. |
| Design | `superpowers:brainstorming` | This SPEC.md **is** the approved brainstorm. Don't re-run discovery. Raise §13 once, all together, then proceed on the stated defaults if unanswered. A copy lives at `docs/superpowers/specs/2026-10-28-trimlab2-design.md`. |
| Isolation | `superpowers:using-git-worktrees` | `git init trimlab2/`, then work on `feat/v2`. **Precondition:** the owner has run `sudo xcodebuild -license accept` themselves, because git and xcodebuild are both blocked until he does. The builder never runs `sudo`. |
| Plan | `superpowers:writing-plans` | Turn §12 into `docs/superpowers/plans/2026-10-28-trimlab2.md`: small tasks, each with files, tests and a done-check. |
| Execute | `superpowers:subagent-driven-development` | One subagent per task, reviewed between tasks. The coordinator keeps `docs/rulings.md` (v1 format: ruling, reason, cost if wrong). UI tasks that have to match the mockup go to Opus; the rest go to Sonnet (v1 ruling). |
| Code | `superpowers:test-driven-development` | Mandatory for `TrimlabModel` (edit list, history, planner, project codec, key map) and `TrimlabMedia` (composition builder, compositor, export, quick cut). Write the test first and watch it fail. |
| UI | `frontend-design:frontend-design` | Load before the mockup and before any SwiftUI view. §6 pins the direction. |
| Bugs | `superpowers:systematic-debugging` | For any playback, compositor or export defect. |
| Review | `superpowers:requesting-code-review` | At the end of every phase in §12. |
| Done | `superpowers:verification-before-completion` | Nobody claims "done" until the §11 checks have run and their output is shown. |
| Finish | `superpowers:finishing-a-development-branch` | Merge, rebuild the `.app`, launch it once. |

Tooling: Xcode 26.4 (selected), macOS 26 SDK, Swift 6 language mode with strict concurrency. Builds use
`xcodebuild` only. The Xcode project is generated from `project.yml` by **XcodeGen** (`brew install
xcodegen`). Agents edit YAML reliably; hand-edited `.pbxproj` files are where agent builds go wrong. The
generated `trimlab.xcodeproj` is git-ignored. Tests use **Swift Testing**, plus XCTest for one XCUITest smoke
target. Any other tool comes from Homebrew. Camlab and trimlab v1 are read-only: never modify them.

---

## 1. The job

### 1.1 Why v2

Reels are now sequences: 15+ short clips from one shoot (Spa Tour is typical), hard cuts, sometimes a
soft crossfade. v1 trims one clip at a time, so the Reel is still assembled in CapCut; v2 does the assembly.
**Target:** shoot folder in, ordered, trimmed, exported Reel out in a few minutes of human time; the one-clip
path stays under 30 seconds.

### 1.2 In scope (v2)

1. Open clips by dragging many files or a folder onto the window, ⌘O (multiple), Finder Open With or Dock drop;
   `.mkv`/`.avi` remux through optional Homebrew ffmpeg.
2. **Reel strip:** thumbnails sized by trimmed length; select, drag to reorder, insert by drop position, delete,
   split at the playhead, cut/crossfade per join, zoom; the total against Instagram's 3:00 always visible.
3. **Trim deck:** the selected clip on v1's gold-bracket deck, unchanged in feel.
4. **Preview:** the whole Reel gaplessly from one AVComposition.
5. Per-clip framing (Fill / Fit); Reel-wide remove audio.
6. Export sheet (Reel / Original, Exact / Quick §5.7, Standard / High, HDR→SDR, name, folder, progress,
   cancel) and done view (Reveal in Finder, Open in QuickTime, AirDrop, **New Reel**).
7. The edit list autosaves as a `.trimlab` file next to the clips and reopens from Finder; undo/redo across
   the whole Reel.
8. Everything else of v1: prefs, logs, remembered window, key map overlay, reduced motion, focus rings, narrow
   layout, the brand.

A one-clip Reel is v1: same screens, same behaviour, no project file (§8.2).

### 1.3 Non-goals, with the hooks v2 leaves for them

v2 must not block these. Each one plugs into a named seam without a schema break or a rewrite.

| Later | What | Hook in v2 |
|---|---|---|
| v3 | Music bed with auto-ducking, plus Instagram loudness (about −14 LUFS integrated) | Schema 2 adds an optional `Reel.music`. `CompositionPlan.audioRamps` is already a list of per-track gain ramps, so a music track and its duck ramps are just more entries. Export runs audio through an `AudioStage` protocol that is the identity in v2; a loudness stage measures and applies gain there. Peaks (§4.6) already give the clip-audio envelope that ducking keys off. |
| v4 | On-device captions via Apple Speech (`SpeechTranscriber`; the spike confirmed en-US is installed) | Schema adds `ReelClip.captions` in **source time**, so they move with reorder and trim. The compositor has an ordered **overlay stage** after layer compositing, empty in v2, where caption rendering goes. Info.plist gains `NSSpeechRecognitionUsageDescription` then, not now. |
| v5 | A few brand looks (Core Image), with preview matching export | Every layer passes through a `LayerSpec.effects` chain inside `ReelCompositor` (§5.2), empty in v2 (framing is applied before it). A look is one more effect (`CIColorCube` LUT). Preview and export already share the one compositor, so they match by construction. |
| Later | iPhone / iPad app | `TrimlabModel`, `TrimlabMedia` and `TrimlabEditor` import no AppKit (§3.1, enforced by a test). An iOS app target supplies its own `PlatformServices` and player surface. **Not built in v2.** |

Also out: text and titles, speed changes, manual crop positioning, keyframed motion, multiple video layers
(picture-in-picture), uploading to Instagram, iCloud sync, more than one window.

---

## 2. Stack

| Layer | Choice | Why |
|---|---|---|
| App | SwiftUI app lifecycle, macOS 26, one window, `.windowStyle(.hiddenTitleBar)` with full-size content | Native, and lets the v1 header be the drag region over the traffic lights. |
| Shared code | Local Swift package `TrimlabKit` with three library targets (§3.1) | Model, media and editor views compile for iOS later. AppKit lives only in the app target. |
| Playback | `AVPlayer` + `AVPlayerItem(asset: AVMutableComposition)` with a custom compositor, drawn by an `AVPlayerLayer` in a plain view (never `AVPlayerView`, which brings default controls) | Spike: gapless at all 17 joins, and a re-trim rebuild lands a seek in 25 ms. |
| Compositing | `ReelCompositor: AVVideoCompositing` rendering with Core Image on Metal | Fit (blurred background) has no layer-instruction equivalent (spike gap 5), and v5 looks need it anyway. One compositor serves preview and export. |
| Export | `AVAssetReader` (composition video output + audio mix output) into `AVAssetWriter` | Spike: exact duration, 13.9 of 14 Mb/s, 6.5× real time. `AVAssetExportSession` can't set bitrate or profile (spike gap 2). It is used only for Quick passthrough. |
| Thumbnails / waveform | `AVAssetImageGenerator.images(for:)`; `AVAssetReader` PCM into 20 ms max-abs peaks | Spike: 40 frames in about 1 s from 4K HEVC; peaks in about 90 ms. |
| ffmpeg | **Only** for (a) remuxing `.mkv`/`.avi` to `.mov` in the cache (`-c copy`), and (b) `ffprobe` as the test oracle. Homebrew `ffmpeg-full` is optional at runtime. Nothing in the export path uses it. | Spike: AVFoundation can't open mkv/avi. A 363 MB remux takes 0.75 s. |
| Persistence | `.trimlab` JSON project files (§8); prefs in `UserDefaults` (`com.dcv.trimlab2`), validated on read | Prefs are per-app. The edit list belongs next to the footage. |
| Logs | `os.Logger` (subsystem `com.dcv.trimlab2`) plus a file sink at `~/Library/Logs/trimlab 2/trimlab.log` (1 MB × 3, rotating) | The owner can read the file. Each export logs its spec, plan summary and settings, and each remux logs its argv. |
| Packaging | `App/build.sh`: `xcodegen generate` → `xcodebuild -scheme trimlab -configuration Release` → `dist/trimlab2.app` (shown as "trimlab 2"), signed with the self-signed **"trimlab dev"** identity | See §8.4. |
| Fonts | Inter 400/500/600/700 and Bodoni Moda 400 italic / 500 / 500 italic as **TTF**, in `Resources/Fonts`, registered through `ATSApplicationFontsPath` | CoreText can't register the v1 woff2 files. The TTFs come from the same OFL releases, are fetched once at build-prep, and are pinned by SHA256. The woff2 files in `assets/fonts/` stay for the HTML mockup only. |

Reuse by copy: `trimlab2/assets/brand.css` (tokens), `dcv-logo-white.svg` (converted to a PDF vector asset),
`trimlab.icns` (icon A), and the v1 mockup's CSS for the design gate. Never import across projects.

Sandbox: **off**. trimlab writes `.trimlab` files next to clips in any folder, runs Homebrew ffmpeg and is
for local use only. Hardened runtime is off. No entitlements beyond the defaults.

---

## 3. Architecture

```
trimlab.app (macOS target: the only AppKit)
  TrimlabApp · AppDelegate (open files) · WindowChrome · KeyMonitor · PlayerSurface · MacPlatformServices
  (NSOpenPanel, NSWorkspace, AirDrop) · PrefsStore · FileLog          ── injects PlatformServices, PlayerSurface
     ▼
TrimlabEditor (SwiftUI + Observation)  EditorModel @MainActor owns Reel + History; views Header, Stage,
  Inspector, Transport, ReelStrip, TrimDeck, ExportSheet, Done, Error, KeyMap; Design/ (tokens, controls)
     ▼ asks for builds, frames, exports
TrimlabMedia (AVFoundation, Core Image)  Prober · Importer (ffmpeg remux) · MediaCache · CompositionBuilder ·
  ReelCompositor · ExportRunner · QuickCut · KeyframeIndex           ── consumes CompositionPlan
     ▼
TrimlabModel (Foundation only)  Reel · ReelClip · RationalTime · ReelEdit/apply · History · Planner ·
  ProjectCodec + Migrations · KeyMap · ModalStack · Naming · Prefs
```

### 3.1 Repo layout

```
trimlab2/
  SPEC.md   project.yml   README.md
  App/build.sh   App/make-signing-identity.sh   App/Info.plist
  App/                      # macOS target: the only place AppKit is imported
    TrimlabApp.swift  AppDelegate.swift  WindowChrome.swift  KeyMonitor.swift
    PlayerSurface.swift  MacPlatformServices.swift  PrefsStore.swift  FileLog.swift  Menus.swift
  Packages/TrimlabKit/Package.swift      # platforms: macOS 26, iOS 26
    Sources/TrimlabModel/   Sources/TrimlabMedia/   Sources/TrimlabEditor/{Design,Views,EditorModel.swift}
    Tests/ModelTests/   Tests/MediaTests/   Tests/EditorTests/
  Resources/Fonts/*.ttf   Resources/Assets/ (dcv-logo-white.pdf)   assets/ (brand.css, icns, woff2 for mockup)
  design/mockup.html  design/mockup-assets/      # the §6.5 design gate
  scripts/make-fixtures.sh   scripts/fetch-fonts.sh
  UITests/SmokeTests.swift
  docs/screens/   docs/rulings.md   docs/superpowers/{specs,plans}/
```

A test (`test_no_appkit_in_package`) scans `Packages/TrimlabKit/Sources` and fails on `import AppKit`,
`import UIKit`, `NSView`, `NSImage`, `NSColor` or `NSWorkspace`.

### 3.2 Core data types (`TrimlabModel`)

```swift
/// Exact rational time (gcd-normalised + − min max, frame snapping); no floats in the edit list.
/// JSON: [value, timescale]. Converted to CMTime only in TrimlabMedia.
public struct RationalTime: Codable, Hashable, Comparable, Sendable { public var value: Int64; public var timescale: Int32 }
public struct TimeSpan: Codable, Hashable, Sendable { public var start, duration: RationalTime }
public struct PixelSize: Codable, Hashable, Sendable { public var width, height: Int }
public enum Framing: String, Codable, Sendable { case fill, fit }       // fit = whole frame over a blurred copy
public enum Join: Codable, Hashable, Sendable { case cut, crossfade(RationalTime) }  // INTO a clip; v2 writes 0.25 s (Short) or 1 s (Long)
public enum HDRKind: String, Codable, Sendable { case sdr, hlg, pq }
public enum LayerEffect: Codable, Hashable, Sendable {}                // no cases in v2; v5 adds .look(id)

public struct SourceRef: Codable, Hashable, Sendable {
  public var relativePath: String?; public var absolutePath: String    // relative to the .trimlab folder, tried first
  public var size: Int64; public var modified: Date                    // change detection
}
public struct ClipFacts: Codable, Hashable, Sendable {                 // probe snapshot; a reopen draws at once
  public var duration, frameDuration: RationalTime                     // nominal, e.g. 1001/30000
  public var displayWidth, displayHeight, rotation: Int                // rotation applied; 0/90/180/270
  public var videoCodec: String; public var hasAudio: Bool; public var hdr: HDRKind
  public var bitrate: Int; public var captureDate: Date?; public var needsRemux: Bool   // .mkv / .avi
}
public struct ReelClip: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID; public var source: SourceRef; public var facts: ClipFacts
  public var inTime, outTime: RationalTime                             // source time, Out exclusive
  public var join: Join; public var framing: Framing                   // join ignored on the first clip
  public var extra: JSONObject                                         // unknown keys, kept and re-written
}
public struct ExportSpec: Codable, Hashable, Sendable {
  public enum Format: String, Codable { case reel, original }
  public enum Cut: String, Codable { case exact, quick }
  public enum Quality: String, Codable { case standard, high }
  public var format = Format.reel, cut = Cut.exact, quality = Quality.high
  public var convertHDR = true, removeAudio = false
  public var fileName: String?, folder: String?                        // nil = derive (§4.9)
  public var extra: JSONObject
}
public struct Reel: Codable, Hashable, Sendable {
  public static let currentSchema = 1
  public var schema = Reel.currentSchema; public var id: UUID; public var name: String
  public var clips: [ReelClip]; public var export: ExportSpec; public var extra: JSONObject
}
public struct Selection: Hashable, Sendable { public var primary: UUID?; public var all: Set<UUID> }
```

`JSONObject` is a small Codable `[String: JSONValue]`. Each type with `extra` decodes its known keys and keeps
every other key unchanged, so a build that opens a file of its own schema never drops fields it doesn't know.

### 3.3 Edits, history, plan

```swift
public enum ReelEdit: Sendable {
  case insert([ReelClip], at: Int), move(Set<UUID>, toGap: Int), delete(Set<UUID>), split(UUID, atSource: RationalTime)
  case setIn(UUID, RationalTime), setOut(UUID, RationalTime), resetIn(UUID), resetOut(UUID)
  case setJoin(UUID, Join), setFraming(Set<UUID>, Framing), setRemoveAudio(Bool), setExport(ExportSpec)
  case relink(UUID, SourceRef, ClipFacts), rename(String)
}
public enum EditError: Error, Equatable { case spanTooShort, crossesHandle, splitTooCloseToEdge, unknownClip, emptyInsert }
public func apply(_ e: ReelEdit, to r: Reel) throws(EditError) -> Reel           // pure

public struct History: Sendable {           // snapshots of (Reel, Selection); a Reel is a small value
  public static let limit = 200
  public mutating func record(_ before: Reel, _ sel: Selection, coalesce: String?)  // same key in one gesture merges
  public mutating func undo(current: (Reel, Selection)) -> (Reel, Selection)?
  public mutating func redo(current: (Reel, Selection)) -> (Reel, Selection)?
}
public struct Placement: Hashable, Sendable {
  public var clipID: UUID; public var index, track: Int                // track 0/1 alternates (A/B)
  public var reelSpan: TimeSpan; public var sourceIn, fadeIn: RationalTime   // fadeIn = effective crossfade, 0 for a cut
}
public struct LayerSpec: Hashable, Sendable {
  public var placement: Int; public var framing: Framing
  public var opacity: ClosedRange<Double>?                             // ramp across the segment, outgoing layer only
  public var effects: [LayerEffect]                                    // [] in v2
}
public struct PlanSegment: Hashable, Sendable { public var span: TimeSpan; public var layers: [LayerSpec] }  // top first
public struct AudioRamp: Hashable, Sendable { public var track: Int; public var span: TimeSpan; public var from, to: Double }
public struct CompositionPlan: Hashable, Sendable {
  public var placements: [Placement]; public var segments: [PlanSegment]   // cover [0, total), no gaps
  public var total, frameDuration: RationalTime; public var renderSize: PixelSize
  public var audioRamps: [AudioRamp]; public var hasAudioOut, hdrOut: Bool
}
public enum Planner { public static func plan(_ r: Reel) -> CompositionPlan }  // missing clips left out
```

---

## 4. Behaviour

### 4.1 Open and import

- Accepts `.mov .mp4 .m4v .mts .mkv .avi`, folders (top level only) and `.trimlab`. Anything else in a drop is
  skipped with one quiet note: "Skipped 2 files trimlab can't open."
- **Ways in:** drop on the window, ⌘O (Open panel, multiple selection, movies and `.trimlab`), Finder Open
  With, Dock drop. With no Reel open, clips start a new Reel. With one open, a drop on the strip inserts at the
  caret (§4.3.3) and every other way in appends; nothing is replaced and Undo takes it back. Opening a
  `.trimlab` replaces the open Reel, which is already saved, so there is no confirm.
- **Batch order:** capture date (QuickTime `creationDate`, then file creation date), then natural file name
  (`IMG_2` before `IMG_10`). Capture order follows the shoot; descriptive names don't (§13 decision 2).
- **Probing:** 4 files at a time. The tile appears at once with v1's shimmer; facts, poster, then sprite and
  peaks fill in, visible tiles first. Defaults: In 0, Out end, join cut, framing = the `defaultFraming` pref
  (Fill). The same file may be added twice; each copy is its own clip.
- **`.mkv` / `.avi`:** the tile says "Preparing…" while `Importer` remuxes into the cache. Without ffmpeg those
  files are refused and a card says "trimlab needs ffmpeg to open .mkv and .avi files. Install it with
  Homebrew:" with a copyable `brew install ffmpeg-full`, re-checked on window focus. Nothing else needs ffmpeg.
- **Unplayable** (`isPlayable == false`, no remux applies): "Can't open IMG_0001.MOV. trimlab can't play this
  kind of file."
- **During an export** (v1 ruling) adding clips, opening a project and New Reel are refused with "Finish or
  cancel the export first." and change nothing.

### 4.2 Preview and transport

- The stage plays the **composited Reel**, exactly what export writes, at the render size (§5.1), fitted with
  32 px padding. A Reel-format preview is already 9:16, so playback needs no frame guide.
- **Peek:** while the deck playhead is in a trimmed-away part (§4.4) or a handle is dragged, the stage shows
  that **source frame** from a per-clip scrub player, letterboxed, with v1's 9:16 gold guide (outside dimmed
  40 %) when the clip is Fill in a Reel. Meanwhile the Reel playhead parks on the clip's nearest kept frame.
- **One playhead in Reel time** drives stage, strip and (inside the selected clip) deck. Space plays from it;
  from peek, from the selected clip's In.
- **Loop Reel** (`\`, on by default) wraps end → 0:00; off, playback stops on the last frame. Reverse shuttle
  stops at 0:00 (v1 ruling). Remove audio (A) mutes the preview and drops waveforms to 20 %.
- Timecode `m:ss.ff` at the Reel frame rate, click toggles seconds (`12.40 s`); the transport shows
  `playhead / total`.
- **Selection follows the playhead only while paused.** During playback selection and deck stay put; when
  playback pauses or a click or step lands the playhead, the clip under it becomes selected, so I, O and S
  always act on the clip you see. In a crossfade overlap that is the incoming clip.

### 4.3 The Reel strip

#### 4.3.1 Geometry and drawing

- A full-width row under the transport, 80 px: 12 px cap row (playhead cap, 3:00 label), 56 px tiles, 12 px
  below. One SwiftUI `Canvas`, hit-tested in the model, so 30 clips cost one draw.
- **Tile width** = trimmed length × px/s, minimum 24 px so a 0.5 s clip can be grabbed, 2 px `--bg-1` gaps.
  The x↔time mapping is piecewise linear per tile, so a minimum-width tile never shifts time elsewhere.
- **Content:** frames from the clip's sprite, sampled across its **kept** span, tiled edge to edge at source
  aspect. No text on tiles (names live in the inspector and deck caption); VoiceOver reads "Clip 4 of 18,
  IMG_4821, 3.2 seconds".
- **States:** loading = v1 shimmer; selected = 1.5 px gold outline; also selected = 1 px `--muted` outline;
  missing = `--bg-2` with "Missing" in 12 px `--muted`; being dragged = 35 %.
- **Playhead:** 1 px ivory line with v1's 9×7 cap. **Crossfade:** the incoming tile overlaps the outgoing by the
  effective fade width, marked by a thin ivory `╳` at 70 %. A cut is just the gap.
- **Over 3:00:** a 1 px `--warn` line at 3:00 with "3:00" in 11 px `--warn` in the cap row; tiles past it get
  `--deck-out`. No marker under 3:00.

#### 4.3.2 Selection

Click selects a clip (primary) and puts the playhead at its In; ⇧-click extends a range, ⌘-click toggles, ⌘A
selects all, Esc collapses to the primary. ↑ / ↓ select the previous / next clip. The deck always shows the
**primary**. Delete, move and framing act on the whole selection; I, O, S and X on the primary only.

#### 4.3.3 Reorder and insert

- **Drag to reorder:** press a tile and move 4 px. The tile (or the selection, in relative order) stays at
  35 %; a ghost at 80 % follows the pointer; a 2 px gold **caret** marks the nearest gap. Neighbours don't
  slide; the caret is the only motion, so reduced motion needs no special case. When zoomed, the strip
  auto-scrolls within 32 px of an edge. Release moves; a drop where it started records nothing; Esc cancels.
- **Keyboard:** ⌥← / ⌥→ move the selection one place.
- **Finder drop:** the same caret over the strip (insert there); v1's armed hairline frame elsewhere (append).
- A moved clip keeps its own join. The first clip's join is ignored but kept, so moving it back restores it.

#### 4.3.4 Delete, split, join, framing

- **Delete** (⌫ / ⌦): no confirm, undoable. Selection moves to the next clip (the previous after the last).
  Deleting every clip shows the empty state; the project file stays (§8.2).
- **Split** (S): the primary clip at the playhead's source time becomes A = [In, t) and B = [t, Out) on the same
  source, a cut between them, B selected. Each half keeps ≥ 0.5 s, otherwise nothing changes and the note says
  "Too close to the clip's edge to split." **Cutting out a middle bit = split, split, delete**; no extra feature.
- **Join** (X, a click on the join in the strip, or the caption's "Crossfade in" control) sets the join into
  the primary clip: cut, Short crossfade (0.25 s) or Long crossfade (1 s). The caption shows a three-way
  segmented control Cut | Short | Long; X and clicks on the join cycle cut → Short → Long → cut. Effective
  length = `min(chosen, ½ × shorter neighbour's trimmed length)`, so it is always valid; the tooltip shows the
  effective value ("Crossfade, 1 s" or "Crossfade, 0.6 s (clip is short)"). Hidden on the first clip.
- **Framing** (F, or the caption's Fill | Fit): applies to the selection; shown when the primary clip isn't
  9:16 and the format is Reel. F sets the selection to the opposite of the primary's framing; no-op on 9:16.

#### 4.3.5 Zoom and scroll

Default **Fit** (whole Reel across the strip). Pinch or ⌘-scroll over the strip, the transport's "− Zoom +", or
⌥⌘= / ⌥⌘− / ⌥⌘0, from fit to 200 px/s. Zoomed, a two-finger swipe scrolls and playback pages to keep the
playhead in view (v1's follow-playhead). No system scrollbar.

#### 4.3.6 Totals and the 3:00 warning

The inspector's large number is the **Reel total** (Σ trims − Σ effective crossfades): `48.2 s`, or `2:14.6`
from one minute, with a muted `of 3:00` and the clip count ("18 clips") under it. Over 3:00 with Reel it turns
`--warn` and a line reads "Instagram Reels can be up to 3 minutes. Trim 0:12.4 more." (repeated in the export
sheet). Export isn't blocked; that is the owner's call each time.

### 4.4 Trim deck (v1's signature element, ported)

- Shows the **primary clip's whole source** in v1's exact geometry (cap 12, filmstrip 64, gap 2, waveform 44,
  side padding 20): bracket feet, tabs and grip line, `--deck-out` outside the span, gold span edges,
  `sqrt(peak)` waveform, ivory playhead with cap. The spike matched it pixel for pixel in a `Canvas`.
- Its playhead is the Reel playhead mapped to source time while inside this clip. A click moves it anywhere in
  the source, outside the span too (**peek**, §4.2): that is how you reach a frame past Out and press O, as v1.
- **Handle drag** shows that source frame on the stage (scrub player, exact seek) with the floating timecode.
  Release commits: the Reel rebuilds (§10) and the playhead returns to the clip's In, as v1. One undo step.
- Snap to the playhead within 6 px, ⌥ disables; minimum span 0.5 s; handles can't cross.
- Zoom: pinch / ⌘-scroll, ⌘= / ⌘−, or the caption's "− Zoom +", 1× to frame level, overview rail when zoomed
  (v1 after the T25 fixes). Selecting another clip resets it to 1×.
- Quick chosen (one-clip only, §5.7): faint keyframe ticks and "starts at 3.00 s, keyframe" under In.
- **Caption row** (28 px, above the canvas): clip name and "clip 4 of 18" left; Framing Fill | Fit (when shown),
  "Crossfade in" (clip 2 on) and "− Zoom +" right.

### 4.5 Inspector

v1's 300 px column with one change, the large number is now the Reel total: clip name (15/600) and two meta
lines ("1080×1920, HEVC, 29.97 fps" / "23.6 s, HDR (HLG)") · hairline · In, Out (15/500) and "Clip 8.5 s" ·
hairline · the Reel total (§4.3.6) · hairline · Remove audio (A), Loop Reel (`\`) · Export… (⌘E), the only
filled control, pinned to the bottom. For a one-clip Reel the total equals the clip length and the clip count
is hidden, which is v1's screen.

### 4.6 Media cache

`~/Library/Caches/trimlab 2/<sha1(path+size+mtime)>/` holds `poster.jpg`, `sprite.jpg` (40 frames at 2×, 64 px
tall), `peaks.bin` (Float16, 20 ms; empty for a silent clip, v1 ruling), `keyframes.bin` and `remux.mov`. The
cache is pruned LRU to 2 GB, and never deletes entries used by the open Reel.

### 4.7 Keyboard

The ⌘ shortcuts are menu items in the system menu bar, so they're discoverable and the menu bar stays the
standard one. Plain keys go through `KeyMonitor`. Both map to the same `Command` enum through
`KeyMap.command(for:context:)`, a pure, tested function.

| Key | Action |
|---|---|
| Space | Play / pause the Reel |
| ← / → | Step one frame (Reel time; source time in peek) |
| ⇧← / ⇧→ | Jump 1 s |
| ↑ / ↓ | Previous / next clip (select, playhead to its In) |
| ⌥← / ⌥→ | Move the selected clips one place earlier / later |
| J / K / L | Shuttle back / stop / forward (repeat for 2×, 4×) |
| Home / End · ⇧Home / ⇧End | Playhead to the clip's In / last kept frame (Out exclusive) · Reel start / last frame |
| I / O · ⌥I / ⌥O | Set In / Out at the deck playhead · reset In to source start / Out to source end |
| S | Split at playhead |
| X | Toggle crossfade into the clip |
| F | Toggle Fill / Fit on the selection |
| ⌫ / ⌦ | Delete the selected clips |
| ⌘A | Select all clips |
| A / \ | Toggle remove audio / loop |
| ⌘N / ⌘O / ⌘E | New Reel / Open clips or a Reel… / Export… |
| ⌘Z / ⇧⌘Z | Undo / redo (whole Reel, §4.8) |
| ⌘= / ⌘− | Deck zoom |
| ⌥⌘= / ⌥⌘− / ⌥⌘0 | Strip zoom in / out / fit |
| ? | Key map overlay |
| Esc | Close the top overlay or sheet; cancel a drag; clear a multi-selection |

Held-key repeat applies only to the arrows, ⌘Z / ⇧⌘Z and the zoom keys (v1 list). Trim keys wait while a
handle is held.

### 4.8 Undo and redo

Covered: the edits to the clips (add, delete, split, order, In/Out, join, framing, rename). Each undo step
restores the selection that was current at that step. Not covered: remove audio and the export sheet fields
(they are export settings, which undo leaves as they are), relinks (Locate… and a changed or moved source hold
across undo and redo), zoom, playhead and loop. A gesture (a handle drag, a reorder drag, a held ⌥→) is one step. History lasts the session only and
starts fresh when a Reel is opened. Edits record nothing while an export is running, because the sheet is
modal.

### 4.9 Export sheet

v1's sheet (560 px, slides from under the header, scrim behind), with these rows:

| Control | Options | Default |
|---|---|---|
| Format | **Reel** (1080×1920) / **Original** | Reel (pref) |
| Cut | **Exact** / **Quick** (§5.7) | Exact |
| Quality | **Standard** / **High** | High |
| HDR (any clip HDR) | switch "Convert HDR to SDR" | on |
| File name | editable | one clip: v1's `<stem>_<in>-<out>.mp4`; more: `<Reel name>.mp4` |
| Save to | folder well + Choose… (native panel) | the first clip's own folder (next to the `.trimlab` file); if that folder isn't writable, `~/Movies/trimlab 2/` with the quiet note (§8). A folder she picks with Choose… is remembered for that Reel only (§13 decision 1) |

- Captions: Reel "1080×1920, ready for Instagram."; Original "1920×1080 at 29.97 fps, from the first clip."
  The **Framing row is gone**; framing is per clip (§4.3.4).
- Summary, v1's string and plain words: `48.2 s  ·  about 84 MB  ·  H.264  ·  with sound` ("no sound";
  "sound kept as recorded" for Quick).
- **Quick** shows disabled with its reason as tooltip: "Quick works on a single clip saved as Original." or
  "Quick can't convert HDR." Choosing Reel or HDR conversion switches Quick to Exact visibly (v1 ruling).
- Over 3:00 with Reel: the §4.3.6 line in `--warn`. A missing clip blocks Export: "IMG_4821.MOV is missing.
  Locate it or remove it from the Reel."
- **Never overwrite a source:** a destination that resolves to any clip's source or the project file shows
  "That's one of the Reel's files. Choose another name." and disables Export. Any other existing file: Replace
  / Keep both (adds " 2"), inline, as v1.
- **Exporting** in place: "Exporting", file name, 2 px hairline with a gold run, "about 1 min left", percent,
  Cancel (stops the writer, deletes the partial). **Quit during an export cancels it** and cleans up first; an
  export that reports after the sheet was force-closed is cancelled at once (both v1 rulings).
- **Done:** 72×128 first-frame still, "Saved." (Bodoni italic 52), file name, "84.1 MB, in Spa Tour" (the folder's plain name, never
  `~`), then secondary buttons **Reveal in Finder**, **Open in QuickTime**, **AirDrop**
  (`NSSharingService(named: .sendViaAirDrop)`, hidden if unavailable) and, pushed right, **New Reel** (closes
  this saved Reel, shows the empty state). Esc or the scrim returns to the Reel. After a fallback: "Saved with
  the slower software encoder."
- **Error:** "Not saved", one plain sentence ("The disk is full."), a Details disclosure (AVFoundation domain,
  code, description, last 30 log lines, Copy), Close, and Back to settings as the filled button.

### 4.10 Modals and focus (carried from v1, ported)

`ModalStack` (model, tested) tracks the key map, the export sheet (with progress, done and error views) and the
ffmpeg card. **The most recently opened modal is on top** (v1 ruling: open time, not push order) and owns the
keyboard: Esc closes it; **Tab / ⇧Tab cycle only inside it** (the Tab trap); its text field types; Space or
Enter press its focused control; only its `passKeys` reach `KeyMap`, everything else is swallowed so the deck
and strip can't move; ⌘ combos it doesn't pass keep their system meaning (⌘Q, ⌘C) and app menu items are
disabled. **Every control is Tab-reachable on a stock Mac** with "Keyboard navigation" off (custom controls
are `.focusable()` views). Focus ring: 2 px gold, 2 px offset, keyboard focus only, never system blue. Closing
a modal returns focus to the control that opened it.

### 4.11 Window, prefs, logs

- 1240×860 at first; minimum **900×720** (v1: 640 tall; the strip adds 80 px and below 720 the stage would drop
  under 380 px). Frame remembered (`setFrameAutosaveName`).
- **Narrow (< 1000 px wide):** the inspector becomes v1's 64 px row under the stage (name, In / Out / total,
  both switches, Export pinned right); strip and deck unchanged.
- **Prefs:** `format`, `quality`, `cut`, `defaultFraming`, `removeAudioDefault`, `loop`, `tcMode`, `lastFolder`;
  a bad value falls back per key (v1). Open Recent via `NSDocumentController.noteNewRecentDocumentURL`.
- **Reduced motion** (`accessibilityReduceMotion`) turns every transition off.

### 4.12 v1 rulings carried forward

Plain-language copy ("with sound / no sound / sound kept as recorded", "in Documents" never `~`, the failure
and fallback lines) · load refused during an export · quit cancels an export · never overwrite a source · the
Tab trap · modal order by open time · a refused load leaves the UI untouched · reverse shuttle stops at the
start · End = last kept frame (Out exclusive) · the length unit stays attached to its number · over-3:00
warning in `--warn` · silent clip = empty peaks, waveform drawn as `sqrt` · fonts loaded before the first
frame · Original rounds odd dimensions down to even · no software fallback after a disk-full failure · every
export and remux is logged.

---

## 5. Composition and export engine

### 5.1 Planner rules (`TrimlabModel`, pure, TDD)

- **Placement:** clip *k* starts at clip *k−1*'s end minus its own effective fade-in; tracks alternate 0/1, so a
  crossfade always overlaps two tracks. Total = Σ trimmed − Σ effective fades.
- **Segments:** all placement starts and ends cut `[0, total)` into intervals, each listing its active layers,
  outgoing on top with an opacity ramp 1→0 in an overlap. No gap, no overlap (tested).
- **Audio:** one track per placement's slot; a crossfade ramps outgoing 1→0 and incoming 0→1.
  `hasAudioOut = !removeAudio && any clip hasAudio`; a silent clip leaves an empty range that reads as digital
  silence (spike verified).
- **Render size:** Reel 1080×1920; Original = the first clip's display size rounded down to even, other clips
  framed into it.
- **Frame rate:** the nominal rate covering the most Reel time, snapped to {23.976, 24, 25, 29.97, 30, 50,
  59.94, 60}, capped at 60, ties to the lower. One clip: its own rate (v1).
- `hdrOut = any clip HDR && !convertHDR`. **Missing clips** are skipped: preview plays without them, export
  refuses (§4.9).

### 5.2 `ReelCompositor` (Core Image)

- Custom `AVVideoCompositing`, one `ReelInstruction` per plan segment (its `LayerSpec`s and render settings),
  one shared Metal `CIContext` on its own serial queue.
- **Per layer:** source buffer → `CIImage` → `preferredTransform` → framing → `effects` (empty in v2; v5 hook)
  → the opacity ramp value at frame time. **Fill** scales to cover and centre-crops. **Fit** puts the frame,
  scaled to fit and centred, over a copy scaled to cover, clamped, `CIGaussianBlur` radius 30 (≈ v1's
  `boxblur=40:2`) and `CIColorControls` brightness −0.12.
- Layers composite bottom-up (source-over), then the overlay stage (empty in v2; v4 hook).
- **Colour:** linear extended-sRGB working space. The compositor does every conversion in Core Image:
  `canConformColorOfSourceFrames` is true, so AVFoundation hands over each source in its own colour and the
  compositor reads the buffer's real tags (AVFoundation's own conversion left each converted clip's first frame
  unconverted). SDR out renders to BT.709; an HLG or PQ source is converted to SDR with a baked v1 LUT
  (`hlg_to_sdr_v1.lut` / `pq_to_sdr_v1.lut`, 65³, applied by a tetrahedral Metal kernel), and any other HDR source
  falls back to Core Image's tone map. HDR out renders BT.2100 HLG 10-bit
  (`kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange`); an SDR source is mapped into HLG by Core Image. The compositor declares 8/10-bit 420 biplanar and BGRA
  as accepted source formats.
- **De-risk gate** (Phase 3, task 1; the one engine piece the spike didn't measure): (a) HLG fixture luma within
  3 % of v1's ffmpeg reference (YAVG 126.6); (b) composited 1080×1920 ≥ 120 fps on the 18-clip spike Reel;
  (c) gapless frame deltas as in spike check 1. If (a) fails, request BT.709 source buffers so AVFoundation
  converts (spike: 1 %), then CI. If (b) fails, stop and report to the owner before building on it.

### 5.3 `CompositionBuilder` and preview

- **Build:** plan + loaded assets → `AVMutableComposition` (two video tracks, up to two audio tracks, gaps via
  `insertEmptyTimeRange`), `AVMutableVideoComposition` (`customVideoCompositorClass = ReelCompositor`,
  instructions from segments, renderSize, frameDuration, colour properties) and `AVMutableAudioMix` from the
  ramps.
- **After any edit:** re-plan (< 1 ms), rebuild, `replaceCurrentItem` with a new `AVPlayerItem`, exact seek to
  the same Reel time (or the trimmed clip's In), restore the play state. Rebuilds coalesce to the latest edit;
  at most one is in flight.
- **Scrub players:** one `AVPlayer` per recently selected clip (LRU of 3) on the single asset, for peek and
  handle drags. **Assets:** `AVURLAsset` with `AVURLAssetPreferPreciseDurationAndTimingKey`, loaded once per
  clip for the Reel's life.

### 5.4 Export presets

| | Reel | Original |
|---|---|---|
| Size | 1080×1920 | first clip's display size, even |
| Frame rate | §5.1, constant | §5.1, constant |
| Video (SDR) | H.264 High (`AVVideoProfileLevelH264HighAutoLevel`), BT.709 tags | same |
| Video (HDR kept) | HEVC Main10, BT.2020 / HLG tags | same |
| Bitrate | Standard 8 Mb/s, High 14 Mb/s; `DataRateLimits` 1.5× when the writer accepts it | Standard 0.6×, High 1.0× the first clip's bitrate, min 6 Mb/s |
| Keyframe interval | 2 s | 2 s |
| Audio | AAC-LC 48 kHz stereo 192 kb/s, `AVAudioBitRateStrategy_Constant` (spike gap 6), or none | same |
| Container | `.mp4`, `shouldOptimizeForNetworkUse = true` (moov before mdat) | `.mp4` |

The HDR-kept path replaces v1's 8-bit-with-HLG-tags compromise (v1 ruling, Task 11) with real 10-bit.

### 5.5 `ExportRunner` (reader → writer)

1. Freeze the `Reel` value, plan it, build as §5.3. Reader outputs: `AVAssetReaderVideoCompositionOutput` (same
   video composition) and `AVAssetReaderAudioMixOutput` (LPCM 48 kHz stereo Float32).
2. Write `<stem>.<hex>.partial.<ext>` in the destination folder (`<hex>`: 8 random hex digits, so the name is
   this export's own and safe to delete); rename to `dest` on success.
3. **Constant frame rate** (spike gap 1): at each grid time `n × frameDuration` with no new buffer, re-append
   the previous buffer. Frame count = `round(total / frameDuration)` exactly.
4. Audio passes through `AudioStage` (identity in v2; v3 hook) before the writer input.
5. **Progress** = last appended video PTS ÷ total, at most 10×/s; ETA from a 3-sample moving average.
6. **Cancel:** `cancelReading`, `cancelWriting`, delete the partial. Quit calls the same path, waiting ≤ 3 s.
7. **Failure** → `diskFull`, `sourceUnreadable`, `encoderFailed`, `other`, each a plain sentence.
   `encoderFailed` retries once with `AVVideoEncoderSpecificationKey:
   [EnableHardwareAcceleratedVideoEncoder: false]` and sets `usedSoftwareEncoder`.
8. **Estimate:** `(video + audio bitrate) × total`; Quick: sum of the source sample sizes in range.

### 5.6 Importer (`.mkv` / `.avi`)

`ffmpeg -hide_banner -y -i <src> -c copy -map 0 -movflags +faststart <cache>/remux.mov` as an argv through
`Process` (never a shell string), searching `/opt/homebrew/opt/ffmpeg-full/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`. A codec that can't be copied into `.mov` gives "Can't open this .mkv: its video format won't
play on a Mac."; no re-encode fallback. `SourceRef` keeps the original path; the cache path resolves at load.

### 5.7 Quick cut: decision

**Kept, for a one-clip Reel only, with Original format and HDR conversion off; otherwise shown disabled with its
reason (§4.9).** Why: a stream-copy cut of one clip is v1 behaviour the owner's decisions keep, and the only
lossless, instant option for long Original clips. With several clips passthrough is unsound: sources differ in
codec, size, rotation and frame rate, joins would land on keyframes instead of chosen frames, and crossfades
and Fit need pixels. One-clip Quick is cheap: passthrough of a single-asset composition.

How: `KeyframeIndex` reads sync samples with `AVSampleCursor`; `snappedIn` = last sync sample ≤ In, shown in
the UI before export. `AVAssetExportSession(preset: AVAssetExportPresetPassthrough)`, `timeRange
[snappedIn, Out)`, `.mp4` (`.mov` for ProRes); remove audio = a video-only composition. Progress from
`states(updateInterval:)`; Cancel = `cancelExport()` plus delete the partial. No software fallback.

### 5.8 Details that bite

- **Rotation:** iPhone portrait is stored 1920×1080 at −90°; `ClipFacts` reports display size and the
  compositor applies `preferredTransform` (spike: all 11 Spa Tour clips).
- **VFR:** composition timing is honoured; CFR comes from §5.5 step 3. The spike's `vfr.mp4` 10 fps tail is a
  source property, not a join gap, and tests must tell them apart. 60 fps clips in a 29.97 Reel are sampled at
  the Reel grid (dropped, never blended).
- **Audio:** mono → dual mono and 44.1 → 48 kHz via the audio mix output settings; with several audio tracks,
  the first enabled one is used.
- Spaces and Unicode in paths are covered by fixtures.
- **Changed source** (size or mtime differ): re-probed on open; a shorter duration clamps Out, with "IMG_4821.MOV
  changed; its Out moved to the new end."

---

## 6. Visual design

### 6.0 Critical requirement: it must not look like a default app

The top requirement, carried from v1 §6.0 with "Python" replaced by "default SwiftUI / AppKit". A Reel editor
that works but looks like a stock Mac utility fails acceptance; the bar is a paid Mac app (Final Cut's trimmer,
Linear, Things).

**Hard rules:**

- **No default SwiftUI or AppKit controls in the window:** no system `Button` look, `Toggle`, `Picker`,
  `Slider`, `Stepper`, `Menu`, `TextField` chrome, `List`, `Form`, scroll indicators, `.help()` tooltips,
  `.alert`, `.confirmationDialog`, `.sheet`, `AVPlayerView` or `VideoPlayer`. Every control comes from
  `TrimlabEditor/Design` (§6.3). The only system UI allowed: the menu bar and the Open and Choose Folder panels.
  `test_no_default_controls` scans `TrimlabEditor/Views` and `App/` and fails on any forbidden symbol outside
  `Design/Controls/`.
- **Chrome:** hidden title bar, full-size content, traffic lights kept, the 56 px `--bg-0` header is the drag
  region (`WindowDragGesture`), window background `--bg-0` before the first frame, no title text.
- **No jank:** tabular figures, fixed-width timecode boxes, reserved rects so nothing shifts as posters,
  sprites and peaks load. **60 fps:** strip and deck are one `Canvas` each; drags don't rebuild other views.
- **Retina-sharp:** 2× sprites, vector PDF logo, canvases at backing scale. **Fonts:** bundled Inter and Bodoni
  Moda, PostScript names asserted by a test; no system font ever visible.
- **Motion with intent:** sheet 220 ms ease-out in, 180 ms out, scrim with it; 1 px glow on a grabbed handle;
  "Saved." rises and fades in once (420 ms); switch knobs 140 ms. Nothing else moves; reduced motion turns it
  all off.

### 6.1 Brand rules (unchanged from v1 §6.1)

- Dark, flat, hairline borders, no shadows beyond a 1 px edge. **Gold `#C9A86A` is the only accent**; DCV cyan
  only in the DCV logo's rule.
- Tokens: `assets/brand.css` verbatim plus the v1 UI plan's derived tokens, transcribed once into
  `Design/Tokens.swift`. A test parses `brand.css`, asserts `Tokens.swift` matches, and finds no `Color(`
  literal elsewhere.
- Inter for all UI text, `monospacedDigit()` on every number; Bodoni Moda for the CTC wordmark and the
  editorial words.
- Header lockup identical to v1: DCV logo (46 px) × Coll Takes Chagrin (Bodoni small caps), a rule, `trimlab`
  (Inter 11, .22em, `--muted`). On the right: the clip file name for a one-clip Reel, otherwise the **Reel
  name** (click to rename inline, which renames the `.trimlab` file), then `?`.

### 6.2 What makes it memorable

The boldness goes to the **deck** (unchanged) and its quieter parent, the **strip**: a row of living frames with
gold only where you are (selected outline, reorder caret). The strip uses gold outlines; only the deck has
filled gold bars, so they never compete. Editorial moments, Bodoni Moda italic, ivory: **"Drop clips."** (64 px,
with "or press ⌘O" in Inter) and **"Saved."** (52 px). The one large number is the **Reel total** (Inter 600,
44 px, tabular) with `of 3:00` at 20 px `--muted`.

### 6.3 Components (`TrimlabEditor/Design`)

Ported 1:1 from the v1 UI plan's component table: `TLPrimaryButton` (40 / 36 px, gold fill), `TLButton`
(secondary, 30 px, hairline), `TLIconButton`, `TLSwitch` (28×16), `TLSegmented` (28 px well), `TLTextField`
(30 px, gold focus border and selection), `TLFolderWell`, `TLTooltip` (350 ms hover, instant on keyboard focus,
`--tip-bg`, 5 px arrow; a disabled-looking control still shows its tip), `TLFocusRing`, `TLDisclosure`,
`TLProgressHairline`. New in v2: `StripCanvas` (§4.3.1), `DeckCanvas` (the spike's port of v1 geometry),
`DropCaret`, `JoinMark`, `ThreeMinuteMarker`. Radii graded as v1: sheet 12, buttons 7–8, tooltip 6, tiles 3.

### 6.4 Layout

```
┌────────────────────────────────────────────────────────────────────────────────┐
│ DCV × Coll Takes Chagrin │ trimlab                       Spa Tour          (?) │ 56
├──────────────────────────────────────────────────────────┬─────────────────────┤
│                                                          │ IMG_4821            │
│                    ┌───────────┐                         │ 1080×1920, HEVC,    │
│                    │           │                         │ 29.97 fps           │
│                    │  PREVIEW  │  composited Reel, 9:16  │ 23.6 s, HDR (HLG)   │
│                    │  (stage   │                         │─────────────────────│
│                    │   bg-0)   │                         │ In    0:01.21       │
│                    │           │                         │ Out   0:10.07       │
│                    └───────────┘                         │ Clip  8.5 s         │
│                                                          │─────────────────────│
│                                                          │ 48.2 s  of 3:00     │
│                                                          │ 18 clips            │
│                                                          │─────────────────────│
│                                                          │ ○ Remove audio   A  │
│                                                          │ ● Loop Reel      \  │
│                                                          │ [  Export…   ⌘E  ]  │
├──────────────────────────────────────────────────────────┴─────────────────────┤
│ ◀◀ ▶ ▶▶   0:07.12 / 0:48.20                                        − Zoom +    │ 40 transport
│      ▾ playhead cap                                                            │ 12 cap row
│ [▓▓▓▓][▓▓▓▓▓▓▓]╳[▓▓▓]┃[▓▓▓▓▓▓▓▓▓▓][▓▓][▓▓▓▓▓]╳[▓▓▓▓▓▓▓]  …  [▓▓▓▓][▓▓▓]       │ 56 Reel strip
│       gold outline = selected, ╳ = crossfade, ┃ = drop caret                    │ 12
├────────────────────────────────────────────────────────────────────────────────┤
│ IMG_4821 · clip 4 of 18          Framing [Fill|Fit]  ○ Crossfade in  − Zoom +  │ 28 deck caption
│ ░░░░[▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│▓▓▓▓▓▓▓▓▓▓▓▓▓▓]░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │ deck canvas 122:
│ ░░░░[∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿∿│∿∿∿∿∿∿∿∿∿∿∿∿∿∿]░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  │ cap 12+film 64+2+wave 44
└────────────────────────────────────────────────────────────────────────────────┘   + 8 pad
  1240×860: header 56, stage 526, bottom 278 (40 + 80 + 28 + 122 + 8); inspector 300
```

- The stage is `--bg-0`. The inspector, transport, strip and deck are `--bg-1`, split by hairlines.
- The transport row's "− Zoom +" is the **strip** zoom; the deck caption's is the **deck** zoom. Each sits
  next to the thing it zooms.
- Narrow (< 1000 px): as in §4.11.

### 6.5 Design gate (blocks UI build)

1. Load `frontend-design`; write a short addendum `docs/superpowers/specs/2026-10-28-trimlab2-ui-design.md`
   covering only what's new (strip, caption row, new states) and pointing at the v1 UI plan for the rest.
2. Build a **static HTML mockup** `design/mockup.html` from v1's mockup CSS and assets (HTML iterates fastest
   and is how the owner approved v1). Stills from Spa Tour or camlab C007, no person's likeness (v1 ruling).
   States: `#empty` ("Drop clips."), `#one-clip` (must read as v1's loaded screen), `#reel` (18 clips, clip 4
   selected, two crossfades), `#reorder` (caret), `#finder-drop` (caret, armed frame), `#multi-select`,
   `#over-3min` (marker, dimmed tiles, warn total), `#strip-zoomed`, `#missing-clip`, `#landscape-fit`
   (caption Framing, peek with 9:16 guide), `#sheet-reel` (Quick disabled with tip), `#done` (New Reel),
   `#narrow`.
3. Screenshots at 1240×860, @1x and @2x, go to the owner. **No Phase 4–7 work before approval.** This is the one
   question allowed beyond §13.
4. The native UI is checked against the approved mockup state by state (`ImageRenderer` captures into
   `docs/screens/`, §11), then a frontend-design self-critique in `docs/screens/CRITIQUE.md`: remove one
   accessory, fix anything that reads as default.
5. Final acceptance includes the owner's eyeball on the running `.app`.

---

## 7. Module interfaces

### 7.1 `TrimlabModel`

| Symbol | Contract |
|---|---|
| `apply(_:to:) throws(EditError) -> Reel` | Pure. Clamps In and Out to frame starts of `facts.frameDuration`, inside `[0, duration]`. A span is ≥ 0.5 s. `move` keeps relative order. `split` makes a new UUID for B. |
| `Planner.plan(_:) -> CompositionPlan` | Pure. Follows §5.1. Deterministic. |
| `Reel.total`, `Reel.overLimit(by:)` | Computed from the plan. The limit is 180 s. |
| `History` | §3.3, §4.8. |
| `ProjectCodec.decode(Data) throws -> Reel`, `encode(Reel) -> Data` | Pretty, sorted-key JSON. Migrates schema *n* → current in steps (`Migrations[n]`). `schema > current` throws `.newerVersion`. Unknown keys round-trip. |
| `SourceResolver.resolve(_:projectFolder:fileExists:) -> URL?` | Relative path first, then absolute. |
| `Naming.exportFileName(_:)`, `Naming.projectFileName(folder:existing:)` | v1 pattern for one clip, `<Reel name>.mp4` for more. `<folder name>.trimlab`, then ` 2`, ` 3`. |
| `KeyMap.command(for: KeyChord, context: KeyContext) -> Command?` | The table in §4.7. `KeyContext` holds hasClip, dragging, inTextField and topModal. |
| `ModalStack` | `open(id, passKeys)`, `close(id)`, `top`, `tabOrder(for:)`. §4.10. |
| `Prefs` | A Codable value with `validated()`. |

### 7.2 `TrimlabMedia`

| Symbol | Contract |
|---|---|
| `Prober.facts(for: URL) async throws -> ClipFacts` | < 30 ms for a typical iPhone clip. Rotation-aware display size, HDR from the format description's transfer function. |
| `Importer.playableURL(for: SourceRef, ffmpeg: FFmpegLocation?) async throws -> URL` | Remux for `needsRemux`. Throws `.needsFFmpeg`, `.remuxFailed(stderrTail)`. |
| `MediaCache.poster/sprite/peaks/keyframes(for:) async throws` | Cached per §4.6. Cancellable. Concurrency 3. |
| `CompositionBuilder.build(_ plan: CompositionPlan, assets: [UUID: AVURLAsset]) async throws -> BuiltComposition` | `composition`, `videoComposition`, `audioMix`. `videoComposition.isValid` is asserted in debug builds. |
| `ReelCompositor` / `ReelInstruction` | §5.2. |
| `ExportRunner.start(reel:dest:) -> AsyncThrowingStream<ExportEvent, Error>` and `cancel()` | Events: `.progress(Double, eta: Double?)` and `.done(ExportResult)`. `ExportResult` holds the url, bytes, firstFrame CGImage and `usedSoftwareEncoder`. |
| `QuickCut.snappedIn(for:clip:) async -> RationalTime`, `QuickCut.start(...)` | §5.7. |
| `ExportEstimator.bytes(reel:) -> Int64` | §5.5 step 8. |
| `FFmpegLocation.find() -> FFmpegLocation?` | The search path in §5.6. |

### 7.3 `TrimlabEditor` and the app target

`EditorModel` (`@MainActor @Observable`) owns `reel`, `selection`, `history`, `playhead`, `playState`,
`stripZoom`, `deckZoom`, `peek`, `modals`, `exportState`, `notes`. Intents: `importURLs(_:at:)`,
`open(project:)`, `newReel()`, `perform(_ edit: ReelEdit, coalesce:)`, `undo()`, `redo()`,
`select(_:extend:toggle:)`, `seek(reelTime:)`, `peek(sourceTime:)`, `play()`, `pause()`, `shuttle(_:)`,
`startExport()`, `cancelExport()`, `command(_ c: Command)`.

```swift
public protocol PlatformServices: Sendable {
  func openPanel(movies: Bool, projects: Bool) async -> [URL]
  func chooseFolder(start: URL?) async -> URL?
  func reveal(_ url: URL); func openInQuickTime(_ url: URL)
  var canAirDrop: Bool { get }; func airDrop(_ url: URL)
  func noteRecent(_ url: URL)
}
public protocol PlayerSurfaceHost { func attach(_ player: AVPlayer) }   // AVPlayerLayer in an NSView on macOS
```

The app target supplies `MacPlatformServices`; `PlayerSurface` (`NSViewRepresentable`, layer-backed view
hosting `AVPlayerLayer`, `.resizeAspect`); `KeyMonitor` (`NSEvent` local monitor → `KeyChord` →
`EditorModel.command`; ⌘ chords are left to the menus); `AppDelegate.application(_:open:)` for Finder and Dock,
including at launch, with URLs queued until the window is ready, never dropped (v1 ruling, Task 27);
`PrefsStore`; `FileLog`.

---

## 8. Finder integration and project files

### 8.1 Document types (Info.plist)

- **Movies**, role Viewer, rank Alternate: `public.movie`, `com.apple.quicktime-movie`, `public.mpeg-4`,
  `com.apple.m4v-video`, `public.avchd-mpeg-2-transport-stream`, `public.avi`, plus an imported
  `org.matroska.mkv` (v1 ruling). This gives Open With and Dock drops.
- **Reel project**, role Editor, rank Owner: exported UTI `com.dcv.trimlab.reel`, extension `trimlab`,
  conforming to `public.data` and `public.content`, not `public.json` (text editors shouldn't claim it). Icon:
  the app icon.
- `LSMinimumSystemVersion` 26.0, `CFBundleIconFile` trimlab, `ATSApplicationFontsPath` Fonts.

### 8.2 The `.trimlab` file

- **When:** written when a Reel first has **two or more clips**; a one-clip trim is v1 and shouldn't leave
  project files in camera-roll folders. Once written, trimlab never deletes it, even if the Reel drops back to
  one clip or none.
- **Where:** the folder of the first clip at creation, `<folder name>.trimlab` (then ` 2`). If that folder
  isn't writable (camera card, read-only volume), `~/Movies/trimlab 2/` with the quiet note "Saved the Reel in
  Movies › trimlab 2: the clips' folder is read-only." It never moves by itself afterwards. Renaming the Reel
  (§6.1) renames it in the same folder, never over anything: if `<new name>.trimlab` is taken (a file or a
  folder), the name stays as it was with the quiet note "A Reel named “X” is already in this folder."
- **Autosave:** 1 s after the last edit, and on New Reel, open, quit and window close; atomic (temp + rename);
  never touches the clips. Contents: the `Reel` (§3.2) as JSON with `"schema": 1` and `"app": "trimlab 2.0"`;
  no caches.
- **Reopen:** stored `ClipFacts` draw the strip at once; sources resolve (§7.1) and re-probe in the background.
  A missing source gives a "Missing" tile; when it's selected the inspector meta reads "Missing" with a
  **Locate…** button (Open panel), which relinks that clip and every other missing clip found by file name in
  the chosen folder.
- A newer schema refuses with "This Reel was made by a newer version of trimlab." and leaves the file alone.

### 8.3 Versioning policy

`schema` is an integer. Additive optional fields (v3 `music`, v4 `captions`, v5 `look`) bump it, and a
migration fills their defaults. Older builds refuse newer files (§8.2) rather than drop data on save. Within
a schema, unknown keys round-trip through `extra`. Tests hold a golden `schema1.trimlab` that every future
version must still open.

### 8.4 Signing and build

- `../camlab/app/make-signing-identity.sh` **exists and is reusable**: it is self-contained, and only its
  `NAME="camlab dev"` and p12-password literals are camlab-specific. Phase 1 **copies** it to
  `trimlab2/App/make-signing-identity.sh` with `NAME="trimlab dev"` (camlab untouched); the owner runs it once (up
  to two keychain prompts). A stable identity keeps macOS privacy grants (Documents and removable-volume access
  now, speech in v4) across rebuilds; an ad-hoc signature changes every build.
- `App/build.sh`: refuse while trimlab is running (v1 ruling) → `xcodegen generate` → `xcodebuild -project
  trimlab.xcodeproj -scheme trimlab -configuration Release -derivedDataPath build CODE_SIGN_STYLE=Manual
  CODE_SIGN_IDENTITY="trimlab dev" DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO` → copy to
  `dist/trimlab2.app` → `codesign -vv`. Without the identity it signs ad-hoc (`-`) and prints the one-time fix.
- Bundle id `com.dcv.trimlab2`, `CFBundleName` and display name "trimlab 2", file `trimlab2.app` (§13 decision 3): installs side by side with v1 (`com.dcv.trimlab`), which keeps working. Both claim movies at rank Alternate, so neither steals the other's Open With; only v2 owns `.trimlab`. Merging into one app is a later, separate decision after the owner's bench.

---

## 9. Icon

Ship **icon A** from v1 (`trimlab2/assets/trimlab.icns`; the owner picked it in v1): black rounded square, DCV
mark, gold hairline framed by two gold brackets, Coll Takes Chagrin in Bodoni small caps. It ships as
`CFBundleIconFile`; no asset catalog is needed. No new candidates.

---

## 10. Non-functional targets

The spike's measurements on this Mac set the targets. Each one has a test or a bench step in §11.

| What | Spike measured | v2 target |
|---|---|---|
| Cold launch to window | – | < 1.0 s |
| Load 18 assets | 80 ms | < 150 ms; strip with posters < 1.0 s |
| Plan + build composition, 18 clips | 2.7 ms | < 10 ms (with custom compositor instructions) |
| Edit → exact seek landed (warm, median) | 25.1 ms | < 50 ms; max < 100 ms |
| Edit → decoded frame on stage (warm, median) | 56.4 ms | < 100 ms; max < 150 ms |
| First item after launch (cold decoders) | 287 ms seek / 356 ms frame | < 500 ms, once |
| Join continuity | 0.00 ms first-frame offset at all joins | same; no composited frame delta > 1 frame at any join |
| Composited throughput 1080×1920 | 276.8 fps (built-in) | ≥ 120 fps through `ReelCompositor` (gate §5.2) |
| Export, 18-clip 39.7 s spike Reel, High | 6.05 s (writer) | < 10 s |
| Export, 30 s 4K HEVC one-clip Reel | – (v1 target) | < 10 s |
| Duration accuracy | 39.200 s exact (writer) | within ±1 frame of `plan.total`; frame count exact (CFR) |
| Bitrate | 13.9 of 14 Mb/s | within ±15 % of target |
| HDR→SDR luma vs v1 | 125.4 vs 126.6 (1 %) | within 3 % |
| Deck / strip canvas render | 0.1–0.2 ms | < 2 ms per frame; drags at 60 fps |
| Filmstrip 40 frames, 4K HEVC | ~1.0 s | background; never blocks input |
| `.mkv` remux 363 MB | 0.75 s | < 2 s |

Also:
Also: no network at runtime (fonts bundled); under 600 MB with a 30-clip Reel open; no main-thread work over
16 ms during playback or drags (checked with signposts).

---

## 11. Tests and acceptance

### 11.1 Fixtures

`scripts/make-fixtures.sh` generates them with Homebrew ffmpeg into `Tests/Fixtures/` (git-ignored): v1's
`portrait_hevc.mov`, `rotated.mov` (+90°), `landscape.mp4` (3840×2160), `hlg.mov`, `noaudio.mp4`, `vfr.mp4`,
odd-dims 1079×1917, `over3.mp4` and a spaces-and-`é` path; new `sixty.mp4`, `mono44k.mov`, `sample.mkv`,
`sample.avi`, `keyframes.mp4` (1 s GOP) and the golden `schema1.trimlab`. The script asserts each fixture's
probed properties so no test passes vacuously (v1 ruling). Media tests **fail, not skip**, without ffprobe or
fixtures.

### 11.2 Automated (must pass; output shown before any "done")

`xcodebuild test` on schemes `TrimlabKit` and `trimlab` is green.

- **Model:** every `ReelEdit` (clamps, min span, no crossing, split edges, multi-selection move, first-clip
  join ignored); totals and the effective-crossfade rule; history coalescing and selection restore; segments
  cover `[0, total)` with no gap or overlap; A/B alternation, frame-rate choice, render size; codec round trip,
  unknown keys kept, migrations, newer schema refused; naming; source resolution; `KeyMap` for every §4.7 row;
  `ModalStack` order, Tab trap, passKeys; prefs validation.
- **Media (ffprobe oracle):** probe facts (rotated dims, frame duration, HDR, hasAudio); the §5.2 gate; gapless
  composited read across all joins; Reel export = 1080×1920, `bt709` × 3, H.264 High, exact CFR frame count,
  duration ±1 frame, bitrate ±15 %, AAC 48 kHz stereo, `ftyp moov mdat`; remove audio = no audio stream;
  continuous silence across a no-audio clip; crossfade mid-frame luma between its neighbours; Fit background
  non-black and low-detail; HDR kept = HEVC Main10 `arib-std-b67`; Original odd dims → even; Quick starts at
  the reported keyframe with stream copy (codec and packet count match); cancel leaves no partial; destination
  == source refused; mkv/avi remux; Unicode paths.
- **Editor:** `EditorModel` with a fake `PlatformServices` and stub media: import order, insert at caret,
  refusal during export, selection follows the playhead on pause, autosave debounce, two-clip threshold,
  read-only folder fallback.
- **Source scans:** `test_no_appkit_in_package`, `test_no_default_controls`, tokens match `brand.css` with no
  colour literals outside `Tokens.swift`, fonts resolve.
- **Screens:** `ImageRenderer` renders every §6.5 state plus loading, exporting, error, ffmpeg card and key map,
  with stub data, @1x and @2x, into `docs/screens/`; the critique is checked in.
- **XCUITest smoke** (built `.app`): launch with two fixture URLs → two tiles → ⌘E → export → "Saved.". If
  macOS asks for automation permission, the builder asks the owner once.

### 11.3 Bench (the owner's Mac, built `.app`)

1. **v1 parity:** one iPhone HDR portrait clip, 3 s off each end with I/O, remove audio, export Reel: right
   length in QuickTime, silent, not washed out.
2. Drop the Spa Tour folder (18+ clips): shoot order. Reorder two, split one and delete its middle, add two
   crossfades, set a landscape clip to Fit. Playback gapless, no stutter at joins.
3. Quit; double-click `Spa Tour.trimlab` in Finder: the Reel reopens exactly, and ⌘Z works from there on.
4. Export, AirDrop to the iPhone, post a private/draft Reel: Instagram accepts it without re-cropping.
5. A landscape R50 V clip from `camlab/clips/`: Fill and Fit both look right and match the preview.

---

## 12. Build order

Each phase ends with an Opus code review (`requesting-code-review`) and a fix round. Phases 1–3 may proceed
while the gate screenshots wait for the owner (v1 ruling).

0. **Design gate (§6.5):** addendum, `design/mockup.html`, screenshots approved by the owner. Phases 4–7 wait.
1. **Skeleton:** license precondition (§0), `git init` + branch; `project.yml`; the package with three empty
   targets; fonts fetched and pinned; window (hidden title bar, `--bg-0`, lockup, "Drop clips."); `Tokens.swift`
   and its test; both source-scan tests; the signing-script copy, `build.sh`, Info.plist types; build the `.app`
   once to prove packaging and signing.
2. **Model (TDD):** types, `apply`, `History`, `Planner`, `ProjectCodec` + migrations scaffold + golden file,
   `Naming`, `SourceResolver`, `KeyMap`, `ModalStack`, `Prefs`.
3. **Media (TDD):** the compositor gate first (§5.2), then `Prober`, `CompositionBuilder`, `MediaCache`,
   `ExportRunner` (CFR, progress, cancel, fallback), `QuickCut`, `Importer`, `ExportEstimator`.
4. **Preview + strip:** `PlayerSurface`; import paths and order; the strip and all of §4.3; transport and keys;
   selection follows playhead; autosave, reopen, missing / Locate.
5. **Deck:** `DeckCanvas` port, handles, snap, peek and scrub players, deck zoom, caption row (framing,
   crossfade), undo across everything.
6. **Export UI:** sheet, estimate, Quick rules, progress, cancel and quit, done (Reveal, QuickTime, AirDrop,
   New Reel), error.
7. **Polish:** every state captured and compared to the mockup, critique, reduced motion, focus and Tab trap,
   narrow layout, key map overlay.
8. **Mac integration:** open events at launch and while running, Dock drop, `.trimlab` type, Open Recent, icon,
   prefs, logs, window restore.
9. **Verify and ship:** full §11.2 run with output shown, whole-branch review, bench with the owner, rebuild the
   `.app`, merge.

---

## 13. Decisions (answered by the owner, 2026-10-28)

1. **Default save folder:** next to the clips: the first clip's own folder, beside the `.trimlab` file. If it isn't writable, `~/Movies/trimlab 2/` with a quiet note. A folder picked with Choose… is remembered per Reel.
2. **Order of a dropped batch:** capture date (QuickTime creation date, then file creation date), then natural file name.
3. **Install:** side by side with v1 as "trimlab 2" (`com.dcv.trimlab2`, `trimlab2.app`, its own prefs, cache and logs) until the owner's bench passes. v1 keeps working.
4. **Crossfade length:** a choice per join: Short 0.25 s or Long 1 s (Cut is the default), shortened automatically on short clips.

---

*DCV Applied Technology, LLC · Chagrin Falls, OH 44023 · built for Coll Takes Chagrin*
