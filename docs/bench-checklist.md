# trimlab 2 bench checklist

Run these on `build/testdrive/trimlab2.app`, the test-drive copy. For each one, note what you see. Anything that looks wrong becomes a fix, and its test gets written first.

## The five main checks

1. **HDR clip, trimmed and silent.** Open one iPhone HDR portrait clip. Set In 3 s from the start and Out 3 s from the end (I / O), then press A to remove the audio, and export as a Reel. In QuickTime: is it the right length, silent, and not washed out?
2. **A whole shoot.** Drop the Spa Tour folder. Are the clips in shoot order? Reorder two, split one and delete its middle, add two crossfades, and set a landscape clip to Fit. Does playback run without gaps and without a stutter at the joins?
3. **Reopen the project.** Quit, then double-click `Spa Tour.trimlab` in Finder. Does the Reel come back exactly as you left it? (Undo history starts fresh when a Reel is opened, by design; check ⌘Z works on a new edit.)
4. **Instagram.** Export, AirDrop it to your iPhone, and post it as a private or draft Reel. Does Instagram take it without re-cropping?
5. **Landscape R50 V clip.** Use a clip from `camlab/clips/`. Do Fill and Fit both look right, and does the export match the preview?

Also: look over the running app next to the approved mockup. Does anything look off?

## The rest, when you have time

**Pointer and keys**
- Use a real mouse and trackpad: Finder drops, ⌘-scroll and pinch to zoom.
- Grab the deck handles and their margin tabs. Check the resize cursor, the 6 px snap, and that ⌥ turns the snap off.
- Start a drag, then interrupt it by opening a sheet or switching windows. Nothing should get stuck.
- Try the menus and keys, including ⌥I and ⌥O.
- Press Tab with Full Keyboard Access on, then off. The focus ring should never be system blue, and clicking the stage should clear focus.

**Layout**
- Make the window narrow, about 900 px and 960 px wide.
- Turn on Reduce Motion.

**Look on real footage**
- How strong the span glow is, and how heavy the text looks.
- Where the tooltips sit.
- The SDR level in a Reel that keeps HDR.

**Playback**
- Audio plays.
- Press End inside a crossfade.
- Scrub 4K footage. Is it fast enough?

**Export sheet**
- The sheet slides in.
- Type a name and press Return.
- Use Choose… to pick a folder.
- Check the Quick tooltip.
- Over-3-minute warning: "3:12.4 of 3:00" next to "Trim 0:12.5 more".

**Exporting**
- Replace and Keep both, against a real file that already exists.
- Cancel mid-export. Quit mid-export. Close the window mid-export.
- The "Saved." animation, then Reveal, QuickTime and AirDrop.
- On an error: scroll the Details and use Copy.
- On the ffmpeg card: re-check and Copy.
- A 5–10 minute export, once to a slow drive as well.

**Opening**
- Open panels and Open Recent.
- Run `open` with a .mov, once with the app closed and once with it open.
- Drop a clip on the Dock icon.
- Double-click a .trimlab file.
- Check `mdls` on a .trimlab file.
- Close the window, then bring it back three ways: the Dock icon, Window › trimlab 2, and opening a clip. You should get exactly one window each time.

**Renaming the Reel** (a Reel with two or more clips)
- Click the name in the header. The text field should open with the cursor already in it.
- Tab to the name and press Return or Space. The field should open.
- Type a new name and press Return. It's renamed, and the gold ring comes back on the name.
- Press Esc while editing. The old name stays, the ring is on the name, and there's no beep or sheet.
- Click the stage or strip while editing. The new name is kept and no ring shows.
- Try a name already used by another Reel in that folder. The note "A Reel named “X” is already in this folder." should appear.
- In Finder, the `.trimlab` file has the new name. ⌘Z puts the old name back on both.
- File › Open Recent shows the new name.
- With VoiceOver on, the name reads as "Reel name".
- Drag across the text in the field to select it. It should select, not move the window.
- Start typing a new name, then press ⌘E, `?`, ⌘N or ⌘Q without pressing Return. The typed name should be kept.
- Rename a Reel saved on an exFAT drive.
- Type with a composing input method (for example Japanese), then press Return or Esc. It should only finish or cancel the composing, not the whole rename.

**Stalls, by hand**
- Play 30 seconds, then drag the strip. Then run `grep -c stall ~/Library/Logs/trimlab\ 2/trimlab.log` and compare it with the count before you started. It should not go up.

**Relaunch**
- After a relaunch, Loop is remembered and the window frame comes back.
- The log lines look right.
- The cleanup of old export files never brings up a folder-access prompt.
