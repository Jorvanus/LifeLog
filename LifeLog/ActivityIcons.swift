import Foundation

/// The icons an activity can be given.
///
/// This was ten symbols hard-coded in the editor, and none of them were the ones the
/// app itself ships with — so opening "Coffee" or "Beers" showed a picker with
/// nothing selected, and the icon appeared to have been lost.
///
/// Grouped rather than one long list because choosing an icon is a browsing task:
/// you know roughly what kind of thing you want before you know which symbol.
/// A symbol only earns a place here if it names something a person does.
enum ActivityIcons {
    struct Group: Identifiable, Sendable {
        let name: String
        let symbols: [String]
        var id: String { name }
    }

    static let groups: [Group] = [
        Group(name: "Home", symbols: [
            "house.fill", "bed.double.fill", "sofa.fill", "shower.fill", "washer.fill",
            "frying.pan.fill", "hammer.fill", "wrench.and.screwdriver.fill", "leaf.fill",
            "trash.fill", "sun.max.fill", "moon.zzz.fill"
        ]),
        Group(name: "Work & study", symbols: [
            "briefcase.fill", "building.2.fill", "desktopcomputer", "laptopcomputer",
            "person.2.badge.gearshape.fill", "phone.fill", "envelope.fill",
            "book.fill", "graduationcap.fill", "pencil.and.ruler.fill", "text.book.closed.fill"
        ]),
        Group(name: "Food & drink", symbols: [
            "fork.knife", "cup.and.saucer.fill", "mug.fill", "wineglass.fill",
            "takeoutbag.and.cup.and.straw.fill", "birthday.cake.fill", "carrot.fill",
            "popcorn.fill", "sunrise.fill"
        ]),
        Group(name: "Shopping & money", symbols: [
            "bag.fill", "cart.fill", "creditcard.fill", "banknote.fill", "gift.fill",
            "shippingbox.fill"
        ]),
        Group(name: "Fitness", symbols: [
            "figure.run", "figure.walk", "figure.hiking", "figure.pool.swim",
            "figure.strengthtraining.traditional", "figure.yoga", "bicycle",
            "dumbbell.fill", "sportscourt.fill", "soccerball", "tennis.racket"
        ]),
        Group(name: "Health", symbols: [
            "cross.case.fill", "heart.fill", "stethoscope", "pills.fill",
            "bandage.fill", "brain.head.profile.fill", "drop.fill"
        ]),
        Group(name: "Travel", symbols: [
            "car.fill", "bus.fill", "tram.fill", "airplane", "ferry.fill",
            "fuelpump.fill", "bolt.car.fill", "suitcase.fill", "map.fill",
            "mappin.and.ellipse", "road.lanes", "globe.americas.fill"
        ]),
        Group(name: "Outdoors", symbols: [
            "mountain.2.fill", "tree.fill", "beach.umbrella.fill", "water.waves",
            "tent.fill", "binoculars.fill", "camera.fill"
        ]),
        Group(name: "Going out", symbols: [
            "film.fill", "music.mic", "music.note", "headphones", "theatermasks.fill",
            "gamecontroller.fill", "party.popper.fill", "balloon.fill", "ticket.fill"
        ]),
        Group(name: "People & pets", symbols: [
            "person.2.fill", "person.3.fill", "figure.2",
            "figure.2.and.child.holdinghands", "figure.and.child.holdinghands",
            "pawprint.fill", "dog.fill", "cat.fill", "hand.wave.fill"
        ]),
        Group(name: "Other", symbols: [
            "circle.fill", "star.fill", "flag.fill", "clock.fill", "calendar",
            "bell.fill", "questionmark.circle.fill"
        ])
    ]

    static var all: [String] { groups.flatMap(\.symbols) }

    static func contains(_ symbol: String) -> Bool {
        all.contains(symbol)
    }
}
