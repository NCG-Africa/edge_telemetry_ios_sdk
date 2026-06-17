// Sources/EdgeRumCore/Context/AccessibilityContext.swift
//
// F16/T16.2 — accessibility settings carried on every event so the
// backend can correlate UX issues with users running large dynamic
// type, VoiceOver, etc.
//
// Wire keys (docs/data-flow.md §3.2):
//   device.dynamic_type        — content size category
//                                ("XS" / "S" / "M" / "L" / "XL" / "XXL"
//                                 / "XXXL" / "AX1" / "AX2" / "AX3"
//                                 / "AX4" / "AX5")
//   device.reduce_motion       — Bool
//   device.bold_text           — Bool
//   device.voiceover           — Bool
//   device.increase_contrast   — Bool (sourced from
//                                `UIAccessibility.isDarkerSystemColorsEnabled`,
//                                which is the iOS "Increase Contrast"
//                                toggle in Settings → Accessibility)
//
// Observers in `ContextObservers` subscribe to:
//   - voiceOverStatusDidChangeNotification
//   - reduceMotionStatusDidChangeNotification
//   - boldTextStatusDidChangeNotification
//   - darkerSystemColorsStatusDidChangeNotification
//   - UIContentSizeCategory.didChangeNotification
//
// Refs: PLAN-iOS.md §16.4 / F16 / T16.2.
//

import Foundation
#if canImport(UIKit)
import UIKit
#endif

public struct AccessibilityContext: Sendable, Hashable {

    public var dynamicType: String?
    public var reduceMotion: Bool?
    public var boldText: Bool?
    public var voiceOver: Bool?
    public var increaseContrast: Bool?

    public init(
        dynamicType: String? = nil,
        reduceMotion: Bool? = nil,
        boldText: Bool? = nil,
        voiceOver: Bool? = nil,
        increaseContrast: Bool? = nil
    ) {
        self.dynamicType = dynamicType
        self.reduceMotion = reduceMotion
        self.boldText = boldText
        self.voiceOver = voiceOver
        self.increaseContrast = increaseContrast
    }

    /// Snapshot the live `UIAccessibility` flags. UIKit's accessibility
    /// properties are documented as safe to read from any thread, but
    /// `UIApplication.shared.preferredContentSizeCategory` must be
    /// touched from the main thread, so we hop if needed (pattern from
    /// `DeviceContext.readScreenMetrics`).
    public static func snapshot() -> AccessibilityContext {
        #if canImport(UIKit)
        let (dynamic, reduce, bold, voice, contrast) = readUIAccessibility()
        return AccessibilityContext(
            dynamicType: dynamic,
            reduceMotion: reduce,
            boldText: bold,
            voiceOver: voice,
            increaseContrast: contrast
        )
        #else
        return AccessibilityContext()
        #endif
    }

    public func write(into bag: inout AttributeBag) {
        bag.setIfPresent("device.dynamic_type", dynamicType.map { .string($0) })
        bag.setIfPresent("device.reduce_motion", reduceMotion.map { .bool($0) })
        bag.setIfPresent("device.bold_text", boldText.map { .bool($0) })
        bag.setIfPresent("device.voiceover", voiceOver.map { .bool($0) })
        bag.setIfPresent("device.increase_contrast", increaseContrast.map { .bool($0) })
    }

    #if canImport(UIKit)
    /// Map `UIContentSizeCategory` to the wire string per
    /// `docs/data-flow.md` §3.2 ("XS"…"AX5"). Exposed internal so
    /// `AccessibilityContextTests` can drive every category without
    /// changing the simulator's preferred text size.
    internal static func dynamicTypeString(_ category: UIContentSizeCategory) -> String {
        switch category {
        case .extraSmall:                        return "XS"
        case .small:                             return "S"
        case .medium:                            return "M"
        case .large:                             return "L"
        case .extraLarge:                        return "XL"
        case .extraExtraLarge:                   return "XXL"
        case .extraExtraExtraLarge:              return "XXXL"
        case .accessibilityMedium:               return "AX1"
        case .accessibilityLarge:                return "AX2"
        case .accessibilityExtraLarge:           return "AX3"
        case .accessibilityExtraExtraLarge:      return "AX4"
        case .accessibilityExtraExtraExtraLarge: return "AX5"
        default:                                 return "L"
        }
    }
    #endif
}

#if canImport(UIKit)

/// Read the five UIAccessibility flags. Forces a main-thread hop when
/// called off-main because `UIApplication.shared` access is main-actor
/// constrained on Swift 6.
private func readUIAccessibility()
    -> (String?, Bool?, Bool?, Bool?, Bool?) {
    if Thread.isMainThread {
        return readUIAccessibilityOnMain()
    }
    var result: (String?, Bool?, Bool?, Bool?, Bool?) = (nil, nil, nil, nil, nil)
    DispatchQueue.main.sync { result = readUIAccessibilityOnMain() }
    return result
}

private func readUIAccessibilityOnMain()
    -> (String?, Bool?, Bool?, Bool?, Bool?) {
    let category = UIApplication.shared.preferredContentSizeCategory
    let dynamic = AccessibilityContext.dynamicTypeString(category)
    let reduce = UIAccessibility.isReduceMotionEnabled
    let bold = UIAccessibility.isBoldTextEnabled
    let voice = UIAccessibility.isVoiceOverRunning
    let contrast = UIAccessibility.isDarkerSystemColorsEnabled
    return (dynamic, reduce, bold, voice, contrast)
}
#endif
