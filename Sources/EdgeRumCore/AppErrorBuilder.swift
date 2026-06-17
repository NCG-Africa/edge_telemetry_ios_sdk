// Sources/EdgeRumCore/AppErrorBuilder.swift
//
// Pure helper that flattens an `Error` value into the wire-attribute
// bag emitted by `EdgeRum.captureError`. Owns:
//
//   - `cause = "AppError"`, `runtime = "swift"`
//   - `error.type` (Swift type name or NSError class)
//   - `error.kind` discriminator (`"swift"` / `"nserror"`)
//   - `error.domain`, `error.code`, `error.message`
//   - `error.userInfo.<key>` flattening for NSError, dropping any
//     non-primitive values (logged when `debug == true`)
//   - `error.stack` from a caller-captured `[String]`, truncated
//     to a UTF-8-safe byte cap
//   - `crash.context.<key>` prefix on caller-supplied context
//
// Stack capture itself MUST happen at the public call site
// (`EdgeRum.captureError`) — by the time the builder runs the bag is
// the only thing that matters, so we accept frames as a parameter.
//
// Refs: PLAN-iOS.md §6.6, §F13/T13.1, §F13/T13.2; CLAUDE.md
//       "Recorder + transport implementation notes".
//

import Foundation
import os.log

/// Pure flattener — no I/O, no global state, no recorder access.
public enum AppErrorBuilder {

    /// Soft cap on the joined `error.stack` payload. Mirrors the
    /// `RunLoopObserverCapture.maxStackBytes` precedent so a deep
    /// stack can't balloon a batch.
    public static let maxStackBytes: Int = 4_096

    /// Build the full wire-attribute bag for an `app.crash` event with
    /// `cause = "AppError"`.
    ///
    /// - Parameters:
    ///   - error: the value reported via `EdgeRum.captureError`.
    ///   - context: caller-supplied context. Keys are prefixed with
    ///     `crash.context.` on the wire (PLAN-iOS.md §F13/T13.1).
    ///   - stack: frames captured at the public call site via
    ///     `Thread.callStackSymbols`. Truncated UTF-8-safely to
    ///     `maxStackBytes`.
    ///   - debug: when `true`, dropped non-primitive `userInfo`
    ///     entries are logged via `os_log`.
    public static func build(
        error: Error,
        context: [String: AttributeValue],
        stack: [String],
        debug: Bool
    ) -> [String: AttributeValue] {
        var attrs: [String: AttributeValue] = [:]
        attrs["cause"] = .string("AppError")
        attrs["runtime"] = .string("swift")
        attrs["error.type"] = .string(String(describing: type(of: error)))
        attrs["error.message"] = .string(messageString(for: error))

        // Every `Error` bridges to `NSError` on Apple platforms with a
        // synthetic `domain == "<MangledTypeName>"` / `code == 0` —
        // useful for routing but only meaningful when the host
        // explicitly threw an `NSError`. `error is NSError` is the
        // disambiguator the iOS SDK runtime gives us.
        let ns = error as NSError
        if isExplicitNSError(error) {
            attrs["error.kind"] = .string("nserror")
            attrs["error.domain"] = .string(ns.domain)
            attrs["error.code"] = .int(ns.code)
            mergeUserInfo(ns.userInfo, into: &attrs, debug: debug)
        } else {
            attrs["error.kind"] = .string("swift")
            // Bridged Swift errors still carry a domain (the type
            // name) and a code — useful for backend bucketing without
            // misrepresenting the source as a Cocoa NSError.
            attrs["error.domain"] = .string(ns.domain)
            attrs["error.code"] = .int(ns.code)
        }

        let stackString = truncateStack(stack, maxBytes: maxStackBytes)
        if !stackString.isEmpty {
            attrs["error.stack"] = .string(stackString)
        }

        for (key, value) in context {
            attrs["crash.context.\(key)"] = value
        }

        return attrs
    }

    // MARK: - Internals (exposed for unit tests)

