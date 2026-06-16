// Sources/EdgeRum/Environment.swift
//
// Refs: PLAN-iOS.md §3.2, §F2/T2.4.
//

import Foundation

/// The deployment environment a host app is running in.
///
/// Set on `EdgeRumConfig.environment`; emitted on every event as the
/// `app.environment` attribute. Three cases match the values the
/// backend already accepts from the web and Android SDKs.
public enum Environment: String, Sendable, Hashable, CaseIterable {
    case production
    case staging
    case development
}
