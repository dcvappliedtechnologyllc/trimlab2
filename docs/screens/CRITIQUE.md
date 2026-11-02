# trimlab 2: native screens, self-critique (Task 38)

The native screens are in `docs/screens/app/` (19 states, @1x and @2x, written by `ScreensTests.renderAll`). The
approved mockup captures are regenerated into `docs/screens/mockup/` (not tracked) with `swift scripts/mockup-shots.swift --page design/mockup.html --out docs/screens/mockup`. This critique is polish inside the approved design (SPEC §6.5 step 4).
SPEC §6.0's hard rules win over any point here. Anything that would visibly depart from the mockup is listed for
the owner and was not made.

## Remove one accessory

**The rules between key map rows.** The key map drew a hairline under each of its 22 rows: twenty-odd rules on one
panel, in a design where hairlines otherwise mean "a different area" (header, inspector, bottom block). The rows
already line up on the 120 px key column, and the key caps start each row. The rules are gone, and each row has
1 px more air above and below (`KeyMapOverlay`). The key map isn't one of the mockup's states, so nothing approved
changed.

## What read as a default, and the fix

| What read as default | Fix (applied) |
|---|---|
| A clip still probing showed its stand-in facts as real numbers: In 0:00.00, Out 0:01.00, Clip 1.0 s. | While a clip is probing or preparing, In, Out and Clip read "–" in `--muted` (wide and narrow). `InspectorView.waiting`. |
| While clips load, the Reel total counts their 1 s stand-ins and looks final. | The total is `--muted` until every clip has loaded (`InspectorView.totalInk`). In the narrow row the dash keeps the timecode's width. |
| The ffmpeg card's sentence wrapped as "…Install it / with Homebrew:", leaving the instruction's tail alone on a line. | The §4.1 sentence is laid out as two lines, split at its full stop (`FFmpegCard.lines`, which a test checks joins back to the sentence byte for byte). |
| The disabled Quick tip floated above the well, cut off with "…" ("Quick works on a single clip saved a…") and covering the Cut row. | It now uses v1's in-sheet tip: 10 px to the right of Quick, vertically centred, 206 px wide and wrapping, with the arrow on its left. This is what the mockup draws. (`TLTipPlacement.beside`) |
| The error Details box was empty in stills, and the log was cut off with "…" instead of showing its last lines. | A still draws the log's last 218 px, bottom-anchored as the live box opens. |
| The export sheet sat halfway down the stage instead of hanging from the header. This also affected the live window. | The sheet's row is top-aligned. The inspector's full-height spacer had been centring it. |

**The focus ring.** Every focusable Design control (`TLFocusRing`, `TLSegmented`, `TLTextField`) uses
`.focusEffectDisabled()` and draws its own 2 px `--brand-gold` ring (the text field's edge turns gold). Nothing
in TrimlabEditor uses `accentColor` or `.tint`, so the system blue ring can't appear. A still can't hold keyboard
focus, so no screen shows the ring. The live check is the owner's.

## For the owner (not changed: these would visibly depart from the approved mockup)

1. **Middle-dot summary.** The sheet's summary "48.2 s · about 84 MB · H.264 · with sound" is the dotted meta
   string that templated UIs use. Two quieter options: plain spacing, or "48.2 s, about 84 MB, H.264, with sound".
   The approved mockup uses dots, so they stay.
2. **Error Details for trimlab's own errors** start "Domain: TrimlabMedia.ExportError / Code: 4". That's useful in
   a pasted report but reads as developer text. One option is to show the sentence and the log, and keep
   domain/code only for system errors. (The mockup has no error state. This is a T36 copy call.)
3. **Weight.** The captures render text slightly heavier than WebKit drew the mockup. Font, weight and size match
   the CSS exactly (Inter 4.001 at the same weights). The difference is how the text is rasterised: WebKit drew the
   mockup with `-webkit-font-smoothing: antialiased`, and CoreText applies the system's font smoothing, as the live
   app will. The fix would be to fight the system's antialiasing, which the brief rules out. Check this on the
   running app.
