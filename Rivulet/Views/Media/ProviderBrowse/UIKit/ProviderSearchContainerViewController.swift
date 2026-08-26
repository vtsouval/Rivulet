// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// UISearchController host for provider-neutral results. Keeping the results
/// controller inside the search controller preserves tvOS keyboard-to-grid
/// focus handoff; a separate sibling results view breaks that boundary.
@MainActor
final class ProviderSearchContainerViewController: UIViewController {
    private let results: ProviderBrowseViewController
    private let searchController: UISearchController
    private let searchContainer: UISearchContainerViewController

    var onNestedChange: ((Bool) -> Void)? {
        didSet { results.onNestedChange = onNestedChange }
    }

    init(providerID: String) {
        results = ProviderBrowseViewController(providerID: providerID, mode: .search)
        searchController = UISearchController(searchResultsController: results)
        searchContainer = UISearchContainerViewController(searchController: searchController)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        searchController.searchResultsUpdater = self
        searchController.searchBar.placeholder = "Search Jellyfin"
        searchController.obscuresBackgroundDuringPresentation = false

        addChild(searchContainer)
        searchContainer.view.frame = view.bounds
        searchContainer.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(searchContainer.view)
        searchContainer.didMove(toParent: self)
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [searchController.searchBar, searchContainer]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if presentedViewController == nil { onNestedChange?(false) }
    }
}

extension ProviderSearchContainerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        results.updateSearchQuery(searchController.searchBar.text ?? "")
    }
}
