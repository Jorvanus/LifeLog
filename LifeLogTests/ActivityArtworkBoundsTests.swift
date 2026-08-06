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

    @Test("Every group has a colour of its own")
    func groupColoursAreDistinct() {
        // Work and Entertainment were both plain purple, which is indistinguishable
        // in a donut where they sit beside each other.
        var seen: [String: String] = [:]
        for group in ActivityCatalog.defaultCategories {
            let hex = CategoryPalette.hex(for: group)
            #expect(hex != CategoryPalette.fallbackHex || group == "Other",
                    "\(group) falls back to grey")
            if let owner = seen[hex] {
                Issue.record("\(group) and \(owner) share \(hex)")
            }
            seen[hex] = group
        }
    }

    @Test("The colour drawn is the colour reported")
    func colourSourcesAgree() {
        // These were two separate lists, and had already drifted: Entertainment was
        // purple on screen and grey in exports, because one list simply lacked it.
        for group in ActivityCatalog.defaultCategories {
            #expect(categoryColorHex(forCategory: group) == "#\(CategoryPalette.hex(for: group))")
        }
        // Case and padding must not change the answer; the old pair disagreed on that.
        #expect(CategoryPalette.hex(for: "food & drink") == CategoryPalette.hex(for: "Food & Drink"))
        #expect(CategoryPalette.hex(for: "  Work  ") == CategoryPalette.hex(for: "Work"))
        // A group the person invented has no colour of its own, and says so.
        #expect(CategoryPalette.hex(for: "Volunteering") == CategoryPalette.fallbackHex)
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
        #expect(ActivityArtworkLayout.verticalOffset < 0)
        // Enough source to cover the cropped card on a 3× screen without enlargement.
        #expect(Double(ActivityArtworkLayout.recommendedSourcePixels)
                >= ActivityArtworkLayout.width * 3)
    }

    /// Ten illustrations shipped as `ActivityCoffee.png` inside imagesets for work,
    /// beer, fitness and a blood donation. Nothing broke, because the catalog reads
    /// the name out of `Contents.json` — which is exactly why it went unnoticed.
    @Test("Each imageset's file is named after the imageset")
    func assetFilenamesMatchTheirImageset() {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LifeLog/Assets.xcassets")
        let sets = (try? FileManager.default.contentsOfDirectory(atPath: root.path))?
            .filter { $0.hasPrefix("Activity") && $0.hasSuffix(".imageset") } ?? []
        #expect(!sets.isEmpty)
        for imageSet in sets {
            let stem = imageSet.replacingOccurrences(of: ".imageset", with: "")
            let contents = root.appendingPathComponent(imageSet)
            let pngs = (try? FileManager.default.contentsOfDirectory(atPath: contents.path))?
                .filter { $0.hasSuffix(".png") } ?? []
            for png in pngs {
                #expect(png == "\(stem).png",
                        "\(imageSet) contains \(png), which is named after another activity")
            }
        }
    }

    /// The catalogue's own names are inflected, so a rule written against the plain
    /// verb silently matched nothing: "exercising" does not contain "exercise", and
    /// "commuting" contains none of travel/transit/drive/car. Both shipped with
    /// usable artwork sitting unreachable in the bundle.
    @Test("Shipped activities resolve to artwork that exists")
    func shippedActivitiesResolveToRealAssets() {
        let expected = [
            "At home": "ActivityHome", "Working": "ActivityWorkV2",
            "Coffee": "ActivityCoffeeV2", "Beers": "ActivityBeersV2",
            "Shopping": "ActivityShoppingV2", "Healthcare": "ActivityHealthcare",
            "Travelling": "ActivityDriving", "Sleeping": "ActivitySleep",
            "Walking": "ActivityWalking", "Exercising": "ActivityFitnessV2",
            "Commuting": "ActivityDriving", "Running": "ActivityFitnessV2",
            "Cycling": "ActivityFitnessV2", "Swimming": "ActivityFitnessV2",
            "Yoga": "ActivityFitnessV2", "Strength training": "ActivityFitnessV2",
            "Breakfast": "ActivityBreakfast", "Lunch": "ActivityLunch",
            "Dining out": "ActivityDiningOut", "Eating": "ActivityEating",
            "Concert": "ActivityConcert", "Watching a movie": "ActivityWatchingMovie",
            "Studying": "ActivityStudying", "Football": "ActivityStudying",
            "Socialising": "ActivitySocialising", "Visiting": "ActivityVisiting"
        ]
        for (activity, asset) in expected {
            #expect(ActivityScene(activity: activity).assetNameForTesting == asset,
                    "\(activity) did not resolve to \(asset)")
            #expect(UIImage(named: asset) != nil, "\(asset) is not in the bundle")
        }
    }

    /// The whole catalogue, not just the ones someone remembered to list above.
    /// Twelve of these had no illustration and nothing said so.
    @Test("Every shipped activity has an illustration")
    func everyShippedActivityHasArtwork() {
        var without: [String] = []
        for entry in ActivityCatalog.defaults {
            guard let asset = ActivityScene(activity: entry.name).assetNameForTesting,
                  UIImage(named: asset) != nil else {
                without.append(entry.name)
                continue
            }
        }
        #expect(without.isEmpty, "no artwork for: \(without.sorted().joined(separator: ", "))")
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
