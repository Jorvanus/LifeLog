import SwiftUI
import SwiftData

struct TimelineView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    @State private var adding = false

    private var today: [Visit] { visits.filter { Calendar.current.isDateInToday($0.arrival) } }
    private var reviewQueue: [Visit] { visits.filter(\.needsCategorisation) }
    private var current: Visit? { visits.first { $0.departure == nil } }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.lifeBackground.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        header
                        if let review = reviewQueue.first { reviewCard(review) }
                        if let current { currentCard(current) }
                        journey
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 28)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $adding) { ManualVisitView() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(greeting).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        .font(.title3).foregroundStyle(.secondary)
                    if !reviewQueue.isEmpty {
                        Text("\(reviewQueue.count) \(reviewQueue.count == 1 ? "place" : "places") to categorise")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.orange)
                            .padding(.top, 4)
                    }
                }
                Spacer()
                Button { adding = true } label: {
                    Image(systemName: "plus").font(.title2.weight(.medium)).frame(width: 50, height: 50)
                        .background(.thinMaterial, in: Circle())
                }.accessibilityLabel("Add visit")
            }
        }.padding(.top, 18)
    }

    private func reviewCard(_ visit: Visit) -> some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            VStack(alignment: .leading, spacing: 17) {
                Label("Review Queue", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                HStack(spacing: 14) {
                    ActivityIcon(activity: visit.activity, category: visit.placeCategory, color: .orange)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(visit.placeName).font(.headline).foregroundStyle(.primary)
                    Text("Suggested: \(visit.inferredActivity)").font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Categorise").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 15).padding(.vertical, 8)
                        .background(.orange.gradient, in: RoundedRectangle(cornerRadius: 9))
                    Image(systemName: "chevron.right").foregroundStyle(.orange)
                }
            }
            .padding(18)
            .background(Color.orange.opacity(0.065), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.orange.opacity(0.3)))
        }.buttonStyle(.plain)
    }

    private func currentCard(_ visit: Visit) -> some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 10) {
                    Circle().fill(.green).frame(width: 10, height: 10)
                    Text("Current Activity").font(.headline).foregroundStyle(.green)
                }
                HStack(spacing: 14) {
                    ActivityIcon(activity: visit.activity, category: visit.placeCategory, color: .green)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(visit.placeName).font(.title3.bold()).foregroundStyle(.primary)
                        Text(visit.activity).foregroundStyle(.secondary)
                        Text("Since \(visit.arrival.formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "house.and.flag.fill").font(.system(size: 48))
                        .foregroundStyle(.green.opacity(0.25))
                }
            }
            .padding(19)
            .background(Color.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.green.opacity(0.25)))
        }.buttonStyle(.plain)
    }

    private var journey: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Today’s Journey").font(.title2.bold())
            if today.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "location.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Your visits will appear here").font(.headline)
                    Text("Enable background logging in Settings or add a visit manually.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(32).lifeCard()
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(today.enumerated()), id: \.element.id) { index, visit in
                        JourneyRow(visit: visit, isFirst: index == 0, isLast: index == today.count - 1)
                    }
                }
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 0..<12: "Good Morning"
        case 12..<17: "Good Afternoon"
        default: "Good Evening"
        }
    }
}

private struct JourneyRow: View {
    let visit: Visit
    let isFirst: Bool
    let isLast: Bool
    private var color: Color { activityColor(visit.activity) }

    var body: some View {
        NavigationLink { VisitEditor(visit: visit) } label: {
            HStack(spacing: 0) {
                ZStack {
                    if !isFirst { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2).offset(y: -34) }
                    if !isLast { Rectangle().fill(Color.secondary.opacity(0.2)).frame(width: 2).offset(y: 34) }
                    Circle().fill(color).frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Color.lifeBackground, lineWidth: 3))
                }.frame(width: 28, height: 94)
                HStack(spacing: 14) {
                    ActivityIcon(activity: visit.activity, category: visit.placeCategory, color: color)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(visit.activity).font(.headline).foregroundStyle(.primary)
                        Text(visit.placeName).font(.subheadline).foregroundStyle(.secondary)
                        Text(timeDescription).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 8) {
                        Text(durationDescription)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                        status
                    }
                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14).frame(height: 94)
                .lifeCard()
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var status: some View {
        if visit.departure == nil {
            Label("Live", systemImage: "circle.fill").font(.caption.weight(.semibold)).foregroundStyle(.green)
                .labelStyle(.titleAndIcon)
        } else if visit.needsCategorisation {
            Text("Categorise").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.orange.opacity(0.1), in: Capsule())
        } else {
            Text("High").font(.caption.weight(.semibold)).foregroundStyle(.green)
                .padding(.horizontal, 10).padding(.vertical, 6).background(.green.opacity(0.1), in: Capsule())
        }
    }

    private var timeDescription: String {
        let start = visit.arrival.formatted(date: .omitted, time: .shortened)
        if let departure = visit.departure { return "\(start) – \(departure.formatted(date: .omitted, time: .shortened))" }
        return "Since \(start)"
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
    let category: String
    let color: Color
    var body: some View {
        Image(systemName: symbol).font(.title2.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 54, height: 54).background(color.gradient, in: Circle())
    }
    private var symbol: String {
        let text = "\(activity) \(category)".lowercased()
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
        if text.contains("travel") { return "car.fill" }
        return "mappin"
    }
}

