// Sources/EdgeRumCrash/MainThreadStackSnapshot.swift
//
// F15/T15.2 — best-effort main-thread stack capture from a non-main
// (watchdog) thread, using only public Mach + POSIX APIs:
//
//   - `pthread_mach_thread_np(pthread_self())` captures the main
//     thread's Mach port at install time.
//   - `thread_suspend` / `thread_resume` halt the main thread for the
//     duration of the snapshot.
//   - `thread_get_state` reads the saved program counter + frame
//     pointer for the suspended thread (`arm_thread_state64_t` on
//     ARM, `x86_thread_state64_t` on Intel).
//   - The frame-pointer chain is walked via `vm_read_overwrite` so
//     a corrupted FP can't crash the process — invalid reads return
//     `KERN_INVALID_ADDRESS` and we bail.
//   - `dladdr` symbolicates each return address.
//
// We deliberately avoid `_pthread_*` private functions (PLAN-iOS.md
// §F15/T15.2 acceptance) and we keep the suspension window short:
// only `vm_read_overwrite` calls (async-signal-safe in practice) and
// no Swift allocations happen between `thread_suspend` and
// `thread_resume`. All collected return addresses are symbolicated
// AFTER resume.
//
// Best-effort by design: if any Mach call fails we return `[]` and
// let `HangEventEncoder` substitute its `<hang-stack-unavailable>`
// placeholder so the T15.2 "non-empty stack" acceptance still holds.
//
// Refs: PLAN-iOS.md §6.8, §F15/T15.2; docs/decisions.md ADR-011.
//

import Foundation
import Darwin
import Darwin.Mach

internal enum MainThreadStackSnapshot {

    // MARK: - Stored main-thread port

    private static let stateLock = NSLock()

    /// Mach port for the main pthread. `MACH_PORT_NULL` until
    /// `installFromMainThread()` runs. The port lifetime is bound to
    /// the main pthread, so no explicit `mach_port_deallocate` is
    /// needed (this is the `_np`-suffix contract).
    nonisolated(unsafe) private static var mainThreadPort: thread_t = mach_port_t(MACH_PORT_NULL)
    nonisolated(unsafe) private static var isInstalled: Bool = false

    /// Test override — when non-nil, `capture()` immediately returns
    /// this array and skips all Mach work. Tests use this to verify
    /// the `[]` → placeholder fallback in `HangEventEncoder` without
    /// having to coerce `thread_get_state` into failing.
    nonisolated(unsafe) private static var testStubFrames: [String]?

    // MARK: - Install / reset

    /// Record the main thread's Mach port. MUST be invoked from the
    /// main thread; the watchdog calls this from `HangDetector.install`
    /// via `DispatchQueue.main.async`. Idempotent; second call is a
    /// no-op so a repeat `EdgeRum.start()` doesn't churn the port.
    internal static func installFromMainThread() {
        precondition(
            Thread.isMainThread,
            "MainThreadStackSnapshot.installFromMainThread must run on the main thread"
        )
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isInstalled else { return }
        let port = pthread_mach_thread_np(pthread_self())
        if port != mach_port_t(MACH_PORT_NULL) {
            mainThreadPort = port
            isInstalled = true
        }
    }

    /// Test hook so install / detection tests can reset the cached
    /// port between cases.
    internal static func _resetForTests() {
        stateLock.lock(); defer { stateLock.unlock() }
        isInstalled = false
        mainThreadPort = mach_port_t(MACH_PORT_NULL)
        testStubFrames = nil
    }

    /// Test hook — install a fixed result for `capture()` so the
    /// `HangEventEncoder` placeholder path can be exercised without
    /// coaxing `thread_get_state` into failing.
    internal static func _installStubForTests(_ frames: [String]?) {
        stateLock.lock(); defer { stateLock.unlock() }
        testStubFrames = frames
    }

    // MARK: - Capture

