import SwiftUI

/// How an activity is drawn: the circular symbol on every timeline card, and the
/// larger illustration reserved for the current-activity card. Split out of
/// TimelineView, which had grown to over a thousand lines by holding the whole
/// timeline, its editor and this artwork in one file.

struct ActivityIcon: View {
    let activity: String
    /// Extra wording used only to pick a symbol — the place name now that LifeLog
    /// does not model a place type.
    var context: String = ""
    let color: Color
    var size: CGFloat = 54
    var body: some View {
        Group {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: Circle())
        }
        .frame(width: size, height: size)
        .shadow(color: color.opacity(0.16), radius: 7, y: 4)
    }
    // Pure lookups over the two initializer parameters, with no dependency on being
    // on the main actor — but `ActivityIcon` conforms to `View`, so SwiftUI infers
    // @MainActor on every member by default, including these. A test that isn't
    // itself @MainActor calling one directly traps at runtime with an isolation
    // violation the compiler only warns about (`ActivityArtworkBoundsTests`,
    // `timelineUsesStoredActivityIcon`). `nonisolated` opts them out explicitly.
    nonisolated private var symbol: String {
        let text = "\(activity) \(context)".lowercased()
        // The catalogue is the user's source of truth. Keyword inference remains a
        // useful fallback for imported labels that have not been adopted yet, but it
        // must not override an icon chosen in Activities.
        if let definition = ActivityCatalog.load().first(where: {
            $0.matchesSnapshot(activity)
        }) {
            return definition.symbol
        }
        if text.contains("travel") || text.contains("transit") { return "car.fill" }
        if text.contains("home") { return "house.fill" }
        if text.contains("work") || text.contains("office") { return "building.2.fill" }
        if text.contains("eat") || text.contains("lunch") || text.contains("restaurant") { return "fork.knife" }
        if text.contains("coffee") || text.contains("cafe") { return "cup.and.saucer.fill" }
        if text.contains("exercise") || text.contains("gym") { return "figure.run" }
        if text.contains("walk") { return "figure.walk" }
        if text.contains("run") { return "figure.run" }
        if text.contains("cycl") { return "bicycle" }
        if text.contains("sleep") || text.contains("in bed") { return "bed.double.fill" }
        if text.contains("shop") { return "bag.fill" }
        return "mappin"
    }

    nonisolated var symbolForTesting: String { symbol }

    /// The illustration for the current-activity card, or nothing when there isn't one.
    ///
    /// Ordered most specific first: "Work trip" has to be caught before the plain
    /// "work" rule, and a cafe before the coffee in it, or the general rule swallows
    /// the particular one.
    ///
    /// Stems rather than whole words, because the catalogue's own names are the
    /// inflected forms. `contains("exercise")` never matched **"Exercising"** — the
    /// string is "exercis-ing", so the app's own default activity missed its own
    /// artwork for as long as both have existed. `commuting` missed `ActivityDriving`
    /// the same way.
    nonisolated fileprivate var resolvedAssetName: String? {
        let text = "\(activity) \(context)".lowercased()
        if text.contains("blood") { return "ActivityDonateBlood" }
        if text.contains("work trip") || text.contains("business trip") { return "ActivityWorkTrip" }
        if text.contains("flight") || text.contains("plane") || text.contains("airport") { return "ActivityFlight" }
        if text.contains("hotel") || text.contains("lodging") { return "ActivityHotel" }
        // Meals, before the broader rules. "Breakfast" would otherwise be caught by
        // nothing at all, and "Dining out" must not fall through to the cafe.
        if text.contains("breakfast") || text.contains("brunch") { return "ActivityBreakfast" }
        if text.contains("lunch") { return "ActivityLunch" }
        // Dining Out is the single meal scene. Historical Eating labels remain
        // readable, without keeping a second nearly-identical illustration.
        if text.contains("dining") || text.contains("dinner") || text.contains("restaurant")
            || text.contains("eating") || text.contains("meal") { return "ActivityDiningOut" }
        if text.contains("concert") || text.contains("gig") || text.contains("live music") { return "ActivityConcert" }
        if text.contains("movie") || text.contains("film") || text.contains("cinema")
            || text.contains("watching tv") || text.contains("television") {
            return "ActivityWatchingMovie"
        }
        if text.contains("football") || text.contains("soccer") {
            return "ActivityFootball"
        }
        if text.contains("study") || text.contains("studying") || text.contains("revis") {
            return "ActivityStudying"
        }
        if text.contains("social") { return "ActivitySocialising" }
        if text.contains("home") { return "ActivityHome" }
        if text.contains("beer") { return "ActivityBeersV2" }
        if text.contains("exercis") || text.contains("fitness") || text.contains("gym")
            || text.contains("workout") || text.contains("yoga") || text.contains("swim")
            || text.contains("cycl") || text.contains("running") || text.contains("strength") {
            return "ActivityFitnessV2"
        }
        if text.contains("meeting") { return "ActivityMeetingV2" }
        // A doctor consultation is the shared visual language for health care.
        if text.contains("doctor") || text.contains("health") || text.contains("medical")
            || text.contains("hospital") { return "ActivityDoctorVisit" }
        if text.contains("grocer") || text.contains("supermarket") { return "ActivityGroceries" }
        if text.contains("family") || text.contains("child") { return "ActivityFamily" }
        if text.contains("desk") { return "ActivityWorkV2" }
        if text.contains("shop") { return "ActivityShoppingV2" }
        // Sleep is deliberately text-and-icon only: showing someone asleep adds
        // no useful context to the current-activity card.
        if text.contains("sleep") || text.contains("in bed") { return nil }
        if text.contains("cafe") || text.contains("café") { return "ActivityCafe" }
        if text.contains("coffee") { return "ActivityCoffeeV2" }
        if text.contains("work") || text.contains("office") { return "ActivityWorkV2" }
        if text.contains("transit") || text.contains("train") || text.contains("subway") || text.contains("metro") || text.contains("bus") {
            return "ActivityTransit"
        }
        if text.contains("commut") || text.contains("travel")
            || text.contains("drive") || text.contains("driving") || text.contains("car") {
            return "ActivityDriving"
        }
        if text.contains("walk") { return "ActivityWalking" }
        // Last, because it is the label for a place LifeLog could not name — anything
        // more specific above should have claimed the visit before it reaches here.
        if text.contains("visiting") || text.contains("visit") { return "ActivitySocialising" }
        return nil
    }
}

