import CoreText
import SwiftUI
import TrimlabModel

/// §4.5. v1's 300 px column, `--bg-1` with a hairline on its left: the selected clip's name and two meta lines ·
/// In, Out and "Clip 8.5 s" · the Reel total (44 px) with `of 3:00`, the clip count and the over-3:00 line · Remove
/// audio (A) and Loop Reel (\) · Export… (⌘E) pinned to the bottom. A one-clip Reel has no Clip row and no count:
/// its total sits under Out, as in v1.
///
/// `narrow` (a window under 1000 px, §4.11) is v1's 64 px row under the stage instead: the name, In and Out, the total
/// at 24 px, both switches without key hints, and Export… 140 px wide pinned right. The meta lines, the Clip row, the
/// count, the over-3:00 line, the keyframe hint and Locate… are left out of the row (UI addendum, "Narrow").
public struct InspectorView: View {
  let model: EditorModel
  let onExport: () -> Void
  let narrow: Bool

  /// `onExport`: Export… (Task 35 opens the sheet).
  public init(model: EditorModel, narrow: Bool = false, onExport: @escaping () -> Void = {}) {
    self.model = model
    self.narrow = narrow
    self.onExport = onExport
  }

  public static let width = Tokens.Layout.inspector
  /// The narrow row's height.
  public static let rowHeight: CGFloat = 64

  public var body: some View {
    if narrow { row } else { column }
  }

  private var exportButton: some View {
    TLPrimaryButton("Export…", key: "⌘E", action: onExport)
      .accessibilityIdentifier("export-button")
      .tlFocusID(EditorModel.sheetOpener)
  }

  private var column: some View {
    VStack(alignment: .leading, spacing: 0) {
      // A handle drag shows its draft live: In, Out, the clip's length and the total (Task 33).
      if let reel = model.draftReel ?? model.reel, let clip = primary(in: reel) {
        let one = reel.clips.count == 1
        info(clip)
          .padding(.bottom, 16)
        hairline
        times(clip, reel: reel, one: one)
          .padding(.vertical, 16)
        if !one {
          hairline
          total(reel)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        hairline
        switches(reel)
          .padding(.vertical, 16)
      }
      Spacer(minLength: 0)
      exportButton
    }
    .padding(EdgeInsets(top: 22, leading: 25, bottom: 24, trailing: 24))  // 24 inside the 1 px hairline
    .frame(width: Self.width)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Tokens.bg1)
    .overlay(alignment: .leading) { Rectangle().fill(Tokens.line).frame(width: 1) }
  }