func activityColor(_ activity: String) -> Color {
    let text = activity.lowercased()
    if text.contains("home") { return .green }
    if text.contains("work") { return .purple }
    if text.contains("eat") || text.contains("lunch") { return .orange }
    if text.contains("exercise") { return .pink }
    if text.contains("walk") || text.contains("run") { return .teal }
    if text.contains("cycl") || text.contains("travel") { return .blue }
    if text.contains("sleep") { return Color(red: 0.22, green: 0.40, blue: 0.52) }
    return .blue
}

private extension View {
    func lifeCard() -> some View {
        background(Color.lifeCard, in: RoundedRectangle(cornerRadius: 20))
            .shadow(color: .black.opacity(0.045), radius: 12, y: 5)
    }
}

extension Color {
    static let lifeBackground = Color(uiColor: .systemGroupedBackground)
    static let lifeCard = Color(uiColor: .secondarySystemGroupedBackground)
}

struct VisitEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Bindable var visit: Visit
    @State private var saveFailed = false
    @State private var correctionBaseline: VisitCorrectionSnapshot?
    private let categories = ["Home", "Work", "Food & Drink", "Shopping", "Fitness", "Healthcare", "Education", "Travel", "Social", "Other"]
    private let activities = ["At home", "Working", "Eating", "Shopping", "Exercising", "Healthcare", "Studying", "Travelling", "Socialising", "Visiting"]

    var body: some View {
        Form {
            if visit.needsCategorisation {
                Section {
                    Label("This place isn’t recognised yet", systemImage: "questionmark.circle.fill")
                        .foregroundStyle(.orange)
                    Text("Categorise it once and LifeLog will recognise this location next time.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if visit.needsCategorisation && !visit.placeSuggestions.isEmpty {
                Section {
                    ForEach(visit.placeSuggestions) { suggestion in
                        Button {
                            select(suggestion)
                        } label: {
                            HStack(spacing: 12) {
                                ActivityIcon(activity: suggestion.suggestedActivity, category: suggestion.category,
                                             color: activityColor(suggestion.suggestedActivity))
                                    .scaleEffect(0.72).frame(width: 42, height: 42)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(suggestion.name).foregroundStyle(.primary)
                                    Text("\(suggestion.category) · \(Int(suggestion.distance.rounded())) m away")
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
            Section("Place") {
                TextField("Place name", text: $visit.placeName)
                Picker("Category", selection: $visit.placeCategory) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }
            }
            Section("What were you doing?") {
                Picker("Activity", selection: activityBinding) {
                    Text("Choose an activity").tag("")
                    ForEach(activities, id: \.self) { Text($0).tag($0) }
                }
                TextField("Or enter your own", text: activityBinding)
                TextField("Notes", text: $visit.note, axis: .vertical)
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
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { saveAndDismiss() }
            }
        }
        .alert("Couldn’t save changes", isPresented: $saveFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("LifeLog left your existing timeline unchanged.")
        }
        .onAppear {
            if correctionBaseline == nil { correctionBaseline = currentSnapshot }
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
        visit.placeCategory = suggestion.category
        visit.userActivity = suggestion.suggestedActivity
        visit.recognitionConfidence = "confirmed"
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

    private func sanitizeVisit() {
        visit.placeName = TextSafety.clean(visit.placeName, maximumLength: 120)
        visit.placeCategory = TextSafety.clean(visit.placeCategory, maximumLength: 40)
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

    private var currentSnapshot: VisitCorrectionSnapshot {
        VisitCorrectionSnapshot(
            placeName: visit.placeName,
            category: visit.placeCategory,
            activity: visit.userActivity ?? visit.inferredActivity
        )
    }

    private func persistChanges(forceLearning: Bool) throws {
        let corrected = correctionBaseline.map { $0 != currentSnapshot } ?? false
        if forceLearning || corrected {
            let result = try SavedPlaceLearning.upsert(
                from: visit,
                previousPlaceName: correctionBaseline?.placeName,
                context: context
            )
            if result == nil { try context.save() }
        } else {
            try context.save()
        }
        correctionBaseline = currentSnapshot
    }
}

private struct VisitCorrectionSnapshot: Equatable {
    let placeName: String
    let category: String
    let activity: String
}
