import Foundation

struct TrendExportFile: Identifiable {
    let id = UUID()
    let url: URL
    let format: String
}

enum TrendExport {
    private struct Row: Codable {
        let date: String
        let checkIn: String
        let checkOut: String
        let place: String
        let category: String
        let categoryColor: String
        let activity: String
        let lifeArea: String
        let durationHours: Double
        let source: String
        let origin: String
        let confidence: String
    }

    static func makeFile(format: String, visits: [Visit], interval: DateInterval, now: Date,
                         scope: InsightsScope = .allHistory) -> TrendExportFile? {
        ExportFileCleanup.removeExpired()
        let rows = visits.filter { scope.includes($0) && $0.resolutionState != .ignored &&
            $0.resolutionState != .superseded && overlaps($0, interval: interval, now: now) }
            .sorted { $0.arrival < $1.arrival }
            .map { visit in
                Row(
                    date: visit.arrival.formatted(date: .numeric, time: .omitted),
                    checkIn: visit.arrival.formatted(date: .omitted, time: .standard),
                    checkOut: (visit.departure ?? now).formatted(date: .omitted, time: .standard),
                    place: visit.displayPlaceName,
                    category: visit.insightCategory,
                    categoryColor: categoryColorHex(forCategory: visit.insightCategory),
                    activity: visit.activity,
                    lifeArea: ActivityCatalog.lifeArea(for: visit.activity, category: visit.insightCategory).rawValue,
                    durationHours: rounded(hours(visit, interval: interval, now: now)),
                    source: visit.source,
                    origin: visit.source.hasPrefix("health-") ? "Apple Health" : "LifeLog / location",
                    confidence: visit.confidenceLabel
                )
            }
        let stamp = Date.now.formatted(.iso8601.timeSeparator(.omitted).timeZone(separator: .omitted))
        let filename = "lifelog-trends-\(stamp).\(format)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            let data: Data
            if format == "json" {
                data = try JSONEncoder().encode(rows)
            } else {
                data = Data(csv(rows).utf8)
            }
            try data.write(to: url, options: .atomic)
            return TrendExportFile(url: url, format: format.uppercased())
        } catch {
            return nil
        }
    }

    private static func csv(_ rows: [Row]) -> String {
        var lines = ["date,check_in,check_out,place,category,category_color,activity,life_area,duration_hours,source,origin,confidence"]
        lines += rows.map { row in
            [row.date, row.checkIn, row.checkOut, row.place, row.category, row.categoryColor, row.activity, row.lifeArea,
             String(row.durationHours), row.source, row.origin, row.confidence].map(csvField).joined(separator: ",")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }

    private static func overlaps(_ visit: Visit, interval: DateInterval, now: Date) -> Bool {
        visit.arrival < interval.end && (visit.departure ?? now) > interval.start
    }

    private static func hours(_ visit: Visit, interval: DateInterval, now: Date) -> Double {
        max(0, min(visit.departure ?? now, interval.end)
            .timeIntervalSince(max(visit.arrival, interval.start)) / 3600)
    }

    private static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }
}
