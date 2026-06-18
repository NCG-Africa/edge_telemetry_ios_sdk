// Samples/EdgeRumSampleApp/EdgeRumSampleApp/SceneDelegate.swift
//
// Minimal SceneDelegate — installs a UINavigationController carrying
// the RootViewController. The F6 UIKit swizzle picks up viewDidAppear
// on every pushed controller without any extra wiring.
//
// Refs: PLAN-iOS.md §12.3.

import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let nav = UINavigationController(rootViewController: RootViewController())
        nav.navigationBar.prefersLargeTitles = true
        window.rootViewController = nav
        self.window = window
        window.makeKeyAndVisible()
    }
}
