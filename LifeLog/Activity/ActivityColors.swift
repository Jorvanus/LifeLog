import SwiftUI

/// The one place a colour is chosen for an activity or a group, and the one place
/// that choice is turned back into a hex string.
///
/// Drawing and reporting used to read from two separate lists that had drifted, so
/// a group could be one colour in the Insights donut and another in an export or
/// in what VoiceOver announced. Everything that needs a colour comes through here.

func activityColor(_ activity: String) -> Color {
    let key = activity.trimmingCharacters(in: .whitespacesAndNewlines)
    if let definition = ActivityCatalog.load().first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame }),
       let colorHex = definition.colorHex, let color = Color(hex: colorHex) { return color }
    if let stored = UserDefaults.standard.string(forKey: "LifeLog.ActivityColor.\(key)"),
       let color = Color(hex: stored) { return color }
    if key.caseInsensitiveCompare("Visiting") == .orderedSame { return .gray }
    return categoryColor(forCategory: ActivityCatalog.category(for: activity))
}

func saveActivityColor(_ color: Color, forActivity activity: String) {
    let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
       let components = resolved.cgColor.components, components.count >= 3 {
        red = components[0]; green = components[1]; blue = components[2]
        alpha = components.count >= 4 ? components[3] : 1
    }
    let hex = [red, green, blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
    var definitions = ActivityCatalog.load()
    if let index = definitions.firstIndex(where: { $0.name.caseInsensitiveCompare(activity) == .orderedSame }) {
        definitions[index].colorHex = hex
        ActivityCatalog.save(definitions)
    }
    UserDefaults.standard.set(hex, forKey: "LifeLog.ActivityColor.\(activity.trimmingCharacters(in: .whitespacesAndNewlines))")
    UserDefaults.standard.synchronize()
}

func activityColorHex(_ color: Color) -> String {
    let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return "8E8E93" }
    return [red, green, blue].map { String(format: "%02X", Int(($0 * 255).rounded())) }.joined()
}

func categoryColor(forCategory category: String) -> Color {
    Color(hex: categoryColorHex(forCategory: category)) ?? .gray
}

/// Both the colour drawn and the value exported come from here, so a group cannot
/// look like one colour on screen and report as another.
func categoryColorHex(forCategory category: String) -> String {
    let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
    if let stored = UserDefaults.standard.string(forKey: "LifeLog.CategoryColor.\(key)") {
        return "#\(stored)"
    }
    return "#\(CategoryPalette.hex(for: key))"
}

extension Color {
    static let lifeBackground = Color(uiColor: .systemGroupedBackground)
    static let lifeCard = Color(uiColor: .secondarySystemGroupedBackground)

    init?(hex: String) {
        let value = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        self.init(red: Double((number >> 16) & 0xff) / 255,
                  green: Double((number >> 8) & 0xff) / 255,
                  blue: Double(number & 0xff) / 255)
    }
}
