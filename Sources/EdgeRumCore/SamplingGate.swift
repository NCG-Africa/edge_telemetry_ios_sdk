// Sources/EdgeRumCore/SamplingGate.swift
//
// F30 / #217 — the one sampling gate (roadmap tranche 5, W12).
//
// Open ⇔ app active ∧ ¬low power ∧ thermal < `serious`. Consulted by
// the three periodic costs only: the frame motion window, the memory
// timer tick and the `cpu_usage` sample riding it. Memory-pressure
// events, hangs, crashes and `long_task` never consult it.
//

import Foundation

public enum SamplingGate {

    /// Pure decision. `appState` is the `app.state` rider value; an
    /// unknown (`nil`) state counts as not active.
    public static func isOpen(appState: String?, power: PowerContext) -> Bool {
        appState == "active"
            && power.lowPowerMode != true
            && power.thermalState != "serious"
            && power.thermalState != "critical"
    }

    /// Live read: the `app.state` rider + `ProcessInfo`. Any thread.
    public static func isOpen() -> Bool {
        isOpen(appState: Riders.shared.currentAppState, power: PowerContext.snapshot())
    }
}
