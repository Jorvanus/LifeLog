import Foundation
import SwiftData

/// A structural fingerprint of a `VersionedSchema` -- built from each entity's name
/// and its properties' names, types, optionality, and uniqueness, plus any
/// uniqueness constraints -- used to detect an accidental edit to a frozen schema
/// version. See the note atop `LifeLogSchema.swift` for why a frozen version must
/// never change, and `SchemaFingerprintTests` for the recorded values this pins
/// against.
///
/// Deliberately not `Schema`'s own `Codable`/`Hashable` conformance: both walk
/// `entities` and `properties` in whatever order the underlying `Set` enumerates
/// them in, which is not guaranteed stable across processes, and a fingerprint
/// that flips on process restart rather than on a real schema edit would be
/// worse than no fingerprint at all. Sorting entities and properties by name
/// before describing them makes this deterministic.
enum SchemaFingerprint {
    static func of(_ type: any VersionedSchema.Type) -> String {
        Schema(versionedSchema: type).entities
            .sorted { $0.name < $1.name }
            .map(describe)
            .joined(separator: "\n")
    }

    private static func describe(_ entity: Schema.Entity) -> String {
        let properties = entity.properties
            .sorted { $0.name < $1.name }
            .map { property -> String in
                var text = "\(property.name):\(String(reflecting: property.valueType))"
                if property.isOptional { text += "?" }
                if property.isUnique { text += ":unique" }
                return text
            }
            .joined(separator: ",")
        let constraints = entity.uniquenessConstraints
            .map { $0.sorted().joined(separator: "+") }
            .sorted()
            .joined(separator: "|")
        return "\(entity.name)[\(properties)]{\(constraints)}"
    }
}