    /// `String` join of `frames` with `"\n"` separator, clipped to
    /// `maxBytes` UTF-8 bytes. Drops trailing frames whole rather than
    /// mid-symbol so the result is always a valid UTF-8 substring.
    public static func truncateStack(_ frames: [String], maxBytes: Int) -> String {
        var accum: [String] = []
        var size = 0
        for frame in frames {
            let frameSize = frame.utf8.count + 1 // include the join '\n'
            if size + frameSize > maxBytes { break }
            accum.append(frame)
            size += frameSize
        }
        return accum.joined(separator: "\n")
    }

    /// Distinguish an explicit `NSError` instance from a Swift error
    /// that the runtime *bridged* to `NSError` automatically. Only the
    /// former should expose `error.userInfo.*` on the wire.
    ///
    /// `type(of: error)` returns the dynamic type of the existential
    /// value — for a Swift `enum`/`struct` that's the Swift type
    /// itself (which fails the `is NSError.Type` test), and for a
    /// host-allocated `NSError(domain:...)` it's `NSError` itself
    /// (which passes).
    static func isExplicitNSError(_ error: Error) -> Bool {
        return type(of: error) is NSError.Type
    }

    /// `localizedDescription` works for both Swift and NSError, but
    /// for a bridged Swift error it often returns the generic
    /// "The operation couldn't be completed." string. Fall back to
    /// `String(describing:)` so the backend gets the case payload
    /// (`keyNotFound("foo")` etc.) when available.
    private static func messageString(for error: Error) -> String {
        let localized = error.localizedDescription
        if !localized.isEmpty
            && !localized.contains("The operation couldn’t be completed")
            && !localized.contains("The operation couldn't be completed") {
            return localized
        }
        return String(describing: error)
    }

    /// Flatten `userInfo` into `error.userInfo.<key>` entries, keeping
    /// only primitives (String / Int / Double / Bool / NSNumber). Any
    /// nested object, array, or class instance is dropped silently
    /// from the wire — the firewall in §F13/T13.2 mandates a flat
    /// primitives-only payload. When `debug == true` the drop is
    /// logged once per key via `os_log`.
    static func mergeUserInfo(
        _ userInfo: [String: Any],
        into attrs: inout [String: AttributeValue],
        debug: Bool
    ) {
        for (key, raw) in userInfo {
            guard let primitive = attributeValue(from: raw) else {
                if debug {
                    os_log(
                        "AppErrorBuilder dropped non-primitive userInfo key %{public}@",
                        log: log,
                        type: .info,
                        key
                    )
                }
                continue
            }
            attrs["error.userInfo.\(key)"] = primitive
        }
    }

    /// Map an arbitrary `Any` to an `AttributeValue` if it is — or
    /// trivially bridges to — a JSON primitive.
    static func attributeValue(from raw: Any) -> AttributeValue? {
        switch raw {
        case let s as String:
            return .string(s)
        case let b as Bool:
            return .bool(b)
        case let i as Int:
            return .int(i)
        case let i as Int64:
            return .int(Int(clamping: i))
        case let d as Double:
            return .double(d)
        case let f as Float:
            return .double(Double(f))
        case let n as NSNumber:
            return attributeValue(fromNSNumber: n)
        default:
            return nil
        }
    }

    private static func attributeValue(fromNSNumber n: NSNumber) -> AttributeValue? {
        // CFBoolean is the only reliable way to distinguish a real
        // `Bool` from an `Int` once it has crossed the NSNumber
        // boundary; ObjCType "c" is also used by Int8 on some
        // toolchains, so the CFTypeID check is the safe path.
        if CFGetTypeID(n) == CFBooleanGetTypeID() {
            return .bool(n.boolValue)
        }
        let type = String(cString: n.objCType)
        switch type {
        case "c", "C", "s", "S", "i", "I", "l", "L", "q", "Q":
            return .int(n.intValue)
        case "f", "d":
            return .double(n.doubleValue)
        default:
            return nil
        }
    }

    private static let log = OSLog(subsystem: "com.edge.rum", category: "AppErrorBuilder")
}
