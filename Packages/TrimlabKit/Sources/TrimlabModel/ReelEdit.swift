import Foundation

/// §3.3. Every change to a Reel is one of these, applied by the pure `apply(_:to:)`.
public enum ReelEdit: Equatable, Sendable {
  case insert([ReelClip], at: Int), move(Set<UUID>, toGap: Int), delete(Set<UUID>), split(UUID, atSource: RationalTime)
  case setIn(UUID, RationalTime), setOut(UUID, RationalTime), resetIn(UUID), resetOut(UUID)
  case setJoin(UUID, Join), setFraming(Set<UUID>, Framing), setRemoveAudio(Bool), setExport(ExportSpec)
  case relink(UUID, SourceRef, ClipFacts), rename(String)
  /// A probe result arriving for a tile added with placeholder facts (Phase 2 review ruling). The editor applies it
  /// with `record: false`, so it is never an undo step. An id no longer in the Reel leaves the Reel unchanged.
  case probed(UUID, ClipFacts)
}

public enum EditError: Error, Equatable {
  case spanTooShort, crossesHandle, splitTooCloseToEdge, unknownClip, emptyInsert
  /// The clips' times mix timescales the plan can't hold exactly (`TimeBounds.reelIsSane`); the Reel is unchanged.
  case unsupportedTiming
}

/// Pure: returns the edited Reel, or throws and leaves the caller's Reel as it was.
public func apply(_ e: ReelEdit, to r: Reel) throws(EditError) -> Reel {
  var reel = r
  switch e {
  case .setIn(let id, let t):
    let i = try index(of: id, in: reel)
    reel.clips[i].inTime = try TrimRules.newIn(t, for: reel.clips[i])
  case .setOut(let id, let t):
    let i = try index(of: id, in: reel)
    reel.clips[i].outTime = try TrimRules.newOut(t, for: reel.clips[i])
  case .resetIn(let id):
    let i = try index(of: id, in: reel)
    reel.clips[i].inTime = try TrimRules.newIn(.zero, for: reel.clips[i])
  case .resetOut(let id):
    let i = try index(of: id, in: reel)
    reel.clips[i].outTime = try TrimRules.newOut(reel.clips[i].facts.duration, for: reel.clips[i])
  case .insert(let clips, let at):
    guard !clips.isEmpty else { throw .emptyInsert }
    reel.clips.insert(contentsOf: clips, at: min(max(at, 0), reel.clips.count))
    try requireSaneTiming(reel)
  case .move(let ids, let gap):
    try requireKnown(ids, in: reel)
    let g = min(max(gap, 0), reel.clips.count)
    let moving = reel.clips.filter { ids.contains($0.id) }
    let before = reel.clips[..<g].filter { ids.contains($0.id) }.count
    reel.clips.removeAll { ids.contains($0.id) }
    reel.clips.insert(contentsOf: moving, at: g - before)
  case .delete(let ids):
    try requireKnown(ids, in: reel)
    reel.clips.removeAll { ids.contains($0.id) }
  case .split(let id, let t):
    let i = try index(of: id, in: reel)
    let (a, b) = try TrimRules.split(reel.clips[i], at: t)
    reel.clips.replaceSubrange(i...i, with: [a, b])
  case .setJoin(let id, let join):
    let i = try index(of: id, in: reel)
    reel.clips[i].join = join.snapped
    try requireSaneTiming(reel)
  case .setFraming(let ids, let framing):
    try requireKnown(ids, in: reel)
    for i in reel.clips.indices where ids.contains(reel.clips[i].id) { reel.clips[i].framing = framing }
  case .setRemoveAudio(let on):
    reel.export.removeAudio = on
  case .setExport(let spec):
    reel.export = spec
  case .relink(let id, let source, let facts):
    let i = try index(of: id, in: reel)
    reel.clips[i] = TrimRules.relinked(reel.clips[i], source: source, facts: facts)
    try requireSaneTiming(reel)
  case .rename(let name):
    reel.name = name
  case .probed(let id, let facts):
    guard let i = reel.index(of: id) else { return r }
    reel.clips[i] = TrimRules.probed(reel.clips[i], facts: facts)
    try requireSaneTiming(reel)
  }
  return reel
}

private func index(of id: UUID, in reel: Reel) throws(EditError) -> Int {
  guard let i = reel.index(of: id) else { throw .unknownClip }
  return i
}

/// Phase 2 review ruling: an edit that brings in new times must leave a Reel the plan can hold exactly.
private func requireSaneTiming(_ reel: Reel) throws(EditError) {
  guard TimeBounds.reelIsSane(reel.clips) else { throw .unsupportedTiming }
}

/// Set edits ignore unknown ids as long as one id is known.
private func requireKnown(_ ids: Set<UUID>, in reel: Reel) throws(EditError) {
  guard reel.clips.contains(where: { ids.contains($0.id) }) else { throw .unknownClip }
}

