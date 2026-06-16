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
    /// During F1 this is a hard-coded placeholder; F1/T1.3 swaps in a
    /// build-plugin-generated constant sourced from the repo-root
    /// `VERSION` file.
    public static let sdkVersion: String = "0.0.0-dev"
}
