import Foundation
import Testing
@testable import TrimlabModel

@Suite struct ImportOrderTests {
  static func at(_ hour: Int, _ minute: Int = 0) -> Date {
    Date(timeIntervalSinceReferenceDate: 783_000_000 + Double(hour * 3600 + minute * 60))
  }

  static func item(_ name: String, capture: Date? = nil, created: Date? = nil) -> ImportItem {
    ImportItem(url: URL(fileURLWithPath: "/clips/\(name)"), captureDate: capture, fileCreated: created)
  }

  static func names(_ items: [ImportItem]) -> [String] { items.map(\.url.lastPathComponent) }

  @Test func captureDateThenNaturalName() {
    let items = [
      Self.item("IMG_10.MOV", capture: Self.at(9)),
      Self.item("IMG_2.MOV", capture: Self.at(9)),
      Self.item("IMG_3.MOV", capture: Self.at(8)),
      Self.item("noDate.MOV"),
    ]
    #expect(Self.names(ImportOrder.sorted(items)) == ["IMG_3.MOV", "IMG_2.MOV", "IMG_10.MOV", "noDate.MOV"])
  }

  @Test func fileCreationDateStandsInForAMissingCaptureDate() {
    // F30: one date key per item = captureDate ?? fileCreated.
    let items = [
      Self.item("A.MOV", capture: Self.at(10), created: Self.at(7)),
      Self.item("B.MOV", created: Self.at(9)),
      Self.item("C.MOV", capture: Self.at(8), created: Self.at(11)),
    ]
    #expect(Self.names(ImportOrder.sorted(items)) == ["C.MOV", "B.MOV", "A.MOV"])
  }

  @Test func undatedItemsComeLastInNaturalOrder() {
    let items = [
      Self.item("clip 10.mov"), Self.item("clip 9.mov"), Self.item("Z.mov", created: Self.at(23)),
      Self.item("clip 1.mov"),
    ]
    #expect(Self.names(ImportOrder.sorted(items)) == ["Z.mov", "clip 1.mov", "clip 9.mov", "clip 10.mov"])
  }

  @Test func sameNameAndDateKeepDropOrder() {
    let a = ImportItem(url: URL(fileURLWithPath: "/one/IMG_1.MOV"), captureDate: Self.at(9), fileCreated: nil)
    let b = ImportItem(url: URL(fileURLWithPath: "/two/IMG_1.MOV"), captureDate: Self.at(9), fileCreated: nil)
    #expect(ImportOrder.sorted([a, b]).map(\.url) == [a.url, b.url])
    #expect(ImportOrder.sorted([b, a]).map(\.url) == [b.url, a.url])
  }

  @Test func emptyBatch() {
    #expect(ImportOrder.sorted([]).isEmpty)
  }
}
