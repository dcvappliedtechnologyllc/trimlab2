import Foundation
import TrimlabModel

/// The caption's three-way join control (§4.3.4): Cut, Short (0.25 s) or Long (1 s).
public enum JoinChoice: Hashable, Sendable, CaseIterable {
  case cut, short, long

  /// The control's segment for a stored join: any crossfade up to Short reads as Short, longer as Long (the same
  /// split as the strip's click cycle).
  public init(_ join: Join) {
    switch join {
    case .cut: self = .cut
    case .crossfade(let t): self = t <= Limits.shortFade ? .short : .long
    }
  }

  public var join: Join {
    switch self {
    case .cut: .cut
    case .short: .crossfade(Limits.shortFade)
    case .long: .crossfade(Limits.longFade)
    }
  }
}

/// §4.4. What the deck's caption row shows for the primary clip; nil-valued controls are hidden.
public struct CaptionModel: Equatable, Sendable {
  /// The file name without its extension (`IMG_4821`).
  public var name: String
  /// "clip 4 of 18"; nil for a one-clip Reel.
  public var position: String?
  /// "4 clips selected"; nil unless more than one clip is selected.
  public var selected: String?
  /// The primary's framing: shown only for a primary that isn't 9:16, in Reel format, with its real facts in.
  public var framing: Framing?
  /// The join into the primary: hidden (nil) on the first clip.
  public var join: JoinChoice?
  /// The join control's tooltip, with the effective length.
  public var joinTip: String?

  /// "Cut", "Crossfade, 1 s", or "Crossfade, 0.6 s (clip is short)" when the effective fade is below the chosen one
  /// (§4.3.4) and reads so once rounded (`Formatting.fade`).
  public static func joinTooltip(_ chosen: Join, effective: RationalTime) -> String {
    guard case .crossfade(let length) = chosen, effective > .zero else { return "Cut" }
    let shown = Formatting.fade(min(effective, length))
    // "Short" only when it reads short: 0.995 s of a 1 s fade rounds to "1 s" and says nothing more.
    return shown == Formatting.fade(length) ? "Crossfade, \(shown)" : "Crossfade, \(shown) (clip is short)"
  }

  /// The names `controlFocus` takes for the caption's two controls.
  public static let joinControl = "caption.join"
  public static let framingControl = "caption.framing"
}

/// §4.4, §4.3.4. The caption row's model side: what it shows, and its two controls' intents. The controls act as
/// F and X do: Framing on the whole selection, the join on the primary.
extension EditorModel {
  /// The caption for the primary clip, from the draft during a handle drag; nil without one.
  public var caption: CaptionModel? {
    guard let shown = draftReel ?? reel, let id = selection.primary, let i = shown.index(of: id) else { return nil }
    let clip = shown.clips[i]
    let count = shown.clips.count
    let waiting = placeholderClipIDs
    var out = CaptionModel(
      name: InspectorView.clipName(clip),
      position: count > 1 ? "clip \(i + 1) of \(count)" : nil,
      selected: selection.all.count > 1 ? "\(selection.all.count) clips selected" : nil)
    let portrait = clip.facts.displayWidth * 16 == clip.facts.displayHeight * 9
    if shown.export.format == .reel, !portrait, !waiting.contains(id) { out.framing = clip.framing }
    if i > 0 {
      out.join = JoinChoice(clip.join)
      // Placeholder facts (a 1 s tile) would halve a Long fade that isn't really short: show the chosen length.
      let known = !waiting.contains(id) && !waiting.contains(shown.clips[i - 1].id)
      let effective: RationalTime
      if known {
        effective = Planner.effectiveFade(into: i, in: shown.clips)
      } else if case .crossfade(let t) = clip.join {
        effective = t
      } else {
        effective = .zero
      }
      out.joinTip = CaptionModel.joinTooltip(clip.join, effective: effective)
    }
    return out
  }

  /// "Crossfade in": the join into the primary clip. Choosing what is already chosen records nothing.
  public func captionSetJoin(_ choice: JoinChoice) {
    guard let reel, let id = selection.primary, let i = reel.index(of: id), i > 0,
          reel.clips[i].join != choice.join
    else { return }
    perform(.setJoin(id, choice.join), coalesce: nil)
  }

  /// "Framing": the whole selection takes `framing` (as F does). Nothing when every selected clip has it already.
  public func captionSetFraming(_ framing: Framing) {
    guard let reel, !selection.all.isEmpty,
          reel.clips.contains(where: { selection.all.contains($0.id) && $0.framing != framing })
    else { return }
    perform(.setFraming(selection.all, framing), coalesce: nil)
  }

  /// A control that takes plain ← / → while it has keyboard focus (`TLSegmented`) reports it here, by a name of its
  /// own, so the key monitor passes those arrows on to it instead of stepping the playhead.
  public func controlFocus(_ name: String, focused: Bool) {
    if focused { arrowControls.insert(name) } else { arrowControls.remove(name) }
  }

  /// A press on the strip, the deck or the stage: keyboard focus leaves the caption's controls (they watch
  /// `focusResetToken`) and the control a closed modal gave it back to (`focusedControl`), and the arrows are the
  /// playhead's again at once.
  public func pointerPressed() {
    arrowControls.removeAll()
    focusResetToken &+= 1
    if modals.top == nil { focusedControl = nil }  // a control a modal handed focus back to lets it go (Task 37)
  }

  /// Whether a focused control should get plain ← / → now: one is on screen (a hidden caption control's name is
  /// dropped), and no handle or strip press is held.
  var arrowsToControl: Bool {
    guard !arrowControls.isEmpty else { return false }
    let shown = caption
    arrowControls = arrowControls.filter { name in
      switch name {
      case CaptionModel.joinControl: shown?.join != nil
      case CaptionModel.framingControl: shown?.framing != nil
      default: true
      }
    }
    return !arrowControls.isEmpty && deckGrab == nil && stripPressed == nil
  }
}
