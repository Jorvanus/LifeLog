import SwiftUI
import SwiftData
import MapKit
import UIKit

struct TimelineView: View {
    @Environment(\.modelContext) private var context
    let recorder: LocationRecorder
    // Imported journal rows are used by Insights, but are not automatic locations
    // or review items. Excluding them keeps the launch timeline query lightweight.
    @Query(filter: #Predicate<Visit> { $0.source != "imported-journal" },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    @State private var adding = false
    @State private var clock = Date.now
    // The add button's glyph and its circle have to grow together, otherwise a
    // Dynamic Type glyph overflows a fixed-size circle at accessibility sizes.
    @ScaledMetric(relativeTo: .title2) private var addButtonDiameter: CGFloat = 56
    // Bump this marker whenever reconciliation learns a new rule, so an installed
    // timeline is repaired once rather than only new records benefiting. v4 no longer
    // reads a walk inside an unbounded stay as leaving, so the walk is reabsorbed.
    @AppStorage("location-policy-reconciled-v4") private var locationPolicyReconciled = false
    // Undoes the stays v3 split in two before reconciliation runs again.
    @AppStorage("stay-splits-rejoined-v1") private var staySplitsRejoined = false
    // Bump this marker whenever de-duplication rules become stronger so an
    // installed timeline receives the one-time repair as well as new callbacks.
    @AppStorage("automatic-location-deduplicated-v3") private var automaticLocationDeduplicated = false

    private var today: [Visit] {
        let locationVisits = visits.filter(ActivityLocationPolicy.isLocationVisit)
        // Today is what the day covered, not what began in it. Selecting by arrival
        // date dropped the overnight stay, so the day appeared to start at the first
        // outing rather than at home.
        let dayStart = Calendar.current.startOfDay(for: clock)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let day = DateInterval(start: dayStart, end: max(dayStart, dayEnd))
        return visits.filter { ActivityLocationPolicy.covers($0, day: day) }
            .filter { $0.resolutionState != .ignored && $0.resolutionState != .superseded }
            .filter { ActivityLocationPolicy.shouldShowInTimeline($0, locationVisits: locationVisits) }
            // Core Location can replay an older unknown callback after a later
            // named visit arrives. Do not show that stale review row when its
            // interval is covered by a more useful location record.
            .filter { visit in
                guard visit.needsCategorisation else { return true }
                let end = visit.departure ?? .now
                return !locationVisits.contains { other in
                    guard other.id != visit.id, !other.needsCategorisation else { return false }
                    let otherEnd = other.departure ?? .now
                    return other.arrival <= end && otherEnd > visit.arrival
                }
            }
            .filter { visit in
                // Health and Motion can emit a short workout plus a longer
                // duplicate with the same start. Keep the more precise sample
                // when one interval is fully contained by another.
                guard ActivityLocationPolicy.isDeviceActivity(visit),
                      !visit.source.hasPrefix("health-sleep") else { return true }
                let end = visit.departure ?? .now
                return !visits.contains { other in
                    guard other.id != visit.id,
                          ActivityLocationPolicy.isDeviceActivity(other),
                          !other.source.hasPrefix("health-sleep"),
                          other.activity.caseInsensitiveCompare(visit.activity) == .orderedSame else { return false }
                    let otherEnd = other.departure ?? .now
                    let contains = other.arrival <= visit.arrival && otherEnd >= end
                    let strictlyBroader = other.arrival < visit.arrival || otherEnd > end
                    // Motion and Health can describe the same walk over exactly the
                    // same interval, and whether the import guard caught it depends on
                    // which batch arrived first. Neither record is broader, so prefer
                    // the more specific source rather than showing the walk twice.
                    let sameInterval = other.arrival == visit.arrival && otherEnd == end
                    return contains && (strictlyBroader ||
                                        (sameInterval && deviceDetail(other) > deviceDetail(visit)))
                }
            }
    }
    /// How much a source actually knows about a walk. A recorded workout carries the
    /// person's own intent, Health's walking samples come from the watch, and Core
    /// Motion is an inference from the phone alone.
    private func deviceDetail(_ visit: Visit) -> Int {
        switch visit.source {
        case "health-workout": 3
        case "health-walking": 2
        default: 1
        }
    }

    private var reviewQueue: [Visit] {
        // The live unknown location has its own prominent card; the queue is for past stays.
        visits.filter { $0.needsReview && !$0.isIgnored && $0.departure != nil }
    }
    private var current: Visit? {
        visits.first { ActivityLocationPolicy.isLocationVisit($0) && !$0.isIgnored && $0.departure == nil }
    }

    private var isWaitingForVisitConfirmation: Bool {
        guard current == nil, recorder.latestLocationTimestamp != nil else { return false }
        return recorder.authorization == .authorizedAlways || recorder.authorization == .authorizedWhenInUse
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lifeBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        header
                        if let review = reviewQueue.first { reviewCard(review) }
                        journey
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 36)
                }
            }
            .accessibilityIdentifier("timeline-screen")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $adding) { ManualVisitView() }
            .task {
                do {
                    let repaired = try ActivityLocationPolicy.resolveLocationCallbacks(context: context)
                    if repaired > 0 {
                        try context.save()
                        Diagnostics.record(context, subsystem: "Core Location",
                                           message: "Closed \(repaired) superseded open visit records.", severity: "info")
                    }
                } catch {
                    // Protected stores are retried when Timeline next appears.
                }
                if !automaticLocationDeduplicated {
                    do {
                        let removed = try ActivityLocationPolicy.deduplicateAutomaticLocations(context: context)
                        if removed > 0 { try context.save() }
                        automaticLocationDeduplicated = true
                    } catch {
                        // Retry after a protected-store failure on the next appearance.
                    }
                }
                if !staySplitsRejoined {
                    do {
                        // Must run before reconciliation, which then re-absorbs the
                        // walk that had been sitting between the two halves.
                        let rejoined = try ActivityLocationPolicy.rejoinStaysSplitByMovement(context: context)
                        if rejoined > 0 {
                            try context.save()
                            Diagnostics.record(context, subsystem: "Core Location",
                                               message: "Rejoined \(rejoined) stays split by movement.", severity: "info")
                        }
                        staySplitsRejoined = true
                    } catch {
                        // Retry after a protected-store failure on the next appearance.
                    }
                }
                // This migration-style cleanup used to scan the complete timeline on
                // every appearance. Large journal imports made that noticeable, so run
                // it once per installation/version; new visits are reconciled as they
                // arrive by LocationRecorder.
                guard !locationPolicyReconciled else { return }
                do {
                    // Journal-only imports do not contain device activity, so there is
                    // nothing to reconcile. This cheap check avoids a second full-history
                    // pass immediately after importing a large archive.
                    if visits.contains(where: ActivityLocationPolicy.isDeviceActivity) {
                        let startedAt = Date.now
                        try ActivityLocationPolicy.reconcileAll(context: context)
                        try ActivityLocationPolicy.updateTravelDescriptions(context: context)
                        try context.save()
                        Diagnostics.performance(context, subsystem: "Timeline", operation: "activity reconciliation",
                                                startedAt: startedAt, itemCount: visits.count)
                    }
                    locationPolicyReconciled = true
                } catch {
                    // Leave the flag unset so a transient protected-store failure can
                    // be retried on the next appearance.
                }
            }
            .task {
                // Refresh elapsed labels without polling Core Location or the store.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    clock = .now
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(greeting)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        // Two lines with a lower floor: now that the greeting scales
                        // with Dynamic Type, a single line would ellipsize at
                        // accessibility sizes rather than wrap.
                        .lineLimit(2).minimumScaleFactor(0.7)
                    Text(headerDate)
                        .font(.title3).foregroundStyle(.secondary)
                    if !reviewQueue.isEmpty {
                        Text("\(reviewQueue.count) \(reviewQueue.count == 1 ? "place" : "places") to review")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                            .padding(.top, 4)
                    }
                }
                Spacer()
                Button { adding = true } label: {
                    Image(systemName: "plus")
                        .font(.title2)
                        .frame(width: addButtonDiameter, height: addButtonDiameter)
                        .background(.regularMaterial, in: Circle())
                        .shadow(color: .black.opacity(0.04), radius: 12, y: 5)
                }.accessibilityLabel("Add visit")
            }
        }.padding(.top, 20)
    }

    private func reviewCard(_ visit: Visit) -> some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            VStack(alignment: .leading, spacing: 17) {
                Label("Review Queue", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                HStack(spacing: 14) {
                    ActivityIcon(activity: visit.activity, context: visit.displayPlaceName, color: .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        // A weak Apple Maps guess already has a name, so asking the
                        // person to agree with it reads very differently from asking
                        // them to identify a place LifeLog knows nothing about.
                        if visit.needsConfirmation {
                            Text("Is this right?").font(.headline).foregroundStyle(.primary)
                            Text(visit.placeName).font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text("Uncategorised location").font(.headline).foregroundStyle(.primary)
                            if !visit.hasPlaceholderName {
                                Text("Likely: \(visit.placeName)").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        Text("Suspected activity: \(visit.inferredActivity)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(visit.needsConfirmation ? "Check" : "Categorise")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 9))
                    Image(systemName: "chevron.right").foregroundStyle(.orange)
                }
            }
            .padding(18)
            .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.orange.opacity(0.3)))
        }.buttonStyle(.plain).accessibilityIdentifier("uncategorised-location-card")
    }

    private func currentCard(_ visit: Visit) -> some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Text("Current Activity").font(.headline.weight(.semibold)).foregroundStyle(.green)
                    Spacer()
                    if visit.needsCategorisation {
                        Label("Label", systemImage: "flag.fill")
                            .font(.caption.bold()).foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(visit.displayPlaceName).font(.title2.bold()).foregroundStyle(.primary)
                        if visit.needsCategorisation {
                            Text("Suspected activity: \(visit.inferredActivity)").foregroundStyle(.secondary)
                            if visit.placeName != "Identifying…" && visit.placeName != "Unknown place" {
                                Text("Likely place: \(visit.placeName)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } else {
                            Text(visit.activity).foregroundStyle(.secondary)
                        }
                        Text("Since \(dayQualifiedTime(visit.arrival)) · \(elapsedVisitDuration(visit))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    Spacer()
                    ActivityScene(activity: visit.suspectedActivity, context: visit.displayPlaceName)
                }
            }
            .padding(20)
            .background(Color.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.green.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.025), radius: 14, y: 7)
        }.buttonStyle(.plain).accessibilityIdentifier("current-location-card")
    }

    private var journey: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Today’s Journey").font(.system(.title, design: .rounded, weight: .bold))
            if today.isEmpty && current == nil && !isWaitingForVisitConfirmation {
                VStack(spacing: 14) {
                    Image(systemName: "location.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Your visits will appear here").font(.headline)
                    Text("Enable background logging in Settings or add a visit manually.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(32).lifeCard()
            } else {
                VStack(spacing: 12) {
                    if let current {
                        currentCard(current)
                    } else if isWaitingForVisitConfirmation {
                        waitingForVisitCard
                    }
                    let historicalVisits = today.filter { current?.id != $0.id }
                    ForEach(Array(historicalVisits.enumerated()), id: \.element.id) { index, visit in
                        JourneyRow(visit: visit, isCurrent: false,
                                   isFirst: current == nil && !isWaitingForVisitConfirmation && index == 0,
                                   isLast: index == historicalVisits.count - 1)
                    }
                }
            }
        }.accessibilityIdentifier("todays-journey")
    }

    private var waitingForVisitCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.green.opacity(0.12)).frame(width: 60, height: 60)
                ProgressView().tint(.green)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Current location").font(.headline.weight(.semibold))
                Text("Waiting for visit confirmation")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let timestamp = recorder.latestLocationTimestamp {
                    Text("Location received \(elapsedDescription(since: timestamp)) ago")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(20)
        .background(Color.green.opacity(0.045), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.green.opacity(0.3)))
        .accessibilityIdentifier("waiting-for-visit-confirmation")
        .accessibilityLabel("Current location, waiting for visit confirmation")
    }

    private func elapsedDescription(since date: Date) -> String {
        let seconds = max(0, Int(clock.timeIntervalSince(date)))
        let minutes = seconds / 60
        if minutes < 1 { return "just now" }
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }

    private func elapsedVisitDuration(_ visit: Visit) -> String {
        let totalMinutes = max(0, Int(clock.timeIntervalSince(visit.arrival) / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12: "Good Morning"
        case 12..<17: "Good Afternoon"
        default: "Good Evening"
        }
    }

    private var headerDate: String {
        let date = Date.now
        return "\(date.formatted(.dateTime.weekday(.wide))) \(date.formatted(.dateTime.day())) \(date.formatted(.dateTime.month(.wide)))"
    }
}

