import Testing
@testable import TrimlabMedia

@Suite struct MediaSmokeTests {
  @Test func moduleLinks() {
    #expect(String(describing: TrimlabMediaModule.self) == "TrimlabMediaModule")
  }

  /// M8: the app warms the GPU off the main actor; the LUT pipeline and the compositor share one Metal device,
  /// so the LUT kernel's device check holds for every context the module makes.
  @Test func warmupBuildsTheGPUOnOneDevice() async throws {
    await MediaWarmup.prepare()
    let device = try #require(HDRToSDR.device)
    let gpu = try #require(HDRToSDR.gpu)
    #expect(gpu.device === device)
  }
}
