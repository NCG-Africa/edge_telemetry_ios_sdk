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
  s.swift_versions        = ['5.10', '6.0']
  s.requires_arc          = true
  s.static_framework      = false

  # PrivacyInfo manifest. F1 ships an empty stub; real declarations
  # land with F20.
  s.resource_bundles = {
    'EdgeRumPrivacy' => ['Sources/EdgeRum/Resources/PrivacyInfo.xcprivacy']
  }

  s.default_subspec = 'Default'

  s.subspec 'Default' do |ss|
    ss.dependency 'EdgeRum/Internal-Core'
    ss.dependency 'EdgeRum/Internal-Capture'
    ss.dependency 'EdgeRum/Internal-Crash'
    ss.source_files = 'Sources/EdgeRum/**/*.swift'
    # The generated EdgeRumVersion.swift comes from the SwiftPM build
    # plugin. For CocoaPods distribution it must be checked in before
    # release tagging; see Tools/gen-version.sh.
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
    # PLCrashReporter ships as a vendored XCFramework. The fetch script
    # downloads it into Frameworks/ before `pod lib lint` runs in CI.
    ss.vendored_frameworks = 'Frameworks/CrashReporter.xcframework'
  end
end
