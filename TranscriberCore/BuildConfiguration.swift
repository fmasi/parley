/// Whether this binary is a debug (`-Onone`) or a release (optimised) build (#271).
///
/// The capture helper stamps `name` into its `captureStart` diagnostic event, so a recording's
/// diagnostics say which kind of build made it: a timing or an allocation count taken on a debug
/// build is not the shipped app's (gotcha 84).
///
/// SwiftPM compiles every target of the package in one configuration and defines `DEBUG` only in
/// the debug one, so the answer compiled into `TranscriberCore` is also the answer for the app and
/// the helper that link it.
///
/// Computed, not stored: a stored `static let` is initialised behind a once-token on its first read.
public enum BuildConfiguration {

    public static var isDebug: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// `"debug"` or `"release"`. Written into recordings' diagnostics: do not rename.
    public static var name: String { name(isDebug: isDebug) }

    public static func name(isDebug: Bool) -> String {
        isDebug ? "debug" : "release"
    }
}
