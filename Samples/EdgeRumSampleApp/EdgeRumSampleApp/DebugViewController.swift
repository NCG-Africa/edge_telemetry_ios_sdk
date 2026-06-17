// Samples/EdgeRumSampleApp/EdgeRumSampleApp/DebugViewController.swift
//
// Buttons that exercise the manual public API entry points: `track`,
// `identify`, `time`, `captureError`, and `disable`/`enable`. Each
// button taps through the F9 interaction capture and runs the labelled
// API method; expected events show up in the SDK's debug log when
// `EdgeRumConfig.debug == true`.
//
// Refs: PLAN-iOS.md §F2 (public API surface).

import UIKit
import EdgeRum

final class DebugViewController: UIViewController {

    private struct ManualError: LocalizedError {
        let errorDescription: String? = "Sample handled error"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "Debug"
        title = "Debug"

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.distribution = .equalSpacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24)
        ])

        stack.addArrangedSubview(button("Track custom event", #selector(tapTrack)))
        stack.addArrangedSubview(button("Identify user",      #selector(tapIdentify)))
        stack.addArrangedSubview(button("Time an operation",  #selector(tapTime)))
        stack.addArrangedSubview(button("Capture an error",   #selector(tapCaptureError)))
        stack.addArrangedSubview(button("Disable capture",    #selector(tapDisable)))
        stack.addArrangedSubview(button("Enable capture",     #selector(tapEnable)))
    }

    private func button(_ title: String, _ action: Selector) -> UIButton {
        let b: UIButton
        if #available(iOS 15.0, *) {
            var conf = UIButton.Configuration.bordered()
            conf.title = title
            conf.buttonSize = .medium
            b = UIButton(configuration: conf)
        } else {
            b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
        }
        b.addTarget(self, action: action, for: .touchUpInside)
        b.accessibilityIdentifier = title
        return b
    }

    // MARK: - Actions

    @objc private func tapTrack() {
        EdgeRum.track("debug_button_pressed", attributes: [
            "screen": "Debug",
            "button": "track"
        ])
    }

    @objc private func tapIdentify() {
        EdgeRum.identify(UserContext(
            id: "u_42",
            name: "Ada Lovelace",
            email: "ada@example.com"
        ))
    }

    @objc private func tapTime() {
        let timer = EdgeRum.time("debug.simulated_work")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
            timer.end(attributes: ["debug.outcome": "ok"])
        }
    }

    @objc private func tapCaptureError() {
        EdgeRum.captureError(ManualError(), context: ["debug.source": "button"])
    }

    @objc private func tapDisable() {
        EdgeRum.disable()
    }

    @objc private func tapEnable() {
        EdgeRum.enable()
    }
}
