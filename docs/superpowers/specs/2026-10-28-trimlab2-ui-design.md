# trimlab 2 UI design addendum

This file covers only what is new in v2: the Reel strip, the caption row, the new inspector lines and the
multi-clip states. Everything else is the v1 UI plan (`../trimlab/docs/superpowers/specs/2026-10-27-trimlab-ui-design.md`),
cited below by section name. SPEC.md §4 and §6 win on any disagreement, and then this file gets fixed. The
clickable mockup is `design/mockup.html`. Its states are chosen by `location.hash`, and it sets `window.__ready = true`
once the fonts and every image have decoded.

## Subject, audience, job (delta from v1)

- **Subject:** a Reel of 15+ short clips from one shoot (Spa Tour), mostly room and product B-roll, hard cuts
  and a few crossfades.
- **Job:** put the clips in order, trim each one, and save one Reel-ready file. The deck stays the hero, and the
  strip is its quieter parent.

## Direction

v1's precision instrument is unchanged. The strip adds a contact sheet of the shoot: real frames, no text on the tiles,
and gold only where you are (the selected outline and the drop caret). The deck keeps the only filled gold bars, so the two
rows never compete (§6.2).

## Tokens and type

No new colours. Every value comes from v1 (the design-values section of the v1 plan), `assets/brand.css` verbatim plus the derived
tokens. The new roles below use only existing tokens.

| New role | Value |
|---|---|
| Selected tile outline | 1.5 px `--brand-gold`, inset, radius 3 |
| Also-selected tile | 1 px `--muted` ring just **outside** the tile, in its half of the 2 px gap (an inset 1 px muted line vanished on bright frames) |
| Missing tile | `--bg-2` fill; "Missing" Inter 12/400 `--muted`, centred, drawn only when it fits (text width + 6 px) |
| Dragged tile | 35 % opacity; ghost 80 %, at most 96 px wide, lifted 6 px, with the 1.5 px gold outline |
| `JoinMark` | `╳`, 1 px `--brand-ink` at 70 %, corner to corner across the overlap, at least 10 px wide (centred on the overlap), inset 14 px top and bottom |
| `DropCaret` | 2 px `--brand-gold`, the tile height + 4 px above and below, centred in the gap |
| `ThreeMinuteMarker` | 1 px `--warn` from the top of the cap row to the bottom of the tiles; "3:00" Inter 11/500 `--warn`, right-aligned 4 px left of the line, baseline 10 px |
| Past 3:00 | `--deck-out` (bg-0 at 70 %) over the tiles right of the marker |
| Reel total over 3:00 | the 44 px number in `--warn`; the line under it Inter 12/17 `--warn` |
| Caption clip name | Inter 13/500 `--text`; "clip 4 of 18" and "4 clips selected" 12/400 `--muted`, 16 px gaps, no separator glyph |

Type is v1's "Type" table. Additions:

- **Reel total:** Inter 600 44/48 px, `-0.02em`, `--brand-ink`. The unit `s` is 20 px 500 `--muted`, 4 px after the
  number. `of 3:00` is 20 px 500 `--muted`, 10 px after. From one minute up the number reads `2:14.6` with no
  unit. Under it, "18 clips" in 12/17 `--muted`, 2 px below.
- **Over-3:00 line:** "Instagram Reels can be up to 3 minutes. Trim 0:12.4 more." in 12/17 `--warn`, 8 px
  below the count. It wraps to two lines in the 252 px column.
- **Transport timecode:** v1's 15/500. The playhead sits in a fixed 60 px box, then ` / 0:48.05` in `--muted`, so
  nothing shifts.

## Layout (1240×860)

The v1 "Layout grid", with the bottom block grown from 170 to 278:

```
header 56
stage (bg-0) 940×526                        │ inspector 300
bottom 278, bg-1, hairline top, side padding 20:
  transport 40     ◀◀ ▶ ▶▶  0:09.17 / 0:48.05                       − Zoom +   (strip zoom)
  strip 80         cap 12 · tiles 56 · 12
  caption 28       hairline top (full width) · IMG_4821  clip 4 of 18 · · ·  Framing [Fill|Fit]  Crossfade in [Cut|Short|Long]  − Zoom +   (deck zoom)
  deck 122         v1 canvas, unchanged (cap 12 + film 64 + gap 2 + wave 44)
  pad 8
```