/// The clip with In and Out brought back inside the trim rules, for files that didn't come through `apply`
/// (hand-edited, or written by an older build). Used by `ProjectCodec.decode`.
func sanitised(_ clip: ReelClip) -> ReelClip { TrimRules.sanitised(clip) }

extension Join {
  /// Ruling (Phase 2 review): v2 has only Short and Long, so a crossfade snaps to the nearer of the two (exactly
  /// halfway takes Short); zero or negative is a cut. Only exact comparisons, so any value is safe. Used on load and
  /// by `.setJoin`.
  var snapped: Join {
    guard case .crossfade(let t) = self else { return self }
    if t <= .zero { return .cut }
    return .crossfade(t <= (Limits.shortFade + Limits.longFade).halved() ? Limits.shortFade : Limits.longFade)
  }
}

extension Reel {
  /// Position of the clip with this id, or nil.
  public func index(of id: UUID) -> Int? { clips.firstIndex { $0.id == id } }
}

/// §4.4 / §7.1: frame-aligned, clamped, handles never cross, span ≥ min(0.5 s, clip duration).
private enum TrimRules {
  static func required(for clip: ReelClip) -> RationalTime { min(Limits.minSpan, clip.facts.duration) }

  /// Floors to a frame start, then clamps into [0, duration]. Duration itself is allowed even off the grid.
  static func snap(_ t: RationalTime, _ clip: ReelClip) -> RationalTime {
    let duration = clip.facts.duration
    if t >= duration { return duration }
    if t <= .zero { return .zero }
    return min(max(floor(t, clip), .zero), duration)
  }

  /// Floors to a frame start; a frame duration that isn't positive means no grid, so the time is kept as is.
  static func floor(_ t: RationalTime, _ clip: ReelClip) -> RationalTime {
    let fd = clip.facts.frameDuration
    return fd.value > 0 && fd.timescale > 0 ? t.floored(toFrame: fd) : t
  }

  /// §4.3.4: A = [In, t), B = [t, Out) with t floored to a frame; both halves ≥ `Limits.splitEdge`.
  /// Out may be off the frame grid, so nothing here assumes a whole number of frames.
  static func split(_ clip: ReelClip, at t: RationalTime) throws(EditError) -> (ReelClip, ReelClip) {
    let cut = floor(t, clip)
    guard cut - clip.inTime >= Limits.splitEdge, clip.outTime - cut >= Limits.splitEdge else {
      throw .splitTooCloseToEdge
    }
    var a = clip, b = clip
    a.outTime = cut
    b.id = UUID()
    b.inTime = cut
    b.join = .cut
    return (a, b)
  }

  /// Swaps source and facts. Out is clamped to the new duration; if that leaves less than the minimum span,
  /// In is pulled back (to a frame start) to restore it.
  static func relinked(_ clip: ReelClip, source: SourceRef, facts: ClipFacts) -> ReelClip {
    var c = clip
    c.source = source
    c.facts = facts
    c.outTime = min(c.outTime, max(facts.duration, .zero))
    let latestIn = c.outTime - required(for: c)
    if c.inTime > latestIn { c.inTime = max(floor(latestIn, c), .zero) }
    return c
  }

  /// A clip still at its placeholder trim (In 0, Out = the placeholder duration) takes the whole probed source;
  /// any other trim is kept and clamped to the probed duration as `relinked` does.
  static func probed(_ clip: ReelClip, facts: ClipFacts) -> ReelClip {
    guard clip.inTime == .zero, clip.outTime == clip.facts.duration else {
      return relinked(clip, source: clip.source, facts: facts)
    }
    var c = clip
    c.facts = facts
    c.outTime = max(facts.duration, .zero)
    return c
  }

  /// Load-time repair (P17): In and Out snapped and clamped as a set would; a span below the minimum keeps Out
  /// and pulls In back (as `relinked` does); crossed handles, or no room to pull back, reset to the whole source.
  static func sanitised(_ clip: ReelClip) -> ReelClip {
    var c = clip
    c.inTime = snap(c.inTime, c)
    c.outTime = snap(c.outTime, c)
    if c.inTime < c.outTime, c.outTime - c.inTime >= required(for: c) { return c }
    if c.inTime < c.outTime, c.outTime >= required(for: c) { return relinked(c, source: c.source, facts: c.facts) }
    c.inTime = .zero
    c.outTime = max(c.facts.duration, .zero)
    return c
  }

  static func newIn(_ t: RationalTime, for clip: ReelClip) throws(EditError) -> RationalTime {
    let value = snap(t, clip)
    if value >= clip.outTime { throw .crossesHandle }
    if clip.outTime - value < required(for: clip) { throw .spanTooShort }
    return value
  }

  static func newOut(_ t: RationalTime, for clip: ReelClip) throws(EditError) -> RationalTime {
    let value = snap(t, clip)
    if value <= clip.inTime { throw .crossesHandle }
    if value - clip.inTime < required(for: clip) { throw .spanTooShort }
    return value
  }
}
