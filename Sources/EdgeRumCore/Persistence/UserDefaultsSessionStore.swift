// Sources/EdgeRumCore/Persistence/UserDefaultsSessionStore.swift
//
// Persists the `SessionState` triple — id, start_time, sequence,
// last_active_at — to the UserDefaults suite
// `com.edge.rum.session`. Replaces F3's `InMemorySessionStore` as the
// production default for `SessionManager`.
//
// JSON-encoded so the on-disk format is human-readable when
// debugging. The `SessionState` Codable conformance from
// `SessionContext.swift` is the source of truth — this store does no
// schema massaging of its own.
//
// On `load()`, if the persisted blob fails to decode (older format,
// truncated write) we silently return `nil` so `SessionManager` will
// generate a fresh session — preferring a clean start over crashing.
// We log the decode failure via `os_log` so the symptom is visible in
// debug mode.
//
// Refs: CLAUDE.md "Session and ID rules → Storage"; PLAN-iOS.md §F4/T4.3.
//

import Foundation
import os.log

public final class UserDefaultsSessionStore: SessionStore, @unchecked Sendable {

    private let defaults: UserDefaultsStoring
    private let key: String
    private let log: OSLog

    public init(
        defaults: UserDefaultsStoring = UserDefaultsStore(suiteName: EdgeRumStorage.sessionSuite),
        key: String = EdgeRumStorage.keySessionState,
        log: OSLog = OSLog(subsystem: "com.edge.rum", category: "SessionStore")
    ) {
        self.defaults = defaults
        self.key = key
        self.log = log
    }

    public func load() -> SessionState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try Self.decoder.decode(SessionState.self, from: data)
        } catch {
            os_log(
                "UserDefaultsSessionStore decode failed; starting fresh: %{public}@",
                log: log,
                type: .info,
                String(describing: error)
            )
            defaults.removeObject(forKey: key)
            return nil
        }
    }

    public func save(_ state: SessionState) {
        do {
            let data = try Self.encoder.encode(state)
            defaults.set(data, forKey: key)
        } catch {
            os_log(
                "UserDefaultsSessionStore encode failed: %{public}@",
                log: log,
                type: .info,
                String(describing: error)
            )
        }
    }

    // MARK: Encoder / decoder

    /// ISO 8601 with fractional seconds for the two `Date` fields so
    /// the on-disk blob round-trips identically across builds.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .millisecondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()
}
