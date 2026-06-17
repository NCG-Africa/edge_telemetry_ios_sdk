// Sources/EdgeRumCore/Context/ContextProvider.swift
//
// Holds the six identity-attribute snapshots (app, device, network,
// session, user, sdk) and combines them into a single `AttributeBag`
// at every `Recorder.recordEvent`.
//
// Refresh hooks let the surrounding code update individual contexts
// without recomputing the whole snapshot:
//   - `refreshNetwork(_:)`     — NWPath transition
//   - `setUser(_:)`            — EdgeRum.identify()
//   - `refreshSession(_:)`     — SessionManager rotation
//   - `refreshDevice(_:)`      — battery / system change
//
// Refs: PLAN-iOS.md §7.5, §F3/T3.3, CLAUDE.md "Recorder + transport
//       implementation notes" step 1 ("snapshots app/device/network/
//       session/user attributes into an in-memory AttributeBag").
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

    public init(
        app: AppContext,
        device: DeviceContext,
        deviceIdentity: DeviceIdentitySnapshot,
        network: NetworkContext,
        session: SessionContextSnapshot,
        user: UserContextSnapshot,
        sdk: SdkContext
    ) {
        self.app = app
        self.device = device
        self.deviceIdentity = deviceIdentity
        self.network = network
        self.session = session
        self.user = user
        self.sdk = sdk
    }

    // MARK: Snapshot

    /// Build the merged attribute bag in the order app → device →
    /// network → session → user → sdk. Within the same call no key
    /// collides (each context writes a disjoint key namespace).
    public func snapshot() -> AttributeBag {
        lock.lock(); defer { lock.unlock() }
        var bag = AttributeBag()
        app.write(into: &bag)
        device.write(into: &bag)
        deviceIdentity.write(into: &bag)
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
}
