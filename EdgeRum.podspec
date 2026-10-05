# EdgeRum.podspec
#
# CocoaPods distribution channel for the edge-rum-ios SDK. Mirrors the
# SwiftPM Package.swift target layout 1:1 — see PLAN-iOS.md §2.4 and
# F1/T1.4 (issue #5).
#
# NOTE on opentelemetry-swift-core: upstream does NOT publish
# OpenTelemetry-Swift-Api / OpenTelemetry-Swift-Sdk to the CocoaPods
# trunk. The only same-named pods on trunk are from an unrelated Aliyun
# fork at 0.1.alpha. The EdgeRumOTelBridge target is therefore omitted
# from the CocoaPods distribution; CocoaPods consumers get the same
# user-visible surface (the public `EdgeRum` umbrella module) but lose
# the architectural-insurance bridge. SwiftPM consumers get the full
# stack. Tracked in PLAN-iOS.md §14 "Backend asks".

Pod::Spec.new do |s|
  s.name             = 'EdgeRum'
  s.version          = File.read(File.expand_path('VERSION', __dir__)).strip
  s.summary          = 'Native iOS Real User Monitoring SDK for the Edge Telemetry platform.'
  s.description      = <<-DESC
    EdgeRum captures performance data, errors, network requests, native
    crashes, hangs, and user interactions on iOS apps and ships them as
    JSON to the EdgeTelemetryProcessor backend. See the README and
    PLAN-iOS.md for the architecture and wire contract.
  DESC

  s.homepage         = 'https://github.com/NCG-Africa/edge_telemetry_ios_sdk'
  s.license          = { :type => 'Apache-2.0', :text => 'Apache License 2.0 — see LICENSE' }
  s.author           = { 'Edge Telemetry' => 'noreply@edge.local' }
  s.source           = { :git => 'https://github.com/NCG-Africa/edge_telemetry_ios_sdk.git',
                         :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  # `Package.swift` uses `swift-tools-version: 6.0` but pins
  # `swiftLanguageModes: [.v5]`, so SwiftPM consumers also compile in
  # Swift 5 mode. CocoaPods is pinned to Swift 5.10 because CLAUDE.md states
  # "nothing on our public surface requires Swift 6 strict
  # concurrency" — advertising 6.0 here makes Xcode promote every
  # MainActor-isolation warning to an error under iOS 26 SDK, blocking
  # `pod lib lint` on warnings the SDK is intentionally not fixing.
  # Bump back to 6.0 once we cross the strict-concurrency audit (an
  # F-future track).
  s.swift_versions        = ['5.10']
  s.requires_arc          = true
  # PLCrashReporter ships as a static xcframework; a dynamic pod can't
  # transitively embed a statically-linked binary, so the CocoaPods
  # distribution builds static. (SPM linkage is governed by Package.swift.)
  s.static_framework      = true

  # PrivacyInfo manifest. F1 ships an empty stub; real declarations
  # land with F20.
  s.resource_bundles = {
    'EdgeRumPrivacy' => ['Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy']
  }

  s.default_subspec = 'Default'

  # EdgeRumVersion.swift is produced by the SwiftPM build plugin at build
  # time; CocoaPods doesn't run SwiftPM plugins, so regenerate it from the
  # VERSION file at install time. Runs on the downloaded pod copy only —
  # never touches the git checkout, so it can't collide with the plugin's
  # SwiftPM output.
  s.prepare_command = 'bash Tools/gen-version.sh Sources/EdgeRum/Generated/EdgeRumVersion.swift'

  s.subspec 'Default' do |ss|
    ss.dependency 'EdgeRum/Internal-Core'
    ss.dependency 'EdgeRum/Internal-Capture'
    ss.dependency 'EdgeRum/Internal-Crash'
    ss.source_files = 'Sources/EdgeRum/**/*.swift'
  end

  # Internal subspecs — names prefixed with `Internal-` so they are
  # clearly not user-facing. They map 1:1 to the SwiftPM internal
  # targets in Package.swift (modulo the OTel bridge, see header note).
  s.subspec 'Internal-Core' do |ss|
    ss.source_files = 'Sources/EdgeRumCore/**/*.swift'
  end

  s.subspec 'Internal-Capture' do |ss|
    ss.dependency 'EdgeRum/Internal-Core'
    ss.source_files = 'Sources/EdgeRumCapture/**/*.swift'
  end

  s.subspec 'Internal-Crash' do |ss|
    ss.dependency 'EdgeRum/Internal-Core'
    ss.source_files = 'Sources/EdgeRumCrash/**/*.swift'
    # SwiftPM vendors CrashReporter.xcframework locally (gitignored, so it
    # isn't in the release tag). For CocoaPods we depend on the upstream
    # PLCrashReporter pod instead — same `CrashReporter` module name, so
    # the `@_implementationOnly import CrashReporter` in this target is
    # unchanged. No binary committed to the repo.
    ss.dependency 'PLCrashReporter', '~> 1.12'
  end
end
