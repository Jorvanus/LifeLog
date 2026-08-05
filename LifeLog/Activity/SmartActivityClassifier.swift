import Foundation
import FoundationModels

/// Uses Apple Intelligence on-device. Coordinates and free-form notes are never included in a prompt.
enum SmartActivityClassifier {
    struct Classification: Sendable {
        let category: String
        let activity: String
        let confidence: Int
    }

    static var availabilityDescription: String {
        let model = SystemLanguageModel(useCase: .contentTagging)
        switch model.availability {
        case .available:
            return model.supportsLocale() ? "Available on device" : "Unavailable for this language"
        case .unavailable(.deviceNotEligible):
            return "This device doesn’t support Apple Intelligence"
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence to use smart classification"
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still preparing"
        @unknown default:
            return "Apple Intelligence availability is unknown"
        }
    }

    static func classify(placeName: String, mapCategory: String, arrival: Date) async -> Classification? {
        let model = SystemLanguageModel(useCase: .contentTagging)
        guard model.isAvailable, model.supportsLocale() else { return nil }

        let instructions: String? = """
            Classify an everyday venue into one category and one likely activity.
            Be conservative: return Other and Visiting when the venue label is ambiguous.
            Never infer health conditions, religion, politics, relationships, or other sensitive traits.
            """
        let session = LanguageModelSession(model: model, tools: [], instructions: instructions)
        let timeBand = timeBand(for: arrival)
        let prompt = """
            Venue label: \(TextSafety.clean(placeName, maximumLength: 100))
            Apple Maps category: \(TextSafety.clean(mapCategory, maximumLength: 40))
            Approximate time band: \(timeBand)
            """

        do {
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedPlaceClassification.self,
                options: GenerationOptions(temperature: 0, maximumResponseTokens: 80)
            )
            return Classification(
                category: response.content.category,
                activity: response.content.activity,
                confidence: response.content.confidence
            )
        } catch {
            return nil
        }
    }

    private static func timeBand(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<11: "morning"
        case 11..<14: "midday"
        case 14..<18: "afternoon"
        case 18..<22: "evening"
        default: "night"
        }
    }
}

@Generable(description: "A conservative classification of an everyday venue")
private struct GeneratedPlaceClassification {
    @Guide(
        description: "Broad venue category",
        .anyOf(["Home", "Work", "Food & Drink", "Shopping", "Fitness", "Healthcare", "Education", "Travel", "Social", "Other"])
    )
    var category: String

    @Guide(
        description: "Most likely activity at the venue",
        .anyOf(["At home", "Working", "Eating", "Shopping", "Exercising", "Healthcare", "Studying", "Travelling", "Socialising", "Visiting"])
    )
    var activity: String

    @Guide(description: "Confidence from 0 to 100", .range(0...100))
    var confidence: Int
}
