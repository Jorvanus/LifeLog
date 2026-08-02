import SwiftUI
import SwiftData
import MapKit

struct MapView: View {
    // Map annotations require coordinates, so avoid loading journal imports and
    // other zero-coordinate records into MapKit at startup.
    @Query(filter: #Predicate<Visit> { $0.latitude != 0 || $0.longitude != 0 },
           sort: \Visit.arrival, order: .reverse) private var visits: [Visit]
    @Query(sort: \SavedPlace.name) private var places: [SavedPlace]
    private var locatedVisits: [Visit] { visits.filter { !$0.isIgnored } }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map {
                    ForEach(locatedVisits) { visit in
                        Annotation(visit.placeName, coordinate: .init(latitude: visit.latitude, longitude: visit.longitude)) {
                            ActivityIcon(activity: visit.activity, category: visit.placeCategory,
                                         color: activityColor(visit.activity)).scaleEffect(0.72)
                        }
                    }
                    UserAnnotation()
                }
                if locatedVisits.isEmpty {
                    ContentUnavailableView("No places to map", systemImage: "map",
                                           description: Text("Automatically recorded visits will appear here."))
                        .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding()
                } else {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(locatedVisits.count) recorded places").font(.headline)
                            Text("Your private location history").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "location.fill").foregroundStyle(.blue)
                    }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20)).padding()
                }
            }.navigationTitle("Map").accessibilityIdentifier("map-screen")
        }
    }
}