/// The larger scene illustration is reserved for the current-activity card;
/// compact timeline cards keep their readable circular activity icons.
struct ActivityScene: View {
    let activity: String
    var context: String = ""

    var body: some View {
        if let assetName {
            Image(assetName)
                .resizable()
                // Fill and crop, rather than fit-then-magnify. The previous version
                // shrank the artwork to fit this band and then blew it back up three
                // times, which drew a ~300px source at roughly 2.7× its own size —
                // the reason the illustrations looked soft. Filling reaches the same
                // framing at the smallest enlargement that still covers the card, and
                // adapts to whatever aspect a replacement image happens to have.
                .scaledToFill()
                // The image is deliberately clipped to this fixed footprint. Do not
                // let the transformed artwork affect layout: transparent source
                // padding must never enlarge the card or push text out of alignment.
                .frame(width: ActivityArtworkLayout.width, height: ActivityArtworkLayout.height)
                // The artwork belongs to the card, so its corners must follow the
                // card rather than exposing a square source-image edge at a placement.
                .clipShape(RoundedRectangle(cornerRadius: ActivityArtworkLayout.cornerRadius))
                .offset(y: ActivityArtworkLayout.verticalOffset)
                .accessibilityHidden(true)
        }
    }

    // Same reasoning as ActivityIcon's pure properties above: `ActivityScene` is
    // also a `View`, so these need `nonisolated` explicitly to be callable from a
    // non-@MainActor test context without trapping.
    nonisolated private var assetName: String? {
        ActivityIcon(activity: activity, context: context, color: .clear).resolvedAssetName
    }

    /// The chosen asset, so a test can check an activity reaches artwork that is
    /// actually in the bundle. Reading it back through the rendered view is not
    /// possible, and these rules have already shipped two silent misses.
    nonisolated var assetNameForTesting: String? { assetName }
}

/// Stable bounds for the decorative scene on the current-activity card. Keeping
/// these values in one place lets UI tests catch accidental artwork regressions.
enum ActivityArtworkLayout {
    static let width: CGFloat = 170
    static let height: CGFloat = 88
    static let verticalOffset: CGFloat = 0
    static let cornerRadius: CGFloat = 14

    /// The shortest edge a replacement illustration should be exported at.
    ///
    /// The card is 170×88pt, which is 510×264 device pixels on a 3× screen, and the
    /// artwork is cropped to fill it — so the source has to cover the *longer* edge
    /// after cropping, not merely match the frame. 1024px on the short edge leaves
    /// room for that crop and for the card ever growing, without shipping megabytes.
    static let recommendedSourcePixels = 1024

}
