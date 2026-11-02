import CoreGraphics
import SwiftUI

/// The 56 px header (SPEC §6.0, §6.1): the v1 lockup, DCV logo × Coll Takes Chagrin | trimlab, then the Reel or
/// file name and `?` on the right; the Reel name (`reelName`) is a quiet button that turns into a field to rename
/// it. The whole header is the window's drag region; 78 px on the left clears the traffic lights. With no title (the
/// empty state) the name and `?` are hidden, as the addendum's #empty. `narrow` (a window under 1000 px) draws the
/// wordmark 200 px wide (v1 `#ctc{width:200px}`).
public struct HeaderView: View {
  let title: String?
  let reelName: ReelName?
  let logo: CGImage?
  let narrow: Bool
  let onHelp: () -> Void

  public init(title: String?, reelName: ReelName? = nil, logo: CGImage?, narrow: Bool = false,
              onHelp: @escaping () -> Void) {
    self.title = title
    self.reelName = reelName
    self.logo = logo
    self.narrow = narrow
    self.onHelp = onHelp
  }

  /// The Reel's name as the header edits it (§6.1): shown in place of `title` for a Reel of two or more clips.
  public struct ReelName {
    public var name: String
    /// The name is a field (`TLNameField`) rather than a button.
    public var editing: Bool
    /// `EditorModel.focusResetToken`: a press on the strip, deck or stage commits the field, as clicking away does.
    public var focusReset: Int
    public var begin: () -> Void
    /// Each edit in the field.
    public var edit: (String) -> Void
    /// Ends the field, keeping or dropping the draft; `keyboard`: Return or Esc (focus goes back with its ring).
    public var commit: (_ keyboard: Bool) -> Void
    public var cancel: (_ keyboard: Bool) -> Void

    public init(name: String, editing: Bool, focusReset: Int, begin: @escaping () -> Void,
                edit: @escaping (String) -> Void, commit: @escaping (_ keyboard: Bool) -> Void,
                cancel: @escaping (_ keyboard: Bool) -> Void) {
      self.name = name
      self.editing = editing
      self.focusReset = focusReset
      self.begin = begin
      self.edit = edit
      self.commit = commit
      self.cancel = cancel
    }
  }

  /// The DCV logo's height in points; callers rasterise `Logo.render` at this height.
  nonisolated public static let logoHeight: CGFloat = 46

  /// Values from `design/mockup.html` (v1's header verbatim).
  enum Metric {
    static let leadingInset: CGFloat = 78
    static let trailingInset: CGFloat = 16
    static let gap: CGFloat = 12
    static let lockupGap: CGFloat = 16
    static let logoHeight: CGFloat = HeaderView.logoHeight
    /// The CTC wordmark is SVG text: 40 px with .28em tracking, baseline y 44 in a 580×60 viewBox, drawn into a
    /// 270×28 box. It is laid out in viewBox units and scaled by 28/60, as the browser does.
    static let wordmarkSize: CGFloat = 40
    /// v1's web font is a static cut with no `smcp`, so the browser synthesises small caps: lower-case letters
    /// are capitals at 70 % (WebKit's multiplier), all from Bodoni's `opsz` 11 instance.
    static let wordmarkSmallCaps: CGFloat = 0.7
    static let wordmarkOpticalSize: CGFloat = 11
    static let wordmarkTracking: CGFloat = 0.28 * wordmarkSize
    static let wordmarkViewBox = CGSize(width: 580, height: 60)
    static let wordmarkBaseline: CGFloat = 44
    static let wordmarkBox = CGSize(width: 270, height: 28)
    /// Narrow: the SVG box is 200 × 28, so the viewBox is scaled to the width and centred in the height.
    static let narrowWordmarkWidth: CGFloat = 200
    static let appSize: CGFloat = 11
    static let appTracking: CGFloat = 0.22 * appSize
    /// `.app` has margin-left 14 on top of the lockup gap, then 16 px from its rule to the text.
    static let appMargin: CGFloat = 14
    static let appPadding: CGFloat = 16
    static let helpMargin: CGFloat = 8
  }

  public var body: some View {
    VStack(spacing: 0) {
      row.frame(height: Tokens.Layout.header - 1)
      Rectangle().fill(Tokens.line).frame(height: 1)
    }
    .frame(maxWidth: .infinity)
    .background(Tokens.bg0)
    .contentShape(Rectangle())
    .modifier(WindowDrag())
  }

  private var row: some View {
    HStack(spacing: Metric.gap) {
      lockup
      Spacer(minLength: 0)
      if let title {
        if let reelName { nameControl(reelName) } else { titleText(title) }
        TLIconButton(.text("?"), size: .ring, label: "Help", tip: "Keys and what is on this screen (?)",
                     tipPlacement: TLTipPlacement(.below, align: .trailing), action: onHelp)
          .tlFocusID(EditorModel.helpControl)
          .padding(.leading, Metric.helpMargin)
      }
    }
    .padding(.leading, Metric.leadingInset)
    .padding(.trailing, Metric.trailingInset)
  }

