import Testing
@testable import TrimlabModel

@Suite struct ModelSmokeTests {
  @Test func moduleLinks() {
    #expect(String(describing: TrimlabModelModule.self) == "TrimlabModelModule")
  }
}
