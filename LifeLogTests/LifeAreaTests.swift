import Foundation
import Testing
@testable import LifeLog

struct LifeAreaTests {
    @Test("Built-in activities receive stable derived life areas")
    func builtInMapping() {
        #expect(LifeArea.default(for: "Coffee", category: "Food & Drink") == .foodDrink)
        #expect(LifeArea.default(for: "Football", category: "Entertainment") == .social)
        #expect(LifeArea.default(for: "CrossFit", category: "Fitness") == .healthFitness)
        #expect(LifeArea.default(for: "Shopping", category: "Shopping") == .errands)
        #expect(LifeArea.default(for: "Sleeping", category: "Sleep") == .sleepRest)
    }

    @Test("Life area is not independently editable -- a stored value from before this design self-heals to the derived one")
    func staleStoredLifeAreaSelfHeals() throws {
        let defaults = UserDefaults(suiteName: "LifeAreaTests.staleStore")!
        defaults.removePersistentDomain(forName: "LifeAreaTests.staleStore")
        ActivityCatalog.withStorage(defaults) {
            // Simulates a definition persisted back when `lifeArea` could be set
            // independently of `category` -- decoding must ignore the stale
            // "Social" value and recompute from the category instead.
            let json = """
            [{"id":"\(UUID().uuidString)","name":"Coffee","category":"Food & Drink",
              "symbol":"cup.and.saucer.fill","lifeArea":"Social","legacyNames":[]}]
            """
            defaults.set(Data(json.utf8), forKey: "LifeLog.ActivityCatalog.v1")
            #expect(ActivityCatalog.lifeArea(for: "Coffee") == .foodDrink)
            #expect(ActivityCatalog.category(for: "Coffee") == "Food & Drink")
        }
    }

    @Test("Renamed and deleted activities keep an honest mapping path")
    func renamedAndDeleted() {
        let renamed = ActivityDefinition(name: "Job", category: "Work", symbol: "briefcase.fill")
        #expect(ActivityCatalog.lifeArea(for: renamed.name, category: renamed.category) == .work)
        // A deleted label is resolved from its recorded category/name, not from a
        // second editable place taxonomy.
        #expect(ActivityCatalog.lifeArea(for: "Imported Workshop", category: "Work") == .work)
        #expect(ActivityCatalog.lifeArea(for: "Imported Coffee", category: "Other") == .other)
    }

    @Test("Imported labels and newly created activities remain inspectable")
    func importedAndCreated() {
        let imported = ActivityDefinition(name: "Local Book Club", category: "Other", symbol: "book.fill")
        let created = ActivityDefinition(name: "CrossFit", category: "Fitness", symbol: "figure.run")
        #expect(imported.lifeArea == LifeArea.other.rawValue)
        #expect(created.lifeArea == LifeArea.healthFitness.rawValue)
        #expect(LifeArea.allCases.contains { $0.rawValue == imported.lifeArea })
    }

    @Test("Month balance totals use life areas while retaining activity detail data")
    func aggregationTotals() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let coffee = segment(activity: "Coffee", category: "Food & Drink", base: base, hours: 2)
        let football = segment(activity: "Football", category: "Entertainment", base: base.addingTimeInterval(7_200), hours: 3)
        let result = MonthlyInsights.make(current: [coffee, football], previous: [],
                                          currentInterval: DateInterval(start: base, duration: 30 * 86_400),
                                          previousInterval: DateInterval(start: base, duration: 30 * 86_400))
        #expect(result.balance.first(where: { $0.name == LifeArea.foodDrink.rawValue })?.hours == 2)
        #expect(result.balance.first(where: { $0.name == LifeArea.social.rawValue })?.hours == 3)
    }

    private func segment(activity: String, category: String, base: Date, hours: Double) -> InsightSegment {
        let visit = Visit(arrival: base, departure: base.addingTimeInterval(hours * 3_600),
                          latitude: -27.47, longitude: 153.03, placeName: "Test",
                          inferredActivity: activity, source: "manual")
        return InsightSegment(id: .visit(ObjectIdentifier(visit)), visit: visit,
                              category: category, activity: activity, placeName: "Test",
                              start: base, end: base.addingTimeInterval(hours * 3_600), hours: hours,
                              color: insightColor(for: category), symbol: insightSymbol(for: category),
                              isUnlogged: false, isLive: false)
    }
}
