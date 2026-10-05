// Sources/EdgeRumCore/StackFrames.swift
//
// F29 / W20 frame format — the one formatter behind `error.stack`,
// `long_task.stack` and `hang.stack`.
//
// Each return address becomes `image +0x<offset> <hint>`:
//
//   - image  = last path component of the Mach-O image (`dladdr` dli_fname)
//   - offset = address − image load base (`dli_fbase`), lowercase hex —
//              image-relative, so it survives ASLR and is symbolicatable
//              against the image's dSYM
//   - hint   = `dladdr` nearest symbol (`dli_sname`), raw (may be
//              mangled); omitted when `dladdr` has none
//
// An address `dladdr` cannot place in any image renders as `0x<absolute>`
// and references no image.
//
// The sibling `<prefix>.binary_images` is a JSON string
// `[{"name":…,"uuid":…}]` of the images the KEPT frames reference,
// deduplicated, first-seen order. `uuid` is the image's LC_UUID in
// PLCrashReporter's `imageUUID` format (32 lowercase hex chars, no
// hyphens) so one symbolication key format serves `crash.report_json`
// and these three stacks alike.
//
// Refs: docs/catalogue/ios-data-catalogue.md §5.10, §5.11, §0 clause 8.
//

import Foundation
#if canImport(Darwin)
import Darwin
import MachO
#endif

/// A Mach-O image referenced by a stack frame — the symbolication key.
public struct StackImage: Hashable, Sendable {
    public let name: String
    public let uuid: String

    public init(name: String, uuid: String) {
        self.name = name
        self.uuid = uuid
    }
}

/// One formatted frame plus the image it points into (nil when unresolved).
public struct StackFrame: Equatable, Sendable {
    public let text: String
    public let image: StackImage?

    public init(text: String, image: StackImage? = nil) {
        self.text = text
        self.image = image
    }
}

public enum StackFrames {

    /// Format raw return addresses as `image +0x<offset> <hint>` frames.
    public static func symbolicate(_ addresses: [UInt]) -> [StackFrame] {
        var uuidByBase: [UInt: String] = [:]
        return addresses.map { address in
            var info = Dl_info()
            guard let ptr = UnsafeRawPointer(bitPattern: address),
                  dladdr(ptr, &info) != 0,
                  let base = info.dli_fbase,
                  let fname = info.dli_fname else {
                return StackFrame(text: String(format: "0x%lx", address))
            }
            let baseAddr = UInt(bitPattern: base)
            let name = (String(cString: fname) as NSString).lastPathComponent
            var text = name + " +0x" + String(address &- baseAddr, radix: 16)
            if let sname = info.dli_sname {
                text += " " + String(cString: sname)
            }
            let uuid: String
            if let cached = uuidByBase[baseAddr] {
                uuid = cached
            } else {
                uuid = imageUUID(header: UnsafeRawPointer(base)) ?? ""
                uuidByBase[baseAddr] = uuid
            }
            return StackFrame(text: text, image: StackImage(name: name, uuid: uuid))
        }
    }

    /// Keep frames whole up to `maxBytes` of `\n`-joined UTF-8.
    /// - Returns: the joined kept stack, bytes removed versus the
    ///   uncapped join (0 when nothing was cut), and the kept frames'
    ///   `binary_images` JSON (nil when none).
    public static func capped(
        _ frames: [StackFrame],
        maxBytes: Int
    ) -> (stack: String, bytesRemoved: Int, binaryImages: String?) {
        var kept: [StackFrame] = []
        var size = 0
        for frame in frames {
            let frameSize = frame.text.utf8.count + 1 // include the join '\n'
            if size + frameSize > maxBytes { break }
            kept.append(frame)
            size += frameSize
        }
        let stack = join(kept)
        let removed = join(frames).utf8.count - stack.utf8.count
        return (stack, removed, binaryImagesJSON(kept))
    }

    /// `\n`-joined frame texts.
    public static func join(_ frames: [StackFrame]) -> String {
        frames.map(\.text).joined(separator: "\n")
    }

    /// JSON string `[{"name":…,"uuid":…}]` of the images `frames`
    /// reference, deduplicated in first-seen order. `nil` when none.
    public static func binaryImagesJSON(_ frames: [StackFrame]) -> String? {
        var seen = Set<StackImage>()
        var list: [[String: String]] = []
        for case let image? in frames.map(\.image) where seen.insert(image).inserted {
            // Omit, never substitute: no LC_UUID → no `uuid` key.
            list.append(image.uuid.isEmpty ? ["name": image.name] : ["name": image.name, "uuid": image.uuid])
        }
        guard !list.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: list, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// LC_UUID of the Mach-O image whose header is at `header`, as
    /// 32 lowercase hex chars (PLCrashReporter's `imageUUID` format).
    static func imageUUID(header: UnsafeRawPointer) -> String? {
        let mh = header.load(as: mach_header.self)
        var cmd: UnsafeRawPointer
        switch mh.magic {
        case MH_MAGIC_64: cmd = header + MemoryLayout<mach_header_64>.size
        case MH_MAGIC: cmd = header + MemoryLayout<mach_header>.size
        default: return nil
        }
        for _ in 0..<mh.ncmds {
            let lc = cmd.load(as: load_command.self)
            if lc.cmd == UInt32(LC_UUID) {
                let u = cmd.load(as: uuid_command.self).uuid
                return withUnsafeBytes(of: u) { bytes in
                    bytes.map { String(format: "%02x", $0) }.joined()
                }
            }
            guard lc.cmdsize > 0 else { return nil } // malformed header: stop, never loop
            cmd += Int(lc.cmdsize)
        }
        return nil
    }
}
