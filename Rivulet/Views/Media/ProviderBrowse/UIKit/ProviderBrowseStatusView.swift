// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Calm full-page state used while a provider browse surface has no focusable
/// content. Kept separate from `HomeStateView` because that view's copy and
/// actions are Plex-specific.
@MainActor
final class ProviderBrowseStatusView: UIView {
    enum State {
        case hidden
        case loading
        case prompt(title: String, message: String?)
        case empty(title: String, message: String?)
        case error(message: String)
    }

    var onRetry: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .large)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .black

        spinner.color = .white
        spinner.hidesWhenStopped = true

        iconView.tintColor = UIColor.white.withAlphaComponent(0.55)
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 46, weight: .light)

        titleLabel.font = .systemFont(ofSize: 38, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 25, weight: .regular)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.58)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 2

        retryButton.setTitle("Try Again", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 25, weight: .semibold)
        retryButton.addTarget(self, action: #selector(retry), for: .primaryActionTriggered)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        [spinner, iconView, titleLabel, messageLabel, retryButton].forEach(stack.addArrangedSubview)
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 80),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -80),
            iconView.widthAnchor.constraint(equalToConstant: 54),
            iconView.heightAnchor.constraint(equalToConstant: 54),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 700)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: State) {
        isHidden = false
        spinner.stopAnimating()
        spinner.isHidden = true
        iconView.isHidden = false
        titleLabel.isHidden = false
        messageLabel.isHidden = false
        retryButton.isHidden = true

        switch state {
        case .hidden:
            isHidden = true
        case .loading:
            spinner.isHidden = false
            spinner.startAnimating()
            iconView.isHidden = true
            titleLabel.isHidden = true
            messageLabel.isHidden = true
        case .prompt(let title, let message):
            iconView.image = UIImage(systemName: "magnifyingglass")
            titleLabel.text = title
            setMessage(message)
        case .empty(let title, let message):
            iconView.image = UIImage(systemName: "film.stack")
            titleLabel.text = title
            setMessage(message)
        case .error(let message):
            iconView.image = UIImage(systemName: "exclamationmark.triangle")
            titleLabel.text = "Unable to Load"
            setMessage(message)
            retryButton.isHidden = false
        }
    }

    private func setMessage(_ message: String?) {
        messageLabel.text = message
        messageLabel.isHidden = message?.isEmpty != false
    }

    @objc private func retry() { onRetry?() }
}
