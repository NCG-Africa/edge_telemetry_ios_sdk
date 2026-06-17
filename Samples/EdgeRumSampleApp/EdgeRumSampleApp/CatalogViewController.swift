// Samples/EdgeRumSampleApp/EdgeRumSampleApp/CatalogViewController.swift
//
// Fires two URLSession.shared.dataTask requests on viewDidLoad to
// exercise the F8 HTTP capture path. Each request produces an
// `http.request` event plus a companion `resource_timing` metric — both
// are visible in the SDK's debug log when `EdgeRumConfig.debug == true`.
//
// The endpoint hosts here are placeholders. The sample app talks to
// `httpbin.org` because it's a stable HTTP echo service; replace with
// your own backend if you want to see real traffic.
//
// Refs: PLAN-iOS.md §F8 (HTTP capture).

import UIKit

final class CatalogViewController: UIViewController {

    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "Catalog"
        title = "Catalog"

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Issuing two GET requests via URLSession.shared.\nWatch Console.app for http.request events."
        view.addSubview(label)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
        ])

        issueRequest(path: "/json")
        issueRequest(path: "/headers")
    }

    private func issueRequest(path: String) {
        guard let url = URL(string: "https://httpbin.org\(path)") else { return }
        URLSession.shared.dataTask(with: url) { _, _, _ in
            // No-op completion. The SDK records the request from its
            // URLProtocol; the host doesn't need to do anything.
        }.resume()
    }
}
