import SwiftUI
import SwiftData

struct PlacesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    var body: some View {
        NavigationStack {
            List {
                ForEach(places) { place in
                    VStack(alignment: .leading) {
                        TextField("Name", text: Bindable(place).name).font(.headline)
                        TextField("Default activity", text: Bindable(place).defaultActivity).foregroundStyle(.secondary)
                    }
                }.onDelete { $0.map { places[$0] }.forEach(context.delete) }
                Section { Text("Name a place from a timeline visit to help LifeLog recognize it next time.").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("Known places")
        }
    }
}

