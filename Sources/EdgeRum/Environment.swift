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
    /// Production builds. Routes events to the live dashboards.
    case production
    /// Pre-production environment. Routes events to staging dashboards
    /// that mirror production but are isolated from production data.
    case staging
    /// Local development / debug builds. Useful for in-team testing
    /// without polluting the staging dashboards.
    case development
}
