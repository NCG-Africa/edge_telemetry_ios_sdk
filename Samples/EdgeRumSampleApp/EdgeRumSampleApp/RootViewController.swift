// Samples/EdgeRumSampleApp/EdgeRumSampleApp/RootViewController.swift
//
// Three navigation rows — Home (this), Catalog, Debug. Pushing each
// row exercises the F6 UIKit screen swizzle so `navigation` and
// `screen.duration` events appear in the captured stream without any
// per-controller code.
//
// The accessibilityIdentifier on each row's destination is the value
// the swizzle prefers for `navigation.screen`; the row labels here
// are display-only.

import UIKit

final class RootViewController: UITableViewController {

    private enum Row: Int, CaseIterable {
        case catalog
        case debug

        var title: String {
            switch self {
            case .catalog: return "Catalog (HTTP requests)"
            case .debug:   return "Debug (manual API calls)"
            }
        }
    }

    init() {
        super.init(style: .insetGrouped)
        self.title = "EdgeRum Sample"
        self.tableView.accessibilityIdentifier = "Home"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used by this sample")
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        cell.textLabel?.text = Row(rawValue: indexPath.row)?.title
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = Row(rawValue: indexPath.row) else { return }
        switch row {
        case .catalog:
            navigationController?.pushViewController(CatalogViewController(), animated: true)
        case .debug:
            navigationController?.pushViewController(DebugViewController(), animated: true)
        }
    }
}