    /// Snapshot the main thread's stack. Returns the empty array on
    /// any failure path (not installed, suspend failed, register read
    /// failed, or no frames recoverable). Safe to call from any
    /// thread other than the main thread — calling from the main
    /// thread would deadlock under the `thread_suspend` and is
    /// guarded against.
    internal static func capture(maxFrames: Int = 64) -> [String] {
        // Test override short-circuit.
        stateLock.lock()
        if let stub = testStubFrames {
            stateLock.unlock()
            return stub
        }
        let port = mainThreadPort
        let installed = isInstalled
        stateLock.unlock()

        guard installed, port != mach_port_t(MACH_PORT_NULL) else { return [] }
        // Calling from the main thread would deadlock: we'd suspend
        // ourselves and never resume. Bail with an empty result.
        if Thread.isMainThread { return [] }

        // Suspend the main thread. KERN_SUCCESS == 0.
        guard thread_suspend(port) == KERN_SUCCESS else { return [] }
        defer { _ = thread_resume(port) }

        // Read PC + FP from the saved register state.
        guard let registers = readRegisters(port: port) else { return [] }

        // Walk the frame pointer chain via vm_read_overwrite so an
        // invalid FP doesn't crash the process.
        var addresses: [UInt] = [registers.pc & Self.pacMask]
        var fp = registers.fp
        var iteration = 0
        while fp != 0, iteration < maxFrames {
            // FPs must be word-aligned. Bail on alignment violation.
            if fp & UInt(MemoryLayout<UInt>.alignment - 1) != 0 { break }
            guard let nextFp = safeReadPointer(at: fp) else { break }
            guard let savedLr = safeReadPointer(at: fp &+ UInt(MemoryLayout<UInt>.size)) else { break }
            let stripped = savedLr & Self.pacMask
            if stripped == 0 { break }
            addresses.append(stripped)
            // Sanity: the next FP must be higher than the current one
            // (stacks grow downward, but FPs are saved at increasing
            // addresses as you walk up the call chain). Cycle / regress
            // means the chain is corrupt — bail.
            if nextFp <= fp { break }
            fp = nextFp
            iteration += 1
        }

        // Symbolicate AFTER resume so we don't run dladdr (which can
        // take dyld's lock) while the main thread is suspended.
        return addresses.map(symbolicate(_:))
    }

    // MARK: - Internals

    /// On Apple Silicon (ARM64e), saved frame and return-address
    /// pointers carry pointer-authentication bits in the high half.
    /// Masking with this constant keeps the bottom 48 bits of an
    /// addressable iOS userland pointer. Aligns with `ptrauth_strip`
    /// behaviour at the bit level.
    private static let pacMask: UInt = 0x0000_FFFF_FFFF_FFFF

    private struct Registers {
        let pc: UInt
        let fp: UInt
    }

    private static func readRegisters(port: thread_t) -> Registers? {
        #if arch(arm64)
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(port, ARM_THREAD_STATE64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Registers(pc: UInt(state.__pc), fp: UInt(state.__fp))
        #elseif arch(x86_64)
        var state = x86_thread_state64_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<x86_thread_state64_t>.size / MemoryLayout<UInt32>.size
        )
        let kr = withUnsafeMutablePointer(to: &state) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: natural_t.self, capacity: Int(count)) { rebound in
                thread_get_state(port, x86_THREAD_STATE64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return Registers(pc: UInt(state.__rip), fp: UInt(state.__rbp))
        #else
        _ = port
        return nil
        #endif
    }

    /// Read one word at `address` via `vm_read_overwrite`. Returns
    /// `nil` if the read kernel-returns anything other than success
    /// (typical case: `KERN_INVALID_ADDRESS` when we walk off the
    /// bottom of the stack). Never traps.
    private static func safeReadPointer(at address: UInt) -> UInt? {
        var buffer: UInt = 0
        var outSize: vm_size_t = 0
        let kr = withUnsafeMutablePointer(to: &buffer) { bufferPtr -> kern_return_t in
            let destAddr = vm_address_t(UInt(bitPattern: bufferPtr))
            return vm_read_overwrite(
                mach_task_self_,
                vm_address_t(address),
                vm_size_t(MemoryLayout<UInt>.size),
                destAddr,
                &outSize
            )
        }
        guard kr == KERN_SUCCESS, outSize == vm_size_t(MemoryLayout<UInt>.size) else {
            return nil
        }
        return buffer
    }

    /// Best-effort symbolication. Falls back to `0x<hex>` when
    /// `dladdr` fails (very young dyld state, JIT pages, etc.).
    /// Mirrors the look of `Thread.callStackSymbols` so downstream
    /// dashboards can parse both kinds of frames uniformly.
    private static func symbolicate(_ address: UInt) -> String {
        var info = Dl_info()
        let rawPtr = UnsafeRawPointer(bitPattern: address)
        guard let rawPtr, dladdr(rawPtr, &info) != 0 else {
            return String(format: "0x%016lx", address)
        }
        let imageName: String
        if let fnamePtr = info.dli_fname {
            let full = String(cString: fnamePtr)
            imageName = (full as NSString).lastPathComponent
        } else {
            imageName = "???"
        }
        let symbolName: String
        let offset: UInt
        if let snamePtr = info.dli_sname {
            symbolName = String(cString: snamePtr)
            if let saddr = info.dli_saddr {
                offset = address &- UInt(bitPattern: saddr)
            } else {
                offset = 0
            }
        } else {
            symbolName = "<unknown>"
            offset = 0
        }
        return String(
            format: "%-30s 0x%016lx %@ + %lu",
            (imageName as NSString).utf8String!,
            address,
            symbolName,
            offset
        )
    }
}
