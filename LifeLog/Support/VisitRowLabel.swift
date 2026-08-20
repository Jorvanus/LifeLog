import SwiftUI

/// The shared shape of a row that represents one recorded visit: a title, and its
/// arrival time as a caption below. What the title shows — a place name, an
/// activity, wherever the caller is already fixed on one and wants the other — and
/// how the row navigates are the caller's choice; only the layout is shared, so a
/// future visual change (a duration, an icon) has one place to make it instead of
/// however many call sites happen to exist.
struct VisitRowLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline).lineLimit(1)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
    }
}
