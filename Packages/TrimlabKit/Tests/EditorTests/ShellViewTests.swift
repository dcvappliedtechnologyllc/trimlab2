import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import TrimlabEditor

/// Task 7: the window shell (header lockup, empty state) and the DCV logo.
@MainActor @Suite struct ShellViewTests {
  static let logoPDF = SourceScan.repoRoot / "Resources/Assets/dcv-logo-white.pdf"
  static let window = CGSize(width: 1240, height: 860)

  init() { FontRegistry.registerBundled(from: SourceScan.repoRoot / "Resources/Fonts") }

  // MARK: logo

  @Test func logoRendersAtBackingScale() throws {
    let at1 = try #require(Logo.render(pdf: Self.logoPDF, height: 46, scale: 1))
    let at2 = try #require(Logo.render(pdf: Self.logoPDF, height: 46, scale: 2))
    #expect(at1.height == 46 && at1.width == 92)  // the PDF page is 200×100 pt
    #expect(at2.height == 92 && at2.width == 184)
    let px = try pixels(at2)
    let opaque = stride(from: 3, to: px.count, by: 4).filter { px[$0] > 200 }
    #expect(opaque.count > 1000, "the logo drew almost nothing")
    // White artwork on a transparent page: premultiplied, so every pixel's RGB equals its alpha.
    let white = stride(from: 3, to: px.count, by: 4).allSatisfy { a in
      (1...3).allSatisfy { abs(Int(px[a - $0]) - Int(px[a])) <= 2 }
    }
    #expect(white, "the logo has non-white pixels")
    #expect(px[3] == 0, "the page background must stay transparent")
  }

  @Test func logoMissingFileIsNil() {
    let gone = FileManager.default.temporaryDirectory.appendingPathComponent("no-\(UUID().uuidString).pdf")
    #expect(Logo.render(pdf: gone, height: 46, scale: 2) == nil)
  }

  // MARK: tabular figures (Task 5 carry)

  /// `monospacedDigit()` must reach the CTFont-backed `Font.tl`: Inter's default figures are proportional.
  @Test func monospacedDigitIsTabularOnTLFont() throws {
    func width(_ s: String, tabular: Bool) throws -> Int {
      let text = Text(s).font(.tl(.inter(.semibold), 44))
      let view = Group { if tabular { text.monospacedDigit() } else { text } }.fixedSize()
      let renderer = ImageRenderer(content: view)
      renderer.scale = 4
      return try #require(renderer.cgImage).width
    }
    #expect(try width("1111", tabular: false) != width("0000", tabular: false), "proportional baseline is vacuous")
    #expect(try width("1111", tabular: true) == width("0000", tabular: true))
    #expect(try width("1:11.1", tabular: true) == width("0:00.0", tabular: true))
  }

  // MARK: screens

  @Test func emptyStateRendersOnBg0() throws {
    let image = try render(RootView(model: Harness().model, logo: logo(scale: 2)) { _ in Color.clear }, size: Self.window, scale: 2)
    #expect(image.width == 2480 && image.height == 1720)
    let px = try pixels(image)
    let bg0: [UInt8] = [0x0B, 0x0C, 0x0E]
    #expect(rgb(px, image, x: 20, y: 20) == bg0)  // header, behind the traffic lights
    #expect(rgb(px, image, x: 1200, y: 1600) == bg0)  // stage
    #expect(rgb(px, image, x: 1200, y: 111) == [0x2A, 0x2E, 0x36])  // the header's bottom hairline (y 55)
    #expect(rgb(px, image, x: 1200, y: 113) == bg0)
  }

  /// The right side of the header: the name and `?` show only with a title (the empty state has neither).
  @Test func noTitleHidesNameAndHelp() throws {
    let size = CGSize(width: Self.window.width, height: Tokens.Layout.header)
    func rightInk(_ title: String?) throws -> Int {
      let image = try render(HeaderView(title: title, logo: logo(scale: 1), onHelp: {}), size: size, scale: 1)
      let px = try pixels(image)
      var ink = 0
      for y in 0..<Int(size.height) - 1 { for x in 900..<image.width where rgb(px, image, x: x, y: y) != [0x0B, 0x0C, 0x0E] { ink += 1 } }
      return ink
    }
    #expect(try rightInk(nil) == 0)
    #expect(try rightInk("Spa Tour") > 100)
  }

  // MARK: helpers

  private func logo(scale: CGFloat) -> CGImage? { Logo.render(pdf: Self.logoPDF, height: 46, scale: scale) }

  private func render(_ view: some View, size: CGSize, scale: CGFloat) throws -> CGImage {
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.scale = scale
    return try #require(renderer.cgImage)
  }

  /// RGBA8 sRGB pixels, row 0 at the top.
  private func pixels(_ image: CGImage) throws -> [UInt8] {
    var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
      guard let ctx = CGContext(
        data: buf.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    #expect(ok)
    return px
  }

  private func rgb(_ px: [UInt8], _ image: CGImage, x: Int, y: Int) -> [UInt8] {
    let i = (y * image.width + x) * 4
    return [px[i], px[i + 1], px[i + 2]]
  }
}
