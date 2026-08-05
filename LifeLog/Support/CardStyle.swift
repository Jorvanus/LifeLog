import SwiftUI

/// The single elevated-card treatment used by Timeline and Insights.
///
/// This previously existed as three near-identical private copies — `lifeCard`
/// in TimelineView and both `insightsCard` and `insightCard` in TrendsView. The
/// two TrendsView variants differed only by 2pt of corner radius yet were
/// applied to sibling cards in the same stack, so adjacent cards on Insights
/// rendered with visibly mismatched corners.
extension View {
    func lifeCard() -> some View {
        background(Color.lifeCard, in: RoundedRectangle(cornerRadius: 22))
            .shadow(color: .black.opacity(0.045), radius: 12, y: 5)
    }
}
