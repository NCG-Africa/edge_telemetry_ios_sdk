// Internal — invisible from `import EdgeRum`.
//
// The real Recorder façade lands with F3 (issue #36). This stub keeps
// the target non-empty during F1 bootstrap.

import Foundation

internal enum EdgeRumCoreModuleStub {
    internal static let marker: String = "EdgeRumCore"
}