  /// The narrow row (mockup `#narrow`): 20 px between sections, 20 px in from either side, a hairline on top.
  private var row: some View {
    HStack(spacing: 20) {
      if let reel = model.draftReel ?? model.reel, let clip = primary(in: reel) {
        Text(Self.clipName(clip))
          .font(.tl(.inter(.semibold), 15))
          .monospacedDigit()
          .foregroundStyle(Tokens.brandInk)
          .lineLimit(1)
          .truncationMode(.middle)
          .layoutPriority(-1)
        let fd = clip.facts.frameDuration
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          let waiting = Self.waiting(model.loading[clip.id])
          rowTime("In", Formatting.timecode(clip.inTime, frame: fd), waiting: waiting)
          rowTime("Out", Formatting.timecode(clip.outTime, frame: fd), waiting: waiting)
        }
        .fixedSize()
        rowTotal
        HStack(spacing: 18) {
          TLSwitch("Remove audio", isOn: reel.export.removeAudio, compact: true, action: model.toggleRemoveAudio)
          TLSwitch("Loop Reel", isOn: model.prefs.loop, compact: true, action: model.toggleLoop)
        }
        .fixedSize()
      }
      Spacer(minLength: 0)
      exportButton
        .frame(width: 140)
    }
    .padding(.horizontal, 20)
    .frame(maxWidth: .infinity)
    .frame(height: Self.rowHeight)
    .background(Tokens.bg1)
    .overlay(alignment: .top) { Rectangle().fill(Tokens.line).frame(height: 1) }
  }

  /// "In 0:01.21": the key 13 `--muted`, 6 px, the time 15/500.
  /// `waiting`: the dash in `--muted`, in the timecode's own width so the row doesn't shift when it arrives.
  private func rowTime(_ key: String, _ value: String, waiting: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(key)
        .font(.tl(.inter(.regular), 13))
        .foregroundStyle(Tokens.muted)
      Text(value)
        .font(.tl(.inter(.medium), 15))
        .monospacedDigit()
        .foregroundStyle(Tokens.text)
        .opacity(waiting ? 0 : 1)
        .overlay(alignment: .leading) {
          if waiting {
            Text(Self.dash)
              .font(.tl(.inter(.medium), 15))
              .foregroundStyle(Tokens.muted)
          }
        }
    }
  }

  /// The total at 24/28: the unit 4 px after it and `of 3:00` 6 px after that, both 14/500 `--muted`.
  private var rowTotal: some View {
    let (number, unit) = Self.totalParts(model.displayTotal)
    return HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(number)
        .font(.tl(.inter(.semibold), 24))
        .tracking(-0.02 * 24)
        .foregroundStyle(Self.totalInk(model))
      if let unit {
        Text(unit)
          .font(.tl(.inter(.medium), 14))
          .foregroundStyle(Tokens.muted)
          .padding(.leading, 4)
      }
      Text("of 3:00")
        .font(.tl(.inter(.medium), 14))
        .foregroundStyle(Tokens.muted)
        .padding(.leading, 6)
    }
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
    .frame(height: 28)
    .accessibilityElement(children: .combine)
  }

  private func primary(in reel: Reel) -> ReelClip? {
    reel.clips.first { $0.id == model.selection.primary } ?? reel.clips.first
  }

  private var hairline: some View { Rectangle().fill(Tokens.line).frame(height: 1) }

  // MARK: sections

  private func info(_ clip: ReelClip) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(Self.clipName(clip))
        .font(.tl(.inter(.semibold), 15))
        .monospacedDigit()  // the mockup's body is tabular-nums: file names too
        .foregroundStyle(Tokens.brandInk)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(height: 20)
        .padding(.bottom, 4)
      ForEach(Array(Self.meta(clip, state: model.loading[clip.id], missing: model.missing.contains(clip.id))
        .enumerated()), id: \.offset) { _, line in
        Text(line)
          .font(.tl(.inter(.regular), 12))
          .monospacedDigit()
          .foregroundStyle(Tokens.muted)
          .lineLimit(1)
          .frame(height: 17)
      }
      if model.missing.contains(clip.id) {
        TLButton("Locate…") { model.locate(clip.id) }
          .padding(.top, 10)
      }
    }
  }

  private func times(_ clip: ReelClip, reel: Reel, one: Bool) -> some View {
    let fd = clip.facts.frameDuration
    let waiting = Self.waiting(model.loading[clip.id])
    return VStack(alignment: .leading, spacing: 0) {
      row("In", waiting ? Self.dash : Formatting.timecode(clip.inTime, frame: fd), muted: waiting)
      if let hint = model.keyframeHint { keyframeHint(hint) }
      row("Out", waiting ? Self.dash : Formatting.timecode(clip.outTime, frame: fd), muted: waiting)
      if one {
        totalNumber(reel).padding(.top, 14)
        overLine  // no one-clip exception (Task 27 ruling)
      } else {
        row("Clip", waiting ? Self.dash : Formatting.clipLength(clip.trimmed), muted: waiting)
      }
    }
  }

  /// While a clip is probing or preparing its facts are the 1 s stand-in, not the file's: its In, Out and length
  /// read as a dash until they're real (critique, Task 38).
  static func waiting(_ state: LoadState?) -> Bool { state == .probing || state == .preparing }
  static let dash = "\u{2013}"

  /// The total's ink: `--warn` past 3:00, `--muted` while any clip is still loading (it counts their 1 s stand-ins),
  /// otherwise `--brand-ink`.
  static func totalInk(_ model: EditorModel) -> Color {
    if model.overLimit != nil { return Tokens.warn }
    return model.loadingClipIDs.isEmpty ? Tokens.brandInk : Tokens.muted
  }

  private func row(_ key: String, _ value: String, muted: Bool = false) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(key)
        .font(.tl(.inter(.regular), 13))
        .foregroundStyle(Tokens.muted)
        .frame(width: 40, alignment: .leading)
      Text(value)
        .font(.tl(.inter(.medium), 15))
        .monospacedDigit()
        .foregroundStyle(muted ? Tokens.muted : Tokens.text)
    }
    .frame(height: 24)
  }

  /// Quick only (v1 `#in-snap`): "starts at 3.00 s, keyframe" under In, 12/18 `--muted` after a 1 × 10 gold mark.
  private func keyframeHint(_ text: String) -> some View {
    HStack(spacing: 0) {
      Rectangle().fill(Tokens.brandGold).frame(width: 1, height: 10).padding(.leading, 1).padding(.trailing, 7)
      Text(text)
        .font(.tl(.inter(.regular), 12))
        .monospacedDigit()
        .foregroundStyle(Tokens.muted)
        .lineLimit(1)
    }
    .frame(height: 18)
    .padding(.leading, 40)
    .padding(.top, -2)
    .padding(.bottom, 2)
  }

  private func total(_ reel: Reel) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      totalNumber(reel)
      Text("\(reel.clips.count) clips")
        .font(.tl(.inter(.regular), 12))
        .monospacedDigit()
        .foregroundStyle(Tokens.muted)
        .frame(height: 17)
        .padding(.top, 2)
      overLine
    }
  }

  /// "Instagram Reels can be up to 3 minutes. Trim 0:12.4 more." in 12/17 `--warn`, 8 px down: Reel format only.
  @ViewBuilder private var overLine: some View {
    if let excess = model.overLimit {
      Text(Formatting.overLimitLine(excess))
        .font(.tl(.inter(.regular), 12))
        .monospacedDigit()
        .lineSpacing(2.5)
        .foregroundStyle(Tokens.warn)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
    }
  }

  /// The total's line box as the mockup lays it out: a 48 px line-height shared by the 44 px number and the 20 px
  /// unit and `of 3:00`, so the smaller text's half-leading grows the box to 57 px with the baseline 40 px down.
  static let totalLine: CGFloat = 57
  static let totalBaseline: CGFloat = 40

  /// "48.2 s of 3:00": the number 44/600 (`--warn` past 3:00), the unit and `of 3:00` 20/500 `--muted`.
  private func totalNumber(_ reel: Reel) -> some View {
    let total = model.displayTotal
    let (number, unit) = Self.totalParts(total)
    return HStack(alignment: .firstTextBaseline, spacing: 0) {
      Text(number)
        .font(.tl(.inter(.semibold), 44))
        .tracking(-0.02 * 44)
        .foregroundStyle(Self.totalInk(model))
      if let unit {
        Text(unit)
          .font(.tl(.inter(.medium), 20))
          .foregroundStyle(Tokens.muted)
          .padding(.leading, 4)
      }
      Text("of 3:00")
        .font(.tl(.inter(.medium), 20))
        .foregroundStyle(Tokens.muted)
        .padding(.leading, 10)
    }
    .monospacedDigit()
    .lineLimit(1)
    .fixedSize()
    .padding(.top, Self.totalBaseline - CTFontGetAscent(TLFont.inter(.semibold).ctFont(size: 44)))
    .frame(height: Self.totalLine, alignment: .topLeading)
    .accessibilityElement(children: .combine)
  }

  private func switches(_ reel: Reel) -> some View {
    VStack(spacing: 0) {
      TLSwitch("Remove audio", isOn: reel.export.removeAudio, key: "A", action: model.toggleRemoveAudio)
      TLSwitch("Loop Reel", isOn: model.prefs.loop, key: "\\", action: model.toggleLoop)
    }
  }

  // MARK: words

  /// The file name without its extension (`IMG_4821`).
  static func clipName(_ clip: ReelClip) -> String {
    URL(filePath: clip.source.absolutePath, directoryHint: .notDirectory).deletingPathExtension().lastPathComponent
  }

  /// "1080×1920, HEVC, 29.97 fps" / "23.6 s, HDR (HLG)"; "Missing"; "Loading…" while the facts are on their way.
  static func meta(_ clip: ReelClip, state: LoadState?, missing: Bool) -> [String] {
    if missing || state == .missing { return ["Missing"] }
    if state == .probing { return ["Loading…"] }
    if state == .preparing { return ["Preparing…"] }
    let f = clip.facts
    let hdr = switch f.hdr {
    case .sdr: ""
    case .hlg: ", HDR (HLG)"
    case .pq: ", HDR (PQ)"
    }
    return ["\(f.displayWidth)×\(f.displayHeight), \(codecName(f.videoCodec)), \(Formatting.fps(f.frameDuration)) fps",
            "\(Formatting.clipLength(f.duration))\(hdr)"]
  }

  static func codecName(_ codec: String) -> String {
    switch codec {
    case "hevc": "HEVC"
    case "h264": "H.264"
    case "prores": "ProRes"
    case "mpeg4": "MPEG-4"
    case "av1": "AV1"
    case "vp9": "VP9"
    case "mjpeg": "Motion JPEG"
    default: codec.uppercased()
    }
  }

  /// `29.97`, `30`, `23.98`: frames per second to two places, trailing zeros dropped.

  /// `("48.2", "s")`, or `("3:12.4", nil)` from a minute up.
  static func totalParts(_ t: RationalTime) -> (String, String?) {
    let text = Formatting.total(t)
    if let space = text.firstIndex(of: "\u{00A0}") {
      return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
    return (text, nil)
  }

}
