import Foundation
import SwiftData

// TraxKit's versioned schema. The store now lives in the host's App Group, so it
// MUST go through VersionedSchema + a MigrationPlan (the host app's hard rule for
// any App-Group SwiftData store).
//
// V1 is the rebuild's initial version — top-level @Model entities listed here, no
// migration stage yet. Any FUTURE reshape of a shipped entity freezes its current
// definition as a nested @Model inside a `TraxSchemaV<n>` enum (same simple class
// name) and adds a MigrationStage; never edit a shipped entity in place.

enum TraxSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [ShareEntity.self, ContactEntity.self, PlaceEntity.self,
         TransitionEntity.self, SyncCursorEntity.self]
    }
}

enum TraxMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TraxSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
