import Foundation

/// §5.1. Pure and deterministic: turns a Reel's edit list into a timed `CompositionPlan`.
public enum Planner {
  /// Output size for the Reel format.
  public static let reelSize = PixelSize(width: 1080, height: 1920)

  /// Nominal frame durations the Reel rate snaps to, lowest rate first (23.976 … 60).
  static let nominalRates: [RationalTime] = [
    RationalTime(1001, 24000), RationalTime(1, 24), RationalTime(1, 25), RationalTime(1001, 30000),
    RationalTime(1, 30), RationalTime(1, 50), RationalTime(1001, 60000), RationalTime(1, 60),
  ]

  /// Used only when no clip is left to take a rate from.
  static let fallbackFrameDuration = RationalTime(1001, 30000)

  /// `missing`: clips whose source can't be found; they are left out, and the clips either side of them meet
  /// directly (the join into the next present clip applies against the previous present clip).
  public static func plan(_ r: Reel, missing: Set<UUID> = []) -> CompositionPlan {
    let present = r.clips.indices.filter { !missing.contains(r.clips[$0].id) }
    let clips = present.map { r.clips[$0] }

    var placements: [Placement] = []
    placements.reserveCapacity(clips.count)
    var end = RationalTime.zero
    for (k, clip) in clips.enumerated() {
      let fade = effectiveFade(into: k, in: clips)
      let start = end - fade
      placements.append(Placement(clipID: clip.id, index: present[k], track: k % 2,
                                  reelSpan: TimeSpan(start: start, duration: clip.trimmed),
                                  sourceIn: clip.inTime, fadeIn: fade))
      end = start + clip.trimmed
    }
    let total = placements.last?.reelSpan.end ?? .zero

    return CompositionPlan(
      placements: placements,
      segments: segments(placements, framings: clips.map(\.framing)),
      total: total,
      frameDuration: clips.isEmpty ? fallbackFrameDuration : frameDuration(for: clips),
      renderSize: renderSize(r.export.format, first: clips.first),
      audioRamps: audioRamps(placements),
      hasAudioOut: !r.export.removeAudio && clips.contains { $0.facts.hasAudio },
      hdrOut: !r.export.convertHDR && clips.contains { $0.facts.hdr != .sdr })
  }

  /// §4.3.4: `min(chosen, ½ × shorter neighbour's trimmed length)`, exact (F7: not floored to a frame).
  /// `.zero` for a cut, for index 0, and for an index outside `clips`.
  public static func effectiveFade(into index: Int, in clips: [ReelClip]) -> RationalTime {
    guard index > 0, index < clips.count, case .crossfade(let chosen) = clips[index].join else { return .zero }
    let half = min(clips[index - 1].trimmed, clips[index].trimmed).halved()
    return max(min(chosen, half), .zero)
  }

  /// §5.1: one clip keeps its own rate; otherwise each rate snaps to the nearest nominal rate (≤ 60), and the
  /// one covering the most trimmed time wins, ties to the lower rate.
  public static func frameDuration(for clips: [ReelClip]) -> RationalTime {
    if clips.count == 1, isPositive(clips[0].facts.frameDuration) { return clips[0].facts.frameDuration }
    var weight = [RationalTime](repeating: .zero, count: nominalRates.count)
    for clip in clips where isPositive(clip.facts.frameDuration) {
      let i = nearestNominal(to: clip.facts.frameDuration)
      weight[i] = weight[i] + clip.trimmed
    }
    // nominalRates runs lowest rate first, so a strict ">" keeps the lower rate on a tie.
    var best: Int?
    for i in weight.indices where weight[i] > .zero && (best.map { weight[i] > weight[$0] } ?? true) { best = i }
    return best.map { nominalRates[$0] } ?? fallbackFrameDuration
  }

  // MARK: private

  private static func isPositive(_ t: RationalTime) -> Bool { t.value > 0 && t.timescale > 0 }

  /// Index into `nominalRates` of the closest rate in fps; a rate exactly between two takes the lower one.
  private static func nearestNominal(to fd: RationalTime) -> Int {
    let fps = Double(fd.timescale) / Double(fd.value)
    var best = 0
    for i in nominalRates.indices {
      let r = nominalRates[i], b = nominalRates[best]
      if abs(Double(r.timescale) / Double(r.value) - fps) < abs(Double(b.timescale) / Double(b.value) - fps) {
        best = i
      }
    }
    return best
  }

  /// All placement starts and ends cut `[0, total)`; each interval lists its active placements, earlier
  /// (outgoing) first. In a two-layer interval the outgoing layer fades out across it (F2).
  private static func segments(_ placements: [Placement], framings: [Framing]) -> [PlanSegment] {
    let cuts = Array(Set(placements.flatMap { [$0.reelSpan.start, $0.reelSpan.end] })).sorted()
    var out: [PlanSegment] = []
    out.reserveCapacity(max(cuts.count - 1, 0))
    var first = 0  // earliest placement that may still be active; placements are sorted by start and by end
    for (a, b) in zip(cuts, cuts.dropFirst()) {
      while first < placements.count, placements[first].reelSpan.end <= a { first += 1 }
      var active: [Int] = []
      var p = first
      while p < placements.count, placements[p].reelSpan.start <= a {
        if placements[p].reelSpan.end >= b { active.append(p) }
        p += 1
      }
      let fading = active.count > 1
      let layers = active.enumerated().map { pos, p in
        LayerSpec(placement: p, framing: framings[p], opacity: fading && pos == 0 ? 0...1 : nil)
      }
      out.append(PlanSegment(span: TimeSpan(start: a, duration: b - a), layers: layers))
    }
    return out
  }

  /// A crossfade ramps the outgoing track 1 → 0 and the incoming 0 → 1 over the overlap.
  private static func audioRamps(_ placements: [Placement]) -> [AudioRamp] {
    var ramps: [AudioRamp] = []
    for (prev, p) in zip(placements, placements.dropFirst()) where p.fadeIn > .zero {
      let span = TimeSpan(start: p.reelSpan.start, duration: p.fadeIn)
      ramps.append(AudioRamp(track: prev.track, span: span, from: 1, to: 0))
      ramps.append(AudioRamp(track: p.track, span: span, from: 0, to: 1))
    }
    return ramps
  }

  /// Reel: 1080×1920. Original: the first clip's display size rounded down to even (Reel size with no clips).
  private static func renderSize(_ format: ExportSpec.Format, first: ReelClip?) -> PixelSize {
    guard format == .original, let f = first?.facts else { return reelSize }
    return PixelSize(width: f.displayWidth & ~1, height: f.displayHeight & ~1)
  }
}

extension Reel {
  /// §4.3.6: Σ trimmed − Σ effective crossfades, leaving out `missing` clips exactly as `Planner.plan` does.
  public func total(missing: Set<UUID>) -> RationalTime { Planner.plan(self, missing: missing).total }

  /// How far the total (without `missing` clips) runs past `limit`, or nil when it doesn't (exactly the limit is
  /// not over).
  public func overLimit(by limit: RationalTime = Limits.reelMax, missing: Set<UUID>) -> RationalTime? {
    let t = total(missing: missing)
    return t > limit ? t - limit : nil
  }
}
