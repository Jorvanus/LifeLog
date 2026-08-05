import Foundation

/// Trims a free-text value to something safe to store, compare and log.
///
/// Every place name, activity and note passes through here before it is written.
/// It strips control characters, normalises Unicode so two spellings that look
/// identical compare as identical, and caps the length. This is used far beyond
/// the on-device classifier it originally shipped inside — `NameKey` builds its
/// name comparison on top of it.
enum TextSafety {
    static func clean(_ text: String, maximumLength: Int) -> String {
        let withoutControls = String(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let normalized = withoutControls.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(maximumLength))
    }
}
