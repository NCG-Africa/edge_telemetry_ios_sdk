// EdgeRum — public umbrella module.
//
// The full surface lands with F2 (issues #29–#35). This stub exists so
// the package builds end-to-end during the F1 bootstrap.

/// Top-level entry point for the EdgeRum SDK.
///
/// This namespace is a caseless `enum` so it cannot be instantiated.
/// The full public surface (`start`, `identify`, `track`, `time`,
/// `captureError`, etc.) is added by F2.
public enum EdgeRum {
    /// SemVer string for this build of the SDK, sent as the
    /// `sdk.version` attribute on every event.
    ///
    /// Sourced at build time from the repo-root `VERSION` file via
    /// `EdgeRumVersionPlugin` — see PLAN-iOS.md §2.6.
    public static let sdkVersion: String = EdgeRumGeneratedVersion.string
}