- Body grid: rows `56px minmax(0,1fr) 278px`, columns `minmax(0,1fr) 300px`. The bottom block spans both columns.
- The strip and the deck share the 20 px side padding, so the strip's first tile and the deck's left edge align.
- The caption row's hairline runs the full window width (margin −20 px). That splits "the Reel" (transport and
  strip) from "this clip" (caption and deck).
- The caption has 20 px padding on the left and 14 px on the right, so the "+" icon's glyph lines up with the transport's "+".
- **Empty:** v1's empty screen: header and stage only, "Drop clips." Bodoni italic 64/72, "or press ⌘O" Inter 13
  `--muted`, 8 px apart. The header has no name and no `?`.
- **Narrow (< 1000 px):** v1's 64 px inspector row: the name, In and Out, the total at 24/28 (unit and `of 3:00` at
  14 px, 6 px apart), both switches with no key hints, and Export… 140 px pinned right. The meta, Clip row, count,
  over line and Locate… are hidden in that row. The caption keeps its labels. At 960 px there is room.

## The Reel strip (`StripCanvas`, §4.3.1)

- **Geometry:** a 12 px cap row, 56 px tiles at radius 3, then 12 px. Gaps are 2 px of `--bg-1` at cuts. At a crossfade
  the incoming tile starts `effectiveFade × px/s` earlier and is drawn over the outgoing one, with no gap.
- **Fit:** px/s is solved so the laid-out width equals the strip width, counting the 24 px minimum tiles, the gaps and
  the overlaps. The mockup bisects; the app can do the same over its piecewise layout. In the mockup's 18-clip Reel,
  the 0.6 s clip 10 is the minimum-width tile.
- **Frames:** sprite cells are drawn edge to edge at the source aspect (31.5 px wide for 9:16, 99.6 px for 16:9
  at 56 px tall), sampled across the **kept** span. The last frame is clipped by the tile's rounded rect.
- **Playhead:** the v1 deck's playhead: 1 px `--brand-ink` through the tiles, with a 9×7 cap at radius 2 at y 3. It stays
  visible during a reorder or a Finder drop.
- **Zoomed:** the same drawing at a fixed px/s (the mockup's `#strip-zoomed` is 64 px/s), scrolled so the playhead sits at
  40 % of the width. Tiles are cut by the strip's edges. There is no scrollbar and no overview rail: the cut tiles at
  both edges already say there is more.
- **Hit-testing:** the 2 px cut gap itself, or the crossfade overlap (at least 4 px, centred), is the **join** of the
  clip on the right. The join zone never takes the tile body, so a 24 px tile can be selected anywhere on it. A click
  cycles cut → Short → Long → cut. Hovering shows the v1 tooltip above the cap row, after 350 ms: "Cut (X)",
  "Crossfade, 1 s", or "Crossfade, 0.8 s (clip is short)". Anywhere else on a tile selects it (⇧ range, ⌘ toggle).

## Caption row (28 px, §4.4)

- **Left:** the clip name, then `clip 4 of 18`. With a multi-selection: `4 clips selected`. A one-clip Reel shows only
  the name.
- **Right**, in this order with 16 px gaps:
  - Framing `[Fill|Fit]`, only when the primary isn't 9:16 and the format is Reel.
  - Crossfade in `[Cut|Short|Long]`, hidden on the first clip.
  - The deck's "− Zoom +": 24 px icon buttons with 14 px glyphs, label 12 `--muted`.
- Each control's label is Inter 12 `--muted`, 8 px before its control.
- **`TLSegmented`, compact size** (new, caption only): a 22 px well, radius 6, 2 px inner padding, 52 px segments,
  Inter 12/500, inner radius 4. Everything else is v1's "Segmented control" (`--bg-0` well, 1 px `--line`, selected
  `--bg-2` with `--brand-ink`). The sheet keeps the 28 px / 90 px size.

