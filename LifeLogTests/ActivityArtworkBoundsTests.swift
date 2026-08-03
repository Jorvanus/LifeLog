import Foundation
import ImageIO
import Testing
@testable import LifeLog

struct ActivityArtworkBoundsTests {
    @Test("Current activity artwork has a bounded fixed footprint")
    func layoutIsBounded() {
        #expect(ActivityArtworkLayout.width == 170)
        #expect(ActivityArtworkLayout.height == 88)
        #expect(ActivityArtworkLayout.maximumScale == 3)
        #expect(ActivityArtworkLayout.verticalOffset < 0)
        #expect(ActivityArtworkLayout.maximumScale * ActivityArtworkLayout.width > 0)
    }

    @Test("Activity artwork PNGs have sane source dimensions")
    func sourceDimensionsAreSane() {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LifeLog/Assets.xcassets")
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
            Issue.record("Could not enumerate the asset catalog")
            return
        }

        let pngs = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "png" && $0.path.contains("Activity") }
        #expect(!pngs.isEmpty)
        for url in pngs {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                Issue.record("Could not read PNG dimensions for \(url.lastPathComponent)")
                continue
            }
            #expect(width > 0 && width <= 2048)
            #expect(height > 0 && height <= 2048)
            #expect(Double(width) / Double(height) < 2.5)
        }
    }
}
