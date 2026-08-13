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
        guard let text = decodeText(data) else { return ([], 1) }
        // Construct formatters once per file. Creating two DateFormatters for every
        // 32,000-row import is much more expensive than the CSV parsing itself.
        let zonedFormatter = makeDateFormatter(format: "yyyy-MM-dd HH:mm:ss zzz")
        let utcFormatter = makeDateFormatter(format: "yyyy-MM-dd HH:mm:ss", utc: true)
        let records = csvRecords(text).dropFirst()
        var rows: [Row] = []
        var malformed = 0
        for fields in records where fields.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            guard fields.count >= 8,
                  let start = zonedFormatter.date(from: fields[2]) ?? utcFormatter.date(from: fields[0]),
                  let end = zonedFormatter.date(from: fields[3]) ?? utcFormatter.date(from: fields[1]),
                  end >= start else {
                malformed += 1
                continue
            }
            rows.append(Row(start: start, end: end,
                            name: TextSafety.clean(fields[5], maximumLength: 80),
                            location: TextSafety.clean(fields[6], maximumLength: 120),
                            note: TextSafety.clean(fields[7], maximumLength: 2_000)))
        }
        return (rows, malformed)
    }

    /// Decodes the common export encodings, including BOM-marked UTF-16 files.
    private static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
        if let text = String(data: data, encoding: .utf16LittleEndian) { return text }
        return String(data: data, encoding: .utf16BigEndian)
    }

    /// RFC 4180 parser. It keeps commas and line breaks inside quoted fields,
    /// and turns doubled quotes (`""`) back into a literal quote. Parsing by
    /// character state avoids the incorrect line splitting used previously and
    /// does not allocate a substring for every physical line.
    private static func csvRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = String()
        var quoted = false
        var pendingQuote = false
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if pendingQuote {
                if scalar == "\"" {
                    field.append("\"")
                    pendingQuote = false
                    index += 1
                    continue
                }
                quoted = false
                pendingQuote = false
            }
            if quoted {
                if scalar == "\"" { pendingQuote = true }
                else { field.unicodeScalars.append(scalar) }
            } else {
                switch scalar {
                case "\"": quoted = true
                case ",": record.append(field); field.removeAll(keepingCapacity: true)
                case "\r", "\n":
                    record.append(field); field.removeAll(keepingCapacity: true)
                    records.append(record); record.removeAll(keepingCapacity: true)
                    if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
                default: field.unicodeScalars.append(scalar)
                }
            }
            index += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    @MainActor
    static func importData(_ data: Data, into context: ModelContext) throws -> JournalImportResult {
        let parsed = parse(data)
        let existing = try context.fetch(FetchDescriptor<Visit>(
            predicate: #Predicate { $0.source == "imported-journal" }
        ))
        // Life Cycle exports can contain tens of thousands of rows. Keep duplicate
        // detection O(1) per row instead of scanning every existing Visit for each
        // imported entry, which otherwise makes a large import feel like a hang.
        var importedKeys = Set(existing.compactMap(importKey(for:)))
        var inserted = 0
        var skipped = 0
        let mutation = VisitMutationService.perform(context: context, kind: .importBatch) {
            for row in parsed.rows {
                let activity = normalizedActivity(row.name)
                let place = row.location.isEmpty ? "Imported journal" : row.location
                let key = importKey(start: row.start, place: place, activity: activity)
                if !importedKeys.insert(key).inserted { skipped += 1; continue }
                context.insert(Visit(
                    arrival: row.start, departure: row.end, latitude: 0, longitude: 0,
                    placeName: place,
                    inferredActivity: activity, userActivity: activity, note: row.note,
                    source: "imported-journal", recognitionConfidence: "imported"
                ))
                inserted += 1
            }
            return .init(changedCount: inserted)
        }
        guard mutation.committed else { throw JournalImportError.mutationFailed(mutation.failureDescription) }
        return JournalImportResult(rows: parsed.rows.count, inserted: inserted,
                                   skipped: skipped, malformed: parsed.malformed)
    }

    private static func importKey(for visit: Visit) -> String? {
        guard visit.visitSource == .importedJournal else { return nil }
        return importKey(start: visit.arrival, place: visit.placeName, activity: visit.activity)
    }

    private static func importKey(start: Date, place: String, activity: String) -> String {
        "\(start.timeIntervalSince1970.rounded())|\(place)|\(activity)"
    }

    private static func makeDateFormatter(format: String, utc: Bool = false) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        if utc { formatter.timeZone = TimeZone(secondsFromGMT: 0) }
        return formatter
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

}

private enum JournalImportError: LocalizedError {
    case mutationFailed(String?)

    var errorDescription: String? {
        switch self {
        case .mutationFailed(let description): return description ?? "LifeLog couldn't save this journal import."
        }
    }
}
