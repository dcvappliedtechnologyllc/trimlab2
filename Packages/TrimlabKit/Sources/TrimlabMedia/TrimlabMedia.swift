public enum TrimlabMediaModule {}

/// For the app at launch: builds the GPU state the first preview frame and the first HDR clip need (the Metal
/// device, the HDR → SDR LUT pipeline and textures, the compositor's Core Image context), off the main actor.
public enum MediaWarmup {
  @concurrent
  public static func prepare() async {
    let gpu = HDRToSDR.gpu
    _ = ReelCompositor.context
    MediaLog.note("warmup: GPU \(HDRToSDR.device?.name ?? "none"), HDR LUT \(gpu == nil ? "unavailable" : "ready")")
  }
}
