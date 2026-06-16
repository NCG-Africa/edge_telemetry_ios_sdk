// Internal — invisible from `import EdgeRum`.
//
// PLCrashReporter integration + crash sidecar + replay land with F14
// (issues #73–#76). This stub exercises the binary target so any
// missing slice fails at F1 build time, not at F14 ship time.

import Foundation
#if canImport(CrashReporter)
@_implementationOnly import CrashReporter
#endif

internal enum EdgeRumCrashModuleStub {
    internal static let marker: String = "EdgeRumCrash"
}
