import Foundation
import ImageIO
import Testing
import UIKit
@testable import LifeLog

struct ActivityArtworkBoundsTests {
    /// A misspelled SF Symbol does not fail to build — it renders as nothing at all,
    /// so an activity would appear to have lost its icon. Every offered name is
    /// checked against the system here rather than trusted.
    @Test("Every offered activity icon exists on this system")
    func iconsResolve() {
        var missing: [String] = []
        for symbol in ActivityIcons.all where UIImage(systemName: symbol) == nil {
            missing.append(symbol)
        }
        #expect(missing.isEmpty, "unresolved symbols: \(missing.joined(separator: ", "))")
    }

    @Test("The icons the app ships with are all offered")
    func shippedIconsAreOfferable() {
        // Otherwise editing one of these shows a picker with nothing selected, which
        // is what the ten-icon list used to do for most of the catalogue.
        let shipped = Set(ActivityCatalog.defaults.map(\.symbol))
        let offered = Set(ActivityIcons.all)
        #expect(shipped.subtracting(offered).isEmpty,
                "not offered: \(shipped.subtracting(offered).sorted().joined(separator: ", "))")
    }

    @Test("Everything the app can produce exists as an activity")
    func generatedLabelsAreDefined() {
        // These arrive from Apple Health, the iPhone's motion history and journey
        // detection. Missing from the catalogue, each showed as a grey dot with no
        // group — and left the Sleep and Commute groups empty while the timeline
        // was full of both.
        let defined = Set(ActivityCatalog.defaults.map { $0.name.lowercased() })
        for produced in ["Sleeping", "Walking", "Running", "Cycling", "Swimming",
                         "Yoga", "Strength training", "Commuting", "In transit", "Home time"] {
            #expect(defined.contains(produced.lowercased()), "\(produced) has no activity")
        }
        // Every group LifeLog offers should have something in it.
        let groups = Set(ActivityCatalog.defaults.map(\.category))
        #expect(groups.contains("Sleep"))
        #expect(groups.contains(CommuteDetection.categoryName))
        // And each shipped activity's icon must be one the picker offers.
        let offered = Set(ActivityIcons.all)
        for entry in ActivityCatalog.defaults {
            #expect(offered.contains(entry.symbol), "\(entry.name) uses an unofferable icon")
        }
    }

    @Test("No icon is offered twice")
    func iconsAreUnique() {
        let all = ActivityIcons.all
        #expect(all.count == Set(all).count)
    }

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
