import Foundation
import SwiftData

struct JournalImportResult: Sendable {
    let rows: Int
    let inserted: Int
    let skipped: Int
    let malformed: Int
}

struct JournalCSVImporter {
    struct Row: Sendable {
        let start: Date
        let end: Date
        let name: String
        let location: String
        let note: String
    }

    static func parse(_ data: Data) -> (rows: [Row], malformed: Int) {
        guard let text = String(data: data, encoding: .utf8) else { return ([], 1) }
        let lines = text.components(separatedBy: .newlines).dropFirst()
        var rows: [Row] = []
        var malformed = 0
        for line in lines where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fields = line.split(separator: ",", maxSplits: 7, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 8,
                  let start = parseDate(String(fields[2])) ?? parseDate(String(fields[0])),
                  let end = parseDate(String(fields[3])) ?? parseDate(String(fields[1])),
                  end >= start else {
                malformed += 1
                continue
            }
            rows.append(Row(start: start, end: end,
                            name: TextSafety.clean(String(fields[5]), maximumLength: 80),
                            location: TextSafety.clean(String(fields[6]), maximumLength: 120),
                            note: TextSafety.clean(String(fields[7]), maximumLength: 2_000)))
        }
        return (rows, malformed)
    }

    @MainActor
    static func importData(_ data: Data, into context: ModelContext) throws -> JournalImportResult {
        let startedAt = Date.now
        let parsed = parse(data)
        let existing = try context.fetch(FetchDescriptor<Visit>())
        // Life Cycle exports can contain tens of thousands of rows. Keep duplicate
        // detection O(1) per row instead of scanning every existing Visit for each
        // imported entry, which otherwise makes a large import feel like a hang.
        var importedKeys = Set(existing.compactMap(importKey(for:)))
        var inserted = 0
        var skipped = 0
        for row in parsed.rows {
            let activity = normalizedActivity(row.name)
            let place = row.location.isEmpty ? "Imported journal" : row.location
            let key = importKey(start: row.start, place: place, activity: activity)
            if !importedKeys.insert(key).inserted { skipped += 1; continue }
            context.insert(Visit(
                arrival: row.start, departure: row.end, latitude: 0, longitude: 0,
                placeName: place, placeCategory: category(for: activity),
                inferredActivity: activity, userActivity: activity, note: row.note,
                source: "imported-journal", recognitionConfidence: "imported"
            ))
            inserted += 1
        }
        try context.save()
        Diagnostics.performance(context, subsystem: "Import", operation: "journal import",
                                startedAt: startedAt, itemCount: parsed.rows.count)
        return JournalImportResult(rows: parsed.rows.count, inserted: inserted,
                                   skipped: skipped, malformed: parsed.malformed)
    }

    private static func importKey(for visit: Visit) -> String? {
        guard visit.source == "imported-journal" else { return nil }
        return importKey(start: visit.arrival, place: visit.placeName, activity: visit.activity)
    }

    private static func importKey(start: Date, place: String, activity: String) -> String {
        "\(start.timeIntervalSince1970.rounded())|\(place)|\(activity)"
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        if let date = formatter.date(from: value) { return date }
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: value)
    }

    private static func normalizedActivity(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("sleep") { return "Sleeping" }
        if value.contains("walk") { return "Walking" }
        if value.contains("transport") || value.contains("travel") || value.contains("commut") { return "Travelling" }
        if ["dinner", "lunch", "breakfast", "coffee", "eat"].contains(where: value.contains) { return "Eating" }
        if value == "home" { return "At home" }
        return TextSafety.clean(raw.isEmpty ? "Visiting" : raw, maximumLength: 80)
    }

    private static func category(for activity: String) -> String {
        switch activity {
        case "Sleeping": "Sleep"
        case "Walking": "Walking"
        case "Travelling": "Travel"
        case "Eating": "Food & Drink"
        case "At home": "Home"
        default: "Other"
        }
    }
}