## Inspector (§4.5)

The v1 inspector column, with these sections split by hairlines: name and meta · In, Out, `Clip 8.5 s` (a third
`tc-row`) · the Reel total, count and over line · Remove audio (A), **Loop Reel** (`\`) · Export… pinned to the bottom.

- **One-clip Reel:** no Clip row and no count. The total sits in the In/Out section, 14 px below Out, as in v1, with
  `of 3:00`. The header shows the file name, `IMG_4821.MOV`.
- **Missing clip selected:** the meta reads "Missing" (12 `--muted`), with a **Locate…** `TLButton` (v1 secondary, 30 px)
  10 px under it. In, Out and Clip come from the stored facts. The total leaves the missing clip out (Planner).
- **Header Reel name** (`Spa Tour`): a plain text button. Hover turns it `--brand-ink`, with the tooltip "Rename the Reel"
  below. There is no hover fill.

## States in the mockup

| Hash | What it shows |
|---|---|
| `#empty` | "Drop clips." / "or press ⌘O" (v1 empty) |
| `#one-clip` | v1's loaded screen: one full-width tile, deck, total 8.5 s of 3:00, header `IMG_4821.MOV` |
| `#reel` | 18 clips, clip 4 selected, Long into clip 8 (effective 0.8 s, short neighbour), Short into clip 13; total 48.2 s |
| `#reorder` | clip 4 at 35 %, its ghost lifted at 80 %, caret between clips 9 and 10 |
| `#finder-drop` | Finder clips held over the strip: the insert caret between clips 11 and 12 **only**. v1's armed hairline window frame (`inset 6px`, radius 10, `--gold-hair`) is the append cue for a drop anywhere else, and the two never show together (§4.3.3) |
| `#multi-select` | clips 4–7: gold primary, muted rings on 5–7, caption "4 clips selected" |
| `#over-3min` | total 3:12.4 in `--warn`, the over line, the marker and the dimmed tiles past it |
| `#strip-zoomed` | 64 px/s, the playhead at 40 % |
| `#missing-clip` | clip 9 Missing tile selected; stage line "IMG_4826.MOV is missing. Locate it or remove it from the Reel." in 13 `--muted`; deck shows bg-2 blocks with the stored brackets and no playhead; inspector Locate… |
| `#landscape-fit` | clip 6 (16:9) selected, caption Framing = Fit, stage in peek: the whole source letterboxed, **no guide and no dim** (Fit crops nothing); the deck playhead is past Out |
| `#landscape-fill` | the same with Framing = Fill: v1's 9:16 gold guide with the outside dimmed 40 % (§4.2: the guide shows only for Fill) |
| `#sheet-reel` | v1 sheet without the Framing row: Reel, Exact with Quick disabled and its visible tip "Quick works on a single clip saved as Original.", High, Convert HDR to SDR on, `Spa Tour.mp4`, Save to `Spa Tour`, summary `48.2 s  ·  about 84 MB  ·  H.264  ·  with sound` |
| `#done` | "Saved.", `Spa Tour.mp4`, `84.1 MB, in Spa Tour`, Reveal in Finder, Open in QuickTime, AirDrop, then **New Reel** pushed right (v1 "Done state", with New Reel in place of Trim another) |
| `#narrow` | `#reel` at 960 px with the 64 px inspector row |

Outside peek, the stage shows the composited Reel at 9:16. For a selected 16:9 clip that is the landscape still,
centre-cropped for Fill or letterboxed on `--bg-0` for Fit.

The mockup is clickable: tiles select (⇧ / ⌘), joins cycle, ↑ / ↓, X, F and A work, and Export… → sheet → Export → done
→ New Reel → empty. Esc or the scrim returns to the state (and selection) the sheet was opened from. Loading `#sheet-reel`
or `#done` directly returns to `#reel`.

## Motion

v1's "Motion", unchanged. The strip adds none: the caret is the only thing that moves during a reorder, and
neighbours don't slide (§4.3.3), so reduced motion needs no special case. The loading shimmer on tiles is v1's deck
shimmer at tile size.

## Imagery

Spa Tour B-roll with **no person in frame**, not even a hand (v1 ruling). `CandleFlickerCloseup.MP4` is the only
Spa Tour clip with no person in it. It supplies the hero (clip 4, full frame), both stills (the landscape one is a 16:9
crop of the candle bowl) and 12 of the 18 sprites, as detail crops.

The other six sprites (01, 02, 03, 05, 10, 11) come from clips with a person in them. Each is a crop of the upright frame
(a soft-focus shelf, a sconce, the vanity, the nook wall, a door panel), sampled over a **0.3 s window**. The frames at
both ends of each window were checked at full size before use. Long windows let hands drift into the crops
(the first round shipped six sprites with fingers or a forearm in some cells), so the windows are now short enough that
nothing moves.

`saved-thumb.jpg` is sprite 01's first frame. The waveform is ColNook3's audio. Audio carries no likeness.

Every committed sprite was opened at native size (576×640, or 1824×640 for 06) and all 40 cells were checked one by
one. There is no person, face, hand or fingertip in any cell.

Recipe:

```
D=~/Downloads/Spa\ Tour; C="$D/CandleFlickerCloseup.MP4@0.5-7.2"
scripts/mockup-assets.sh --still "$C@0,0,1" --peaks "$D/ColNook3.MP4" \
 "$D/ColCoral1.MP4@30-30.3@0.62,0.14,0.38"   "$D/ColSconce2.MP4@6-6.3@0.55,0.05,0.45" \
 "$D/ColNook3.MP4@6-6.3@0,0.6,0.3"           "$C@0,0,1" \
 "$D/ColCentered2.MP4@11.8-12.1@0,0.15,0.5"  "$C@0,0.6,1,wide" \
 "$C@0.05,0.02,0.45"   "$C@0.1,0.08,0.6"     "$C@0,0.2,0.5" \
 "$D/ColIntroNew1.MP4@9.5-9.8@0,0.1,0.32"    "$D/ColSconce1.MP4@22-22.3@0.6,0.05,0.4" \
 "$C@0,0.55,0.45"      "$C@0.5,0.1,0.5"      "$C@0.2,0.55,0.45" \
 "$C@0.5,0.5,0.5"      "$C@0.4,0.6,0.35"     "$C@0.55,0.3,0.45"   "$C@0.3,0.3,0.4"
```

## Plan review against the brief (frontend-design pass 1)

- Draft put the clip name and duration on each tile. That is the generic NLE look, and §4.3.1 says no text on tiles.
  Names live in the caption and inspector, so the strip stays a row of pictures.
- Draft made the crossfade a gold bow-tie. Gold would then appear on every join, and §6.2 keeps gold "only where
  you are". It is the ivory `╳` at 70 %.
- Draft gave the zoomed strip a v1-style overview rail in the cap row. That would collide with the playhead cap and the
  3:00 label, so it was cut. The cut edge tiles do the job.
- Draft hid the caption's control labels in narrow. "Cut Short Long" alone doesn't say what it changes, and 960 px
  has room, so the labels stay.
- The caption once had a `·` between the name and "clip 4 of 18". That is the middot-meta tell. A 16 px gap and the
  muted colour already separate them.

## Self-critique (frontend-design, after the build)

1. Removed one accessory: the `--bg-2` hover fill behind the header's Reel name. It was the only filled hover in the
   header and made a text label look like a toolbar button. Hover is now a colour change to `--brand-ink`.
2. Fixed what read as default: the also-selected 1 px `--muted` outline, drawn inset, disappeared on bright frames
   and multi-select looked broken. It is now a ring outside the tile, in the gap. The reorder ghost was a full-width
   copy that buried the caret; it is now capped at 96 px and lifted 6 px.
3. Review round 1:
   - Person-free sprites (see Imagery).
   - The 9:16 guide follows the framing (Fill only).
   - Finder-drop shows only the caret.
   - The playhead stays visible during drags.
   - The join zone no longer swallows the edges of short tiles.
