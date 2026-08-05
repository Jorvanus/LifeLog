import SwiftUI

/// Choosing an icon from a grid rather than a menu.
///
/// A menu was workable for ten symbols and unusable for eighty: it is a long scroll
/// through single-file rows, and you cannot see the shapes side by side, which is the
/// only way anyone actually picks an icon.
struct ActivityIconPicker: View {
    @Binding var symbol: String
    /// Tints the grid the way the activity will actually look on the timeline.
    var tint: Color = .blue
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 58), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22, pinnedViews: [.sectionHeaders]) {
                // An icon the app set but this list does not offer still has to be
                // shown, or its activity would appear to have no icon at all and
                // choosing anything would silently discard it.
                if !ActivityIcons.contains(symbol) {
                    section(title: "Current", symbols: [symbol])
                }
                ForEach(ActivityIcons.groups) { group in
                    section(title: group.name, symbols: group.symbols)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 28)
        }
        .navigationTitle("Icon")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("activity-icon-picker")
    }

    private func section(title: String, symbols: [String]) -> some View {
        Section {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(symbols, id: \.self) { option in
                    Button {
                        symbol = option
                        dismiss()
                    } label: {
                        Image(systemName: option)
                            .font(.title2)
                            .foregroundStyle(option == symbol ? .white : tint)
                            .frame(width: 58, height: 58)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(option == symbol ? AnyShapeStyle(tint) : AnyShapeStyle(.quaternary))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option)
                    .accessibilityAddTraits(option == symbol ? [.isSelected] : [])
                }
            }
        } header: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background(Color.lifeBackground)
        }
    }
}
