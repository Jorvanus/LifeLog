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
    private var symbol: String {
        let text = "\(activity) \(context)".lowercased()
        if text.contains("travel") || text.contains("transit") { return "car.fill" }
        if text.contains("home") { return "house.fill" }
        if text.contains("work") || text.contains("office") { return "building.2.fill" }
        if text.contains("eat") || text.contains("lunch") || text.contains("restaurant") { return "fork.knife" }
        if text.contains("coffee") || text.contains("cafe") { return "cup.and.saucer.fill" }
        if text.contains("exercise") || text.contains("gym") { return "figure.run" }
        if text.contains("walk") { return "figure.walk" }
        if text.contains("run") { return "figure.run" }
        if text.contains("cycl") { return "bicycle" }
        if text.contains("sleep") { return "bed.double.fill" }
        if text.contains("shop") { return "bag.fill" }
        return "mappin"
    }

    fileprivate var resolvedAssetName: String? {
        let text = "\(activity) \(context)".lowercased()
        if text.contains("home") { return "ActivityHome" }
        if text.contains("beer") { return "ActivityBeers" }
        if text.contains("exercise") || text.contains("fitness") || text.contains("gym") { return "ActivityExercise" }
        if text.contains("meeting") { return "ActivityMeeting" }
        if text.contains("doctor") { return "ActivityDoctor" }
        if text.contains("health") || text.contains("medical") || text.contains("hospital") { return "ActivityHealthcare" }
        if text.contains("grocer") || text.contains("supermarket") { return "ActivityGroceries" }
        if text.contains("family") || text.contains("child") { return "ActivityFamily" }
        if text.contains("hotel") || text.contains("lodging") { return "ActivityHotel" }
        if text.contains("desk") { return "ActivityDesk" }
        if text.contains("shop") { return "ActivityShopping" }
        if text.contains("sleep") { return "ActivitySleep" }
        if text.contains("work") || text.contains("office") { return "ActivityWork" }
        if text.contains("travel") || text.contains("transit") || text.contains("drive") || text.contains("car") { return "ActivityDriving" }
        if text.contains("walk") { return "ActivityWalking" }
        if text.contains("coffee") || text.contains("cafe") { return "ActivityCoffee" }
        if text.contains("flight") || text.contains("plane") || text.contains("airport") { return "ActivityFlight" }
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
                .scaledToFit()
                // The image is deliberately clipped to this fixed footprint. Do not
                // let the transformed artwork affect layout: transparent source
                // padding must never enlarge the card or push text out of alignment.
                .scaleEffect(3.0)
                .frame(width: ActivityArtworkLayout.width, height: ActivityArtworkLayout.height)
                .offset(y: ActivityArtworkLayout.verticalOffset)
                .clipped()
                .accessibilityHidden(true)
        }
    }

    private var assetName: String? {
        ActivityIcon(activity: activity, context: context, color: .clear).resolvedAssetName
    }
}

/// Stable bounds for the decorative scene on the current-activity card. Keeping
/// these values in one place lets UI tests catch accidental artwork regressions.
enum ActivityArtworkLayout {
    static let width: CGFloat = 170
    static let height: CGFloat = 88
    static let maximumScale: CGFloat = 3
    static let verticalOffset: CGFloat = -16
}
