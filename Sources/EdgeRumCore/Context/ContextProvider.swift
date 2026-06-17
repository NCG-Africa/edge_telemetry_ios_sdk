// Sources/EdgeRumCore/Context/ContextProvider.swift
//
// Holds the identity-attribute snapshots and combines them into a
// single `AttributeBag` at every `Recorder.recordEvent`. The original
// six groups — app, device, network, session, user, sdk — are joined
// by three F16 enrichment groups: power, accessibility, storage.
//
// Refresh hooks let the surrounding code update individual contexts
// without recomputing the whole snapshot:
//   - `refreshNetwork(_:)`        — NWPath transition
//   - `setUser(_:)`               — EdgeRum.identify()
//   - `refreshSession(_:)`        — SessionManager rotation
//   - `refreshDevice(_:)`         — battery / system change / locale change
//   - `refreshPower(_:)`          — thermal / low power mode change (F16/T16.1)
//   - `refreshAccessibility(_:)`  — VoiceOver / dynamic type / etc. (F16/T16.2)
//   - `refreshStorage(_:)`        — periodic refresh + lifecycle    (F16/T16.4)
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3, §16.4 / F16; CLAUDE.md "Recorder
//       + transport implementation notes" step 1 ("snapshots app/
//       device/network/session/user attributes into an in-memory
//       AttributeBag").
//

import Foundation

public final class ContextProvider: @unchecked Sendable {

    private let lock = NSLock()
    private var app: AppContext
    private var device: DeviceContext
    private var deviceIdentity: DeviceIdentitySnapshot
    private var network: NetworkContext
    private var session: SessionContextSnapshot
    private var user: UserContextSnapshot
    private var sdk: SdkContext
    private var power: PowerContext
    private var accessibility: AccessibilityContext
    private var storage: StorageContext

    public init(
        app: AppContext,
        device: DeviceContext,
        deviceIdentity: DeviceIdentitySnapshot,
        network: NetworkContext,
        session: SessionContextSnapshot,
        user: UserContextSnapshot,
        sdk: SdkContext,
        power: PowerContext = PowerContext(),
        accessibility: AccessibilityContext = AccessibilityContext(),
        storage: StorageContext = StorageContext()
    ) {
        self.app = app
        self.device = device
        self.deviceIdentity = deviceIdentity
        self.network = network
        self.session = session
        self.user = user
        self.sdk = sdk
        self.power = power
        self.accessibility = accessibility
        self.storage = storage
    }

    // MARK: Snapshot

    /// Build the merged attribute bag in the order app → device →
    /// power → accessibility → storage → network → session → user →
    /// sdk. Within the same call no key collides (each context writes
    /// a disjoint key namespace).
    public func snapshot() -> AttributeBag {
        lock.lock(); defer { lock.unlock() }
        var bag = AttributeBag()
        app.write(into: &bag)
        device.write(into: &bag)
        deviceIdentity.write(into: &bag)
        power.write(into: &bag)
        accessibility.write(into: &bag)
        storage.write(into: &bag)
        network.write(into: &bag)
        session.write(into: &bag)
        user.write(into: &bag)
        sdk.write(into: &bag)
        return bag
    }

    // MARK: Refresh

    public func refreshApp(_ app: AppContext) {
        lock.lock(); self.app = app; lock.unlock()
    }

    public func refreshDevice(_ device: DeviceContext) {
        lock.lock(); self.device = device; lock.unlock()
    }

    public func refreshDeviceIdentity(_ identity: DeviceIdentitySnapshot) {
        lock.lock(); self.deviceIdentity = identity; lock.unlock()
    }

    public func refreshNetwork(_ network: NetworkContext) {
        lock.lock(); self.network = network; lock.unlock()
    }

    public func refreshSession(_ session: SessionContextSnapshot) {
        lock.lock(); self.session = session; lock.unlock()
    }

    public func setUser(_ user: RecorderUser) {
        lock.lock()
        self.user = self.user.merging(user)
        lock.unlock()
    }

    public func refreshUser(_ user: UserContextSnapshot) {
        lock.lock(); self.user = user; lock.unlock()
    }

    public func refreshPower(_ power: PowerContext) {
        lock.lock(); self.power = power; lock.unlock()
    }

    public func refreshAccessibility(_ accessibility: AccessibilityContext) {
        lock.lock(); self.accessibility = accessibility; lock.unlock()
    }

    public func refreshStorage(_ storage: StorageContext) {
        lock.lock(); self.storage = storage; lock.unlock()
    }

    // MARK: Read

    public func currentSession() -> SessionContextSnapshot {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    public func currentUser() -> UserContextSnapshot {
        lock.lock(); defer { lock.unlock() }
        return user
    }

    public func currentDeviceIdentity() -> DeviceIdentitySnapshot {
        lock.lock(); defer { lock.unlock() }
        return deviceIdentity
    }

    public func currentNetwork() -> NetworkContext {
        lock.lock(); defer { lock.unlock() }
        return network
    }

    public func currentPower() -> PowerContext {
        lock.lock(); defer { lock.unlock() }
        return power
    }

    public func currentAccessibility() -> AccessibilityContext {
        lock.lock(); defer { lock.unlock() }
        return accessibility
    }

    public func currentStorage() -> StorageContext {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