/// Distance as a person would say it: whole metres up to a kilometre, then one
/// decimal place, because "1.4 km" is a walk and "1,428 m" is a measurement.
func formattedDistance(_ metres: CLLocationDistance) -> String {
    metres < 1_000
        ? "\(Int(metres.rounded())) m"
        : String(format: "%.1f km", metres / 1_000)
}

/// Names the day a time fell on when it was not today. A night at home belongs to
/// this morning's timeline but began yesterday evening, and "6:12 pm – 7:20 am"
/// with no day would read as a stay of a few minutes.
private func dayQualifiedTime(_ date: Date) -> String {
    let time = date.formatted(date: .omitted, time: .shortened)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return time }
    if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
    return "\(date.formatted(.dateTime.day().month(.abbreviated))) \(time)"
}

private struct JourneyRow: View {
    let visit: Visit
    let isCurrent: Bool
    let isFirst: Bool
    let isLast: Bool
    private var color: Color { visit.needsCategorisation ? .orange : activityColor(visit.activity) }

    var body: some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            HStack(spacing: 0) {
                ZStack {
                    if !isFirst {
                        Rectangle().fill(Color.secondary.opacity(0.28)).frame(width: 2, height: 62).offset(y: -31)
                    }
                    if !isLast {
                        Rectangle().fill(Color.secondary.opacity(0.28)).frame(width: 2, height: 62).offset(y: 31)
                    }
                    Circle().fill(Color.lifeBackground).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(color, lineWidth: 2))
                        .overlay(Circle().fill(color).frame(width: 8, height: 8))
                }.frame(width: 38, height: 108)
                HStack(spacing: 14) {
                    ActivityIcon(activity: visit.suspectedActivity, context: visit.displayPlaceName,
                                 color: color, size: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        if visit.needsCategorisation {
                            Text("Uncategorised location").font(.headline.weight(.semibold)).foregroundStyle(.primary)
                            Text("Suspected: \(visit.inferredActivity)")
                                .font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            Text(visit.activity).font(.headline.weight(.semibold)).foregroundStyle(.primary)
                            // A journey is described by how far it went. Its place name
                            // is only ever "Walking workout", which says nothing.
                            Text(visit.hasRoute ? formattedDistance(visit.routeDistance) : visit.placeName)
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text(timeDescription).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(durationDescription)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                        status
                    }
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).frame(height: 108)
                .lifeCard()
            }
        }
        .accessibilityValue("Category colour \(categoryColorHex(forCategory: visit.insightCategory))")
        .buttonStyle(.plain)
    }

    @ViewBuilder private var status: some View {
        if visit.needsCategorisation {
            Label(isCurrent ? "Live · Categorise" : "Categorise", systemImage: "flag.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.orange.opacity(0.1), in: Capsule())
        } else if isCurrent {
            Label("Live", systemImage: "circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else {
            Text(visit.confidenceLabel).font(.caption.weight(.semibold)).foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.green.opacity(0.1), in: Capsule())
        }
    }

    private var timeDescription: String {
        let start = dayQualifiedTime(visit.arrival)
        if isCurrent { return "Since \(start)" }
        let end = (visit.departure ?? .now).formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private var durationDescription: String {
        let totalMinutes = max(0, Int(visit.duration / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}

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
private struct ActivityScene: View {
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
    let key = category.trimmingCharacters(in: .whitespacesAndNewlines)
    if let stored = UserDefaults.standard.string(forKey: "LifeLog.CategoryColor.\(key)"),
       let color = Color(hex: stored) { return color }
    switch key.lowercased() {
    case "home": return .green
    case "work": return .purple
    case "food & drink": return .orange
    case "shopping": return .indigo
    case "fitness": return .pink
    case "healthcare": return .red
    case "education": return .yellow
    case "travel": return .blue
    case "entertainment": return .purple
    case "social": return .teal
    case "sleep": return Color(red: 0.22, green: 0.40, blue: 0.52)
    default: return .gray
    }
}

func categoryColorHex(forCategory category: String) -> String {
    if let stored = UserDefaults.standard.string(forKey: "LifeLog.CategoryColor.\(category.trimmingCharacters(in: .whitespacesAndNewlines))") {
        return "#\(stored)"
    }
    let defaults: [String: String] = ["Home": "#34C759", "Work": "#AF52DE", "Food & Drink": "#FF9500",
                                      "Shopping": "#5856D6", "Fitness": "#FF2D55", "Healthcare": "#FF3B30",
                                      "Education": "#FFCC00", "Travel": "#007AFF", "Social": "#30B0C7", "Sleep": "#386680"]
    return defaults[category] ?? "#8E8E93"
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

struct VisitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var visit: Visit
    @Query(sort: \VisitCorrection.changedAt, order: .reverse) private var corrections: [VisitCorrection]
    @Query(sort: \Visit.arrival, order: .reverse) private var history: [Visit]
    @State private var saveFailed = false
    @State private var confirmingDelete = false
    @State private var correctionBaseline: VisitCorrectionSnapshot?
    @State private var mapPosition: MapCameraPosition = .automatic
    @State private var adjustingLocation = false
    @State private var showingNearbyPlaces = false
    private let activities = ["At home", "Working", "Eating", "Shopping", "Exercising", "Healthcare", "Studying", "Travelling", "Socialising", "Visiting"]

    private var availableActivities: [String] {
        let names = ActivityCatalog.load().map(\.name)
        return names.isEmpty ? activities : names
    }

    var body: some View {
        Form {
            if visit.needsCategorisation {
                Section {
                    Label("This place isn’t recognised yet", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Categorise it once and LifeLog will recognise this location next time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if canLearnPlace {
                    Section("Quick labels") {
                        Button {
                            applyQuickLabel(name: "Home", activity: "At home")
                        } label: {
                            Label("Set as Home", systemImage: "house.fill")
                        }
                        Button {
                            applyQuickLabel(name: "Work", activity: "Working")
                        } label: {
                            Label("Set as Work", systemImage: "building.2.fill")
                        }
                    }
                }
            }
            if visit.needsCategorisation && !visit.placeSuggestions.isEmpty {
                Section {
                    ForEach(visit.placeSuggestions) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: suggestion.suggestedActivity, context: suggestion.name,
                                             color: activityColor(suggestion.suggestedActivity), size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.name).foregroundStyle(.primary)
                                    Text("\(suggestion.suggestedActivity) · \(Int(suggestion.distance.rounded())) m away")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                    }
                } header: {
                    Text("Nearby places")
                } footer: {
                    Text("Suggestions are nearby public places from Apple Maps.")
                }
            }
            if visit.hasRoute {
                Section {
                    Map(position: $mapPosition) {
                        MapPolyline(coordinates: visit.route.map(\.coordinate))
                            .stroke(activityColor(visit.activity), lineWidth: 4)
                    }
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .mapControls { MapCompass() }
                    .accessibilityIdentifier("visit-route-map")
                    Text(routeSummary)
                        .font(.footnote).foregroundStyle(.secondary)
                } header: {
                    Text("Journey")
                } footer: {
                    // Said plainly, because this is the most precise location data
                    // LifeLog holds and the person should know it is here.
                    Text("The path this walk followed, recorded by Apple Health.")
                }
            }
            if visit.latitude != 0 || visit.longitude != 0 {
                Section {
                    if let coordinate = recordedCoordinate {
                        MapReader { proxy in
                            Map(position: $mapPosition) {
                                Marker("Recorded location", coordinate: coordinate)
                                    .tint(adjustingLocation ? .orange : .blue)
                            }
                            .frame(height: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .mapControls { MapCompass(); MapUserLocationButton() }
                            .onTapGesture(coordinateSpace: .local) { point in
                                guard adjustingLocation,
                                      let updated = proxy.convert(point, from: .local),
                                      CLLocationCoordinate2DIsValid(updated) else { return }
                                visit.latitude = updated.latitude
                                visit.longitude = updated.longitude
                                mapPosition = .region(region(centeredOn: updated))
                            }
                        }
                        .accessibilityIdentifier("visit-location-map-picker")
                        Text(adjustingLocation
                             ? "Tap the map to move the pin, then tap Done to save it."
                             : "Recorded at the location shown above.")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button {
                            adjustingLocation.toggle()
                        } label: {
                            Label(adjustingLocation ? "Finish adjusting pin" : "Adjust pin location",
                                  systemImage: adjustingLocation ? "checkmark.circle" : "mappin.and.ellipse")
                        }
                    } else {
                        Label("No map coordinate was recorded for this visit.", systemImage: "mappin.slash")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Map location")
                } footer: {
                    Text("Adjusting the pin changes this visit’s stored coordinate. It does not contact Apple Maps until you choose a place suggestion or save a place.")
                }
            }
            Section {
                TextField("Place name", text: $visit.placeName)
                if recordedCoordinate != nil {
                    Button {
                        showingNearbyPlaces = true
                    } label: {
                        Label("Choose nearby Apple Maps place", systemImage: "mappin.and.ellipse")
                    }
                }
                if visit.needsConfirmation {
                    // Without this there is no way to agree with a weak guess:
                    // dismissing the editor leaves the confidence untouched, so the
                    // visit would return to the review queue forever.
                    Button { confirmPlace() } label: {
                        Label("Yes, this is right", systemImage: "checkmark.circle.fill")
                    }
                    .accessibilityIdentifier("confirm-place")
                }
            } header: {
                Text("Place")
            } footer: {
                if visit.needsConfirmation {
                    Text("LifeLog matched this from Apple Maps but isn\u{2019}t confident. Confirming remembers it for future visits here; correcting the name teaches it instead.")
                }
            }
            Section("What were you doing?") {
                if !historicalActivities.isEmpty {
                    Menu {
                        ForEach(historicalActivities, id: \.self) { activity in
                            Button(activity) { visit.userActivity = activity }
                        }
                    } label: {
                        Label("Use a previous activity here", systemImage: "clock.arrow.circlepath")
                    }
                }
                Picker("Activity", selection: activityBinding) {
                    Text("Choose an activity").tag("")
                    ForEach(availableActivities, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or enter your own", text: activityBinding)
                TextField("Notes", text: $visit.note, axis: .vertical)
            }
            Text("Changing the activity or place type updates this visit. For a recognised location, saving also learns the choice for future check-ins; you can edit it again at any time.")
                .font(.footnote).foregroundStyle(.secondary)
            Section("Recognition") {
                LabeledContent("Confidence", value: visit.confidenceLabel)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Inferred activity evidence")
                        .font(.subheadline.weight(.semibold))
                    Text(inferenceEvidenceText)
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("This is an inference, not a confirmed fact. You can edit the activity above.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !matchingCorrections.isEmpty {
                    ForEach(matchingCorrections.prefix(5)) { correction in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(correction.reason).font(.caption.bold())
                            Text("\(correction.previousPlaceName) → \(correction.newPlaceName)")
                            Text("\(correction.previousActivity) → \(correction.newActivity)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("No corrections recorded for this visit yet.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Time") {
                DatePicker("Arrived", selection: $visit.arrival)
                DatePicker("Left", selection: Binding(get: { visit.departure ?? .now }, set: { visit.departure = $0 }))
            }
            if visit.latitude != 0 || visit.longitude != 0 {
                Section {
                    Button {
                        learnPlace()
                    } label: {
                        Label("Save & Learn Place", systemImage: "brain.head.profile")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canLearnPlace)
                } footer: {
                    Text("LifeLog will update a nearby saved geofence or create a new 100-metre geofence, then reuse this place and activity automatically.")
                }
            }
        }
        .navigationTitle(visit.needsCategorisation ? "Categorise Place" : "Visit")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingNearbyPlaces) {
            if let coordinate = recordedCoordinate {
                NearbyPlacePicker(coordinate: coordinate, arrival: visit.arrival) { suggestion in
                    select(suggestion)
                    visit.latitude = suggestion.latitude
                    visit.longitude = suggestion.longitude
                    showingNearbyPlaces = false
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Delete visit")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { saveAndDismiss() }
            }
        }
        .alert("Couldn’t save changes", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog left your existing timeline unchanged.")
        }
        .confirmationDialog("Delete this visit?", isPresented: $confirmingDelete) {
            Button("Delete visit", role: .destructive) { deleteVisit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("If the visits before and after it are the same place and activity, their time will be merged. Otherwise no surrounding visit will be guessed.")
        }
        .onAppear {
            if correctionBaseline == nil { correctionBaseline = currentSnapshot }
            if let coordinate = recordedCoordinate {
                mapPosition = .region(region(centeredOn: coordinate))
            }
        }
        .onDisappear {
            guard !saveFailed else { return }
            sanitizeVisit()
            try? persistChanges(forceLearning: false)
        }
    }

    private var activityBinding: Binding<String> {
        Binding(get: { visit.userActivity ?? "" }, set: { visit.userActivity = $0 })
    }

    private var historicalActivities: [String] {
        var values = history
            .filter { $0.id != visit.id && $0.placeName.caseInsensitiveCompare(visit.placeName) == .orderedSame }
            .map(\.activity)
        values.append(contentsOf: ActivityCatalog.load().map(\.name))
        return Array(Set(values)).filter { !$0.isEmpty }.sorted()
    }

    /// Whether the walk came back to where it started is the thing a person actually
    /// recognises about it — a loop from home reads differently from a walk somewhere.
    private var routeSummary: String {
        let points = visit.route
        guard let first = points.first, let last = points.last else { return "No path recorded" }
        let distance = formattedDistance(visit.routeDistance)
        let returned = last.location.distance(from: first.location) <= ActivityLocationPolicy.departureRadius
        return returned ? "\(distance) · returned to the start" : "\(distance) · ended elsewhere"
    }

    private var inferenceEvidenceText: String {
        var evidence = visit.inferenceEvidence
        let key = visit.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !key.isEmpty, key != "identifying…", key != "unknown place" {
            let recurrence = history.reduce(into: 0) { count, candidate in
                if candidate.id != visit.id,
                   candidate.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key {
                    count += 1
                }
            }
            if recurrence > 0 { evidence.append("Recurring place (\(recurrence) prior check-in\(recurrence == 1 ? "" : "s"))") }
        }
        return evidence.isEmpty ? "No inference evidence recorded" : evidence.joined(separator: " · ")
    }

    /// Accepts a weak Apple Maps guess as correct. The inferred activity becomes an
    /// explicit choice so the visit stops reading as a guess, and learning it saves
    /// the place for future arrivals.
    private func confirmPlace() {
        if visit.userActivity?.isEmpty != false {
            visit.userActivity = visit.inferredActivity
        }
        visit.recognitionConfidence = "confirmed"
        learnPlace()
    }

    private func learnPlace() {
        sanitizeVisit()
        do {
            try persistChanges(forceLearning: true)
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func select(_ suggestion: PlaceSuggestion) {
        visit.placeName = suggestion.name
        visit.userActivity = suggestion.suggestedActivity
        visit.recognitionConfidence = "confirmed"
    }

    private func applyQuickLabel(name: String, activity: String) {
        visit.placeName = name
        visit.userActivity = activity
        visit.recognitionConfidence = "confirmed"
        learnPlace()
    }

    private func saveAndDismiss() {
        sanitizeVisit()
        do {
            try persistChanges(forceLearning: false)
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func deleteVisit() {
        do {
            let all = try context.fetch(FetchDescriptor<Visit>(sortBy: [SortDescriptor(\.arrival)]))
            let previous = all.filter { $0.id != visit.id && ($0.departure ?? .now) <= visit.arrival }
                .max { $0.arrival < $1.arrival }
            let end = visit.departure ?? visit.arrival
            let next = all.filter { $0.id != visit.id && $0.arrival >= end }
                .min { $0.arrival < $1.arrival }
            if let previous, let next, sameActivityLocation(previous, next) {
                previous.departure = next.departure ?? next.arrival
            }
            context.delete(visit)
            try context.save()
            dismiss()
        } catch {
            saveFailed = true
        }
    }

    private func sameActivityLocation(_ lhs: Visit, _ rhs: Visit) -> Bool {
        let lhsPlace = lhs.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsPlace = rhs.placeName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lhsPlace == rhsPlace && lhs.activity.caseInsensitiveCompare(rhs.activity) == .orderedSame
    }

    private func sanitizeVisit() {
        PlaceLookupService.cancelAllLookups()
        visit.placeName = TextSafety.clean(visit.placeName, maximumLength: 120)
        visit.userActivity = visit.userActivity.map { TextSafety.clean($0, maximumLength: 80) }
        visit.note = TextSafety.clean(visit.note, maximumLength: 2_000)
        if let departure = visit.departure, departure < visit.arrival {
            visit.departure = visit.arrival
        }
    }

    private var canLearnPlace: Bool {
        (visit.latitude != 0 || visit.longitude != 0) &&
        !TextSafety.clean(visit.placeName, maximumLength: 100).isEmpty &&
        !TextSafety.clean(visit.activity, maximumLength: 80).isEmpty
    }

    private var recordedCoordinate: CLLocationCoordinate2D? {
        let coordinate = CLLocationCoordinate2D(latitude: visit.latitude, longitude: visit.longitude)
        guard CLLocationCoordinate2DIsValid(coordinate),
              coordinate.latitude != 0 || coordinate.longitude != 0 else { return nil }
        return coordinate
    }

    private func region(centeredOn coordinate: CLLocationCoordinate2D) -> MKCoordinateRegion {
        MKCoordinateRegion(center: coordinate,
                           span: MKCoordinateSpan(latitudeDelta: 0.004, longitudeDelta: 0.004))
    }

    private var currentSnapshot: VisitCorrectionSnapshot {
        VisitCorrectionSnapshot(
            placeName: visit.placeName,
            activity: visit.userActivity ?? visit.inferredActivity,
            confidence: visit.recognitionConfidence ?? "pending"
        )
    }

    private var matchingCorrections: [VisitCorrection] {
        corrections.filter {
            abs($0.visitArrival.timeIntervalSince(visit.arrival)) < 1 &&
            abs($0.latitude - visit.latitude) < 0.00001 &&
            abs($0.longitude - visit.longitude) < 0.00001
        }
    }

    private func persistChanges(forceLearning: Bool) throws {
        let corrected = correctionBaseline.map { $0 != currentSnapshot } ?? false
        if forceLearning || corrected {
            let result = try SavedPlaceLearning.upsert(
                from: visit,
                previousPlaceName: correctionBaseline?.placeName,
                context: context
            )
            if result == nil {
                CorrectionHistory.record(visit: visit, from: correctionBaseline ?? currentSnapshot,
                                         context: context, reason: "Manual correction")
                try context.save()
            }
        } else {
            try context.save()
        }
        InsightsInvalidation.invalidate(reason: corrected ? "visit correction" : "visit edit", context: context)
        correctionBaseline = currentSnapshot
    }
}

private struct NearbyPlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    let coordinate: CLLocationCoordinate2D
    let arrival: Date
    let onSelect: (PlaceSuggestion) -> Void
    @State private var suggestions: [PlaceSuggestion] = []
    @State private var isLoading = true
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Searching Apple Maps…")
                } else if failed || suggestions.isEmpty {
                    ContentUnavailableView("No nearby places found", systemImage: "mappin.slash",
                                           description: Text("Try adjusting the pin or enter the place name manually."))
                } else {
                    List(suggestions) { suggestion in
                        Button {
                            onSelect(suggestion)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: suggestion.suggestedActivity,
                                             context: suggestion.name,
                                             color: activityColor(suggestion.suggestedActivity), size: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.name).foregroundStyle(.primary)
                                    Text("\(suggestion.suggestedActivity) · \(Int(suggestion.distance.rounded())) m away")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Nearby Apple Maps Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .task {
                do {
                    let result = try await PlaceLookupService.nearbyPlaces(at: coordinate, radius: 250, arrival: arrival)
                    suggestions = result.suggestions
                } catch {
                    failed = true
                }
                isLoading = false
            }
        }
    }
}
