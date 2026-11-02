import SwiftUI
import TrimlabModel

/// §4.2, §6.4. The 40 px transport row: ◀◀ ▶ ▶▶ (a second back, play / pause, a second on), the timecode
/// `playhead / total` (the playhead in a fixed box so nothing shifts; a click switches `m:ss.ff` ↔ seconds), and on
/// the right the strip's "− Zoom Reel +".
public struct TransportView: View {
  let model: EditorModel
  let onZoom: (Int) -> Void

  /// `onZoom(±1)`: the strip zoom steps (Task 29 wires them).
  public init(model: EditorModel, onZoom: @escaping (Int) -> Void = { _ in }) {
    self.model = model
    self.onZoom = onZoom
  }

  /// The playhead's box: 60 px for `0:09.17` (the addendum), 68 px for `102.40 s`.
  static func playheadBox(_ mode: TCMode) -> CGFloat { mode == .timecode ? 60 : 68 }

  public var body: some View {
    HStack(spacing: 2) {
      TLIconButton(.back, label: "Back one second", tip: "Back one second (⇧←)") { model.jump(-1) }
      TLIconButton(model.isPlaying ? .pause : .play, size: .play, label: model.isPlaying ? "Pause" : "Play",
                   tip: model.isPlaying ? "Pause (Space)" : "Play the Reel (Space)") { model.togglePlay() }
      TLIconButton(.forward, label: "Forward one second", tip: "Forward one second (⇧→)") { model.jump(1) }
      TimecodeReadout(model: model).padding(.leading, 12)
      Spacer(minLength: 0)
      HStack(spacing: 2) {
        TLIconButton(.minus, label: "Zoom the Reel out", tip: "Zoom the Reel out (⌥⌘−)") { onZoom(-1) }
        Text("Zoom Reel")
          .font(.tl(.inter(.regular), 12))
          .foregroundStyle(Tokens.muted)
          .padding(.horizontal, 4)
        TLIconButton(.plus, label: "Zoom the Reel in", tip: "Zoom the Reel in (⌥⌘=)",
                     tipPlacement: TLTipPlacement(.above, align: .trailing)) { onZoom(1) }
      }
    }
    .padding(.horizontal, -6)
    .frame(height: Tokens.Layout.transport)
  }

  static func format(_ t: RationalTime, mode: TCMode, frame: RationalTime) -> String {
    mode == .timecode ? Formatting.timecode(t, frame: frame) : Formatting.seconds(t)
  }
}

/// `playhead / total`. While playing only `PlayheadDigits` reads the playhead: rebuilding this button (its focus,
/// hover, tooltip and accessibility modifiers) and re-laying out the window for a new `Text` on every frame was about
/// 40 % of the main thread's time during playback, and pushed passes over the stall watchdog's 16 ms (Task 42
/// acceptance 2, miss 6). VoiceOver hears the time while paused; while playing, a label that changed every frame
/// would rebuild the button again.
struct TimecodeReadout: View {
  let model: EditorModel

  var body: some View {
    let mode = model.prefs.tcMode
    let fd = model.plan?.frameDuration ?? RationalTime(1001, 30000)
    let all = TransportView.format(model.displayTotal, mode: mode, frame: fd)
    return TLButton(style: .bare, label: Self.label(model), action: model.toggleTCMode) {
      HStack(spacing: 0) {
        PlayheadDigits(model: model, mode: mode, frame: fd)
          .frame(width: TransportView.playheadBox(mode), height: 28)
        Text(" / \(all)")
          .font(PlayheadDigits.font)
          .monospacedDigit()
          .foregroundStyle(Tokens.muted)
      }
      .lineLimit(1)
      .fixedSize()
      .frame(height: 28)
    }
  }
}

extension TimecodeReadout {
  /// The button's VoiceOver label: "Playhead 0:09.17 of 0:40.00" paused, "Playhead, playing, of 0:40.00" while
  /// playing (it doesn't read the playhead then).
  static func label(_ model: EditorModel) -> String {
    let mode = model.prefs.tcMode
    let fd = model.plan?.frameDuration ?? RationalTime(1001, 30000)
    let all = TransportView.format(model.displayTotal, mode: mode, frame: fd)
    guard !model.isPlaying else { return "Playhead, playing, of \(all)" }
    return "Playhead \(TransportView.format(model.playhead, mode: mode, frame: fd)) of \(all)"
  }
}

/// The playhead's digits, the one thing a playback tick changes in the transport: drawn in a canvas in a fixed box,
/// so a new value only redraws it. As a `Text`, each new string made SwiftUI lay out the whole window again
/// (every control's geometry, the window's minimum size) on every frame.
struct PlayheadDigits: View {
  static let font = Font.tl(.inter(.medium), 15)
  let model: EditorModel
  let mode: TCMode
  let frame: RationalTime

  var body: some View {
    let now = TransportView.format(model.playhead, mode: mode, frame: frame)
    Canvas { context, size in
      let text = context.resolve(Text(now).font(Self.font).monospacedDigit().foregroundStyle(Tokens.text))
      let scale = Self.fit(text.measure(in: CGSize(width: .infinity, height: size.height)).width, in: size.width)
      context.clip(to: Path(CGRect(origin: .zero, size: size)))  // never past the box, whatever the string
      context.translateBy(x: 0, y: size.height / 2)
      context.scaleBy(x: scale, y: scale)
      context.draw(text, at: .zero, anchor: .leading)
    }
  }

  /// The scale that fits a string `width` wide into the box: 1 when it fits. At 15 pt the box holds `9:59.29` (57 pt
  /// of 60) and `999.99 s` (65 of 68); a Reel from 10:00 (`10:00.00`, 67 pt) or 1 000 s on is drawn smaller rather
  /// than running into " / total" (the `Text` this replaced truncated instead).
  static func fit(_ width: CGFloat, in box: CGFloat) -> CGFloat { width > box && width > 0 ? box / width : 1 }
}