  private func titleText(_ title: String) -> some View {
    Text(title)
      .font(.tl(.inter(.medium), 13))
      .monospacedDigit()
      .foregroundStyle(Tokens.text)
      .lineLimit(1)
      .truncationMode(.tail)
      .frame(height: 28)
  }

  /// The Reel name: a bare button in the title's type (a click, or Return or Space with keyboard focus, edits it),
  /// or while editing the field, which commits on Return or when focus leaves and cancels on Esc.
  @ViewBuilder private func nameControl(_ reelName: ReelName) -> some View {
    if reelName.editing {
      TLNameField("Reel name", value: reelName.name, focusReset: reelName.focusReset, onEdit: reelName.edit,
                  onCommit: reelName.commit, onCancel: reelName.cancel)
        .tlFocusID(EditorModel.reelNameField)
        .accessibilityIdentifier(EditorModel.reelNameControl)
    } else {
      TLButton(style: .bare, label: "Reel name", tip: "Rename the Reel",
               tipPlacement: TLTipPlacement(.below, align: .trailing), action: reelName.begin) {
        titleText(reelName.name)
      }
      .tlFocusID(EditorModel.reelNameControl)
      .accessibilityValue(reelName.name)
      .accessibilityHint("Renames the Reel and its file")
      .accessibilityIdentifier(EditorModel.reelNameControl)
    }
  }

  private var lockup: some View {
    HStack(spacing: Metric.lockupGap) {
      logoImage
      Text("×")
        .font(.tl(.inter(.regular), 15))
        .foregroundStyle(Tokens.muted)
        .opacity(0.6)
      wordmark
      appName
    }
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("DCV Applied Technology × Coll Takes Chagrin, trimlab")
  }

  @ViewBuilder private var logoImage: some View {
    if let logo {
      Image(decorative: logo, scale: 1)
        .resizable()
        .interpolation(.high)
        .aspectRatio(contentMode: .fit)
        .frame(height: Metric.logoHeight)
    } else {
      // Reserve the logo's rect so nothing shifts (its PDF is 2:1).
      Color.clear.frame(width: Metric.logoHeight * 2, height: Metric.logoHeight)
    }
  }

  /// Bodoni Moda 500 small caps, the baseline where the SVG puts it (y 44 of 60).
  private var wordmark: some View {
    let box = Metric.wordmarkBox
    let view = Metric.wordmarkViewBox
    // The SVG's "meet": the viewBox scaled to fit the box, centred where it doesn't fill it.
    let width = narrow ? Metric.narrowWordmarkWidth : box.width
    let scale = narrow ? width / view.width : box.height / view.height
    let drop = (box.height - view.height * scale) / 2
    return smallCaps("Coll Takes Chagrin")
      .tracking(Metric.wordmarkTracking)
      .foregroundStyle(Tokens.brandInk)
      .fixedSize()
      .alignmentGuide(.top) { $0[.firstTextBaseline] - Metric.wordmarkBaseline }
      .frame(width: view.width, height: view.height, alignment: .topLeading)
      .scaleEffect(scale, anchor: .topLeading)
      .offset(y: drop)
      .frame(width: width, height: box.height, alignment: .topLeading)
  }

  /// Synthesised small caps: capitals at full size, lower case as capitals at 70 %.
  private func smallCaps(_ string: String) -> Text {
    let face = TLFont.bodoni(italic: false, weight: 500)
    let full = Font.tl(face, Metric.wordmarkSize, opticalSize: Metric.wordmarkOpticalSize)
    let small = Font.tl(face, Metric.wordmarkSize * Metric.wordmarkSmallCaps, opticalSize: Metric.wordmarkOpticalSize)
    var runs: [(text: String, small: Bool)] = []
    for ch in string {
      let isSmall = ch.isLowercase
      let piece = isSmall ? ch.uppercased() : String(ch)
      if let last = runs.last, last.small == isSmall { runs[runs.count - 1].text += piece } else { runs.append((piece, isSmall)) }
    }
    var attributed = AttributedString()
    for run in runs {
      var piece = AttributedString(run.text)
      piece.font = run.small ? small : full
      attributed += piece
    }
    return Text(attributed)
  }

  /// "trimlab" after a 1 px rule (the owner: the header says "trimlab", not "trimlab 2").
  private var appName: some View {
    HStack(spacing: 0) {
      Rectangle().fill(Tokens.line).frame(width: 1, height: Metric.wordmarkBox.height)
      Text("trimlab")
        .font(.tl(.inter(.regular), Metric.appSize))
        .tracking(Metric.appTracking)
        .foregroundStyle(Tokens.muted)
        .padding(.leading, Metric.appPadding)
    }
    .padding(.leading, Metric.appMargin)
  }
}

/// The header drags the window (`WindowDragGesture` is macOS-only, F32).
private struct WindowDrag: ViewModifier {
  func body(content: Content) -> some View {
    #if os(macOS)
    content.gesture(WindowDragGesture())
    #else
    content
    #endif
  }
}
