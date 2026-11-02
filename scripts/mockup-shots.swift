// Dev tool (not in the package): screenshots design/mockup.html states via an offscreen WKWebView.
// swift scripts/mockup-shots.swift --page design/mockup.html --out <dir> --states a,b,c [--width 1240 --height 860]
import AppKit
import WebKit

var args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
guard let page = opt("--page"), let out = opt("--out"), let statesArg = opt("--states") else {
    FileHandle.standardError.write(Data("usage: mockup-shots.swift --page <html> --out <dir> --states a,b [--width N --height N]\n".utf8))
    exit(2)
}
let width = Double(opt("--width") ?? "1240") ?? 1240
let height = Double(opt("--height") ?? "860") ?? 860
let states = statesArg.split(separator: ",").map(String.init)
let pageURL = URL(fileURLWithPath: page, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
let outDir = URL(fileURLWithPath: out, isDirectory: true, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).standardizedFileURL
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

@MainActor func pump(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

// Redraws the snapshot into a bitmap of exactly pixelsWide x pixelsHigh (the screen's backing scale would otherwise double it).
@MainActor func png(_ image: NSImage, pixelsWide: Int, pixelsHigh: Int) -> Data? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let ctx = CGContext(data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          true else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
    guard let out = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
}

@MainActor func run() async -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    let frame = NSRect(x: 0, y: 0, width: width, height: height)
    let web = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
    let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = web
    window.alphaValue = 0.01; window.ignoresMouseEvents = true; window.setFrameOrigin(NSPoint(x: 0, y: 0))  // effectively invisible but on-screen, so WebKit treats it as visible and paints
    window.orderFrontRegardless()
    NSApplication.shared.activate(ignoringOtherApps: true)
    var failed: Int32 = 0
    for state in states {
        var comps = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)!
        comps.fragment = state
        // read access covers the repo root: the page references ../assets
        web.loadFileURL(comps.url!, allowingReadAccessTo: pageURL.deletingLastPathComponent().deletingLastPathComponent())
        var ready = false
        for _ in 0..<200 {
            await pump(0.1)
            if let v = try? await web.evaluateJavaScript("window.__ready === true && location.hash === '#\(state)'"), (v as? Bool) == true { ready = true; break }
        }
        if !ready { FileHandle.standardError.write(Data("\(state): __ready never became true\n".utf8)); failed = 1; continue }
        await pump(0.6)  // let post-ready transitions settle
        for (scale, tag) in [(1.0, "1x"), (2.0, "2x")] {
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: width, height: height)
            cfg.snapshotWidth = NSNumber(value: width * scale)
            cfg.afterScreenUpdates = true
            do {
                let img = try await web.takeSnapshot(configuration: cfg)
                guard let data = png(img, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale)) else { throw NSError(domain: "png", code: 1) }
                try data.write(to: outDir.appendingPathComponent("\(state)@\(tag).png"))
            } catch {
                FileHandle.standardError.write(Data("\(state)@\(tag): \(error)\n".utf8)); failed = 1
            }
        }
        print("ok \(state)")
    }
    return failed
}

let task = Task { @MainActor in
    let code = await run()
    exit(code)
}
_ = task
NSApplication.shared.run()
