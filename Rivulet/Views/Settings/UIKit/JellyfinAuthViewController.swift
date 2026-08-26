// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Native tvOS connection flow for Jellyfin. Passwords live only in the text
/// field for the duration of the request; successful sessions persist the
/// revocable Jellyfin token in Keychain through `JellyfinSessionStore`.
@MainActor
final class JellyfinAuthViewController: UIViewController {
    private enum Keys {
        static let lastServerURL = "jellyfin.lastServerURL"
    }

    private let serverField = UITextField()
    private let usernameField = UITextField()
    private let passwordField = UITextField()
    private let connectButton = UIButton(type: .system)
    private let quickConnectButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private let quickCodeLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .large)

    private var operation: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        buildInterface()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
        updateFocusIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard presentingViewController == nil else { return }
        cancelOperation()
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if serverField.text?.isEmpty != false { return [serverField] }
        return [usernameField]
    }

    deinit {
        operation?.cancel()
    }

    private func buildInterface() {
        // The system material styles are unavailable on tvOS. `.dark` is the
        // native tvOS blur and still lets the translucent panel inherit the
        // moving imagery behind it.
        let backdrop = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.layer.cornerRadius = 38
        backdrop.layer.cornerCurve = .continuous
        backdrop.clipsToBounds = true
        backdrop.layer.borderWidth = 1
        backdrop.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        view.addSubview(backdrop)

        let title = UILabel()
        title.text = "Connect Jellyfin"
        title.font = .systemFont(ofSize: 52, weight: .bold)
        title.textColor = .white

        let subtitle = UILabel()
        subtitle.text = "Use your Jellyfin profile or Quick Connect."
        subtitle.font = .systemFont(ofSize: 25, weight: .regular)
        subtitle.textColor = UIColor.white.withAlphaComponent(0.62)

        configureField(serverField, placeholder: "Server address", contentType: .URL)
        serverField.keyboardType = .URL
        serverField.autocapitalizationType = .none
        serverField.autocorrectionType = .no
        serverField.text = UserDefaults.standard.string(forKey: Keys.lastServerURL)

        configureField(usernameField, placeholder: "Username", contentType: .username)
        usernameField.autocapitalizationType = .none
        usernameField.autocorrectionType = .no

        configureField(passwordField, placeholder: "Password", contentType: .password)
        passwordField.isSecureTextEntry = true

        connectButton.configuration = primaryButtonConfiguration(title: "Connect", image: "arrow.right")
        connectButton.addTarget(self, action: #selector(connectPressed), for: .primaryActionTriggered)

        quickConnectButton.configuration = secondaryButtonConfiguration(title: "Quick Connect", image: "qrcode")
        quickConnectButton.addTarget(self, action: #selector(quickConnectPressed), for: .primaryActionTriggered)

        closeButton.configuration = secondaryButtonConfiguration(title: "Cancel", image: "xmark")
        closeButton.addTarget(self, action: #selector(closePressed), for: .primaryActionTriggered)

        statusLabel.font = .systemFont(ofSize: 23, weight: .medium)
        statusLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        statusLabel.numberOfLines = 2
        statusLabel.textAlignment = .center
        statusLabel.isHidden = true

        quickCodeLabel.font = .monospacedDigitSystemFont(ofSize: 58, weight: .semibold)
        quickCodeLabel.textColor = .white
        quickCodeLabel.textAlignment = .center
        quickCodeLabel.isHidden = true

        activity.hidesWhenStopped = true
        activity.color = .white

        let buttonRow = UIStackView(arrangedSubviews: [quickConnectButton, connectButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 22
        buttonRow.distribution = .fillEqually

        let stack = UIStackView(arrangedSubviews: [
            title, subtitle, serverField, usernameField, passwordField,
            buttonRow, quickCodeLabel, activity, statusLabel, closeButton
        ])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 22
        stack.setCustomSpacing(42, after: subtitle)
        stack.setCustomSpacing(32, after: passwordField)
        backdrop.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            backdrop.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            backdrop.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            backdrop.widthAnchor.constraint(equalToConstant: 940),
            backdrop.heightAnchor.constraint(greaterThanOrEqualToConstant: 750),

            stack.topAnchor.constraint(equalTo: backdrop.contentView.topAnchor, constant: 58),
            stack.leadingAnchor.constraint(equalTo: backdrop.contentView.leadingAnchor, constant: 72),
            stack.trailingAnchor.constraint(equalTo: backdrop.contentView.trailingAnchor, constant: -72),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: backdrop.contentView.bottomAnchor, constant: -48),

            serverField.heightAnchor.constraint(equalToConstant: 76),
            usernameField.heightAnchor.constraint(equalToConstant: 76),
            passwordField.heightAnchor.constraint(equalToConstant: 76),
            buttonRow.heightAnchor.constraint(equalToConstant: 82),
            closeButton.heightAnchor.constraint(equalToConstant: 68)
        ])
    }

    private func configureField(
        _ field: UITextField,
        placeholder: String,
        contentType: UITextContentType
    ) {
        field.placeholder = placeholder
        field.textContentType = contentType
        field.font = .systemFont(ofSize: 29, weight: .medium)
        field.textColor = .white
        field.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        field.layer.cornerRadius = 18
        field.layer.cornerCurve = .continuous
        field.layer.borderWidth = 1
        field.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 1))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 1))
        field.rightViewMode = .always
        field.clearButtonMode = .whileEditing
    }

    private func primaryButtonConfiguration(title: String, image: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePlacement = .trailing
        configuration.imagePadding = 14
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.systemBlue.withAlphaComponent(0.86)
        configuration.baseForegroundColor = .white
        return configuration
    }

    private func secondaryButtonConfiguration(title: String, image: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePadding = 12
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = UIColor.white.withAlphaComponent(0.10)
        configuration.baseForegroundColor = .white
        return configuration
    }

    @objc private func connectPressed() {
        guard operation == nil else { return }
        let server = serverField.text ?? ""
        let username = usernameField.text ?? ""
        let password = passwordField.text ?? ""
        guard !server.isEmpty, !username.isEmpty else {
            showStatus("Enter your server address and username.", isError: true)
            return
        }

        // Remove the password from UIKit's backing storage before any network
        // suspension. The immutable request value is retained only for the
        // lifetime of this authentication task and is never persisted or logged.
        passwordField.text = nil

        setBusy(true, message: "Connecting…")
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                self.operation = nil
                self.passwordField.text = nil
            }
            do {
                let transport = try JellyfinTransport(
                    serverURL: server,
                    clientIdentity: JellyfinSessionStore.clientIdentity()
                )
                let client = JellyfinAuthClient(transport: transport)
                _ = try await client.publicSystemInfo()
                let session = try await client.authenticate(username: username, password: password)
                try await JellyfinSessionStore.shared.persist(session)
                UserDefaults.standard.set(session.serverURL.absoluteString, forKey: Keys.lastServerURL)
                MediaProviderRegistry.shared.populateFromCurrentAuth()
                if let jellyfinID = MediaProviderRegistry.shared.enabledProviders()
                    .first(where: { $0.kind == .jellyfin })?.id {
                    MediaProviderRegistry.shared.selectPrimaryProvider(jellyfinID)
                }
                self.finishAuthentication()
            } catch is CancellationError {
                self.setBusy(false)
            } catch {
                self.setBusy(false)
                self.showStatus(Self.userFacingMessage(for: error), isError: true)
            }
        }
    }

    @objc private func quickConnectPressed() {
        guard operation == nil else { return }
        let server = serverField.text ?? ""
        guard !server.isEmpty else {
            showStatus("Enter your server address first.", isError: true)
            return
        }

        setBusy(true, message: "Starting Quick Connect…")
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            do {
                let transport = try JellyfinTransport(
                    serverURL: server,
                    clientIdentity: JellyfinSessionStore.clientIdentity()
                )
                let client = JellyfinAuthClient(transport: transport)
                guard try await client.isQuickConnectEnabled() else {
                    throw JellyfinAPIError.forbidden(message: "Quick Connect is disabled on this server.")
                }
                let started = try await client.startQuickConnect()
                self.quickCodeLabel.text = started.code
                self.quickCodeLabel.isHidden = false
                self.showStatus("Approve this code from an authenticated Jellyfin device.", isError: false)

                let deadline = Date().addingTimeInterval(300)
                var state = started
                while !state.authenticated {
                    try Task.checkCancellation()
                    guard Date() < deadline else {
                        throw JellyfinAPIError.unauthorized(message: "Quick Connect expired. Try again.")
                    }
                    try await Task.sleep(for: .seconds(2))
                    state = try await client.pollQuickConnect(secret: started.secret)
                }

                let session = try await client.authenticateWithQuickConnect(secret: started.secret)
                try await JellyfinSessionStore.shared.persist(session)
                UserDefaults.standard.set(session.serverURL.absoluteString, forKey: Keys.lastServerURL)
                MediaProviderRegistry.shared.populateFromCurrentAuth()
                if let jellyfinID = MediaProviderRegistry.shared.enabledProviders()
                    .first(where: { $0.kind == .jellyfin })?.id {
                    MediaProviderRegistry.shared.selectPrimaryProvider(jellyfinID)
                }
                self.finishAuthentication()
            } catch is CancellationError {
                self.setBusy(false)
            } catch {
                self.setBusy(false)
                self.quickCodeLabel.isHidden = true
                self.showStatus(Self.userFacingMessage(for: error), isError: true)
            }
        }
    }

    @objc private func closePressed() {
        cancelOperation()
        dismiss(animated: true)
    }

    private func cancelOperation() {
        operation?.cancel()
        operation = nil
        passwordField.text = nil
        quickCodeLabel.text = nil
        quickCodeLabel.isHidden = true
    }

    private func setBusy(_ busy: Bool, message: String? = nil) {
        connectButton.isEnabled = !busy
        quickConnectButton.isEnabled = !busy
        serverField.isEnabled = !busy
        usernameField.isEnabled = !busy
        passwordField.isEnabled = !busy
        if busy { activity.startAnimating() } else { activity.stopAnimating() }
        if let message { showStatus(message, isError: false) }
    }

    private func showStatus(_ message: String, isError: Bool) {
        statusLabel.text = message
        statusLabel.textColor = isError ? .systemRed : UIColor.white.withAlphaComponent(0.72)
        statusLabel.isHidden = false
    }

    private func finishAuthentication() {
        setBusy(false)
        quickCodeLabel.isHidden = true
        showStatus("Connected", isError: false)
        UIView.animate(withDuration: 0.25, animations: {
            self.view.alpha = 0
        }, completion: { _ in
            self.dismiss(animated: false)
        })
    }

    /// Deliberately maps errors to a fixed vocabulary. Server response bodies
    /// and request diagnostics can include deployment-specific details and must
    /// never be surfaced as an authentication status message.
    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case JellyfinAPIError.invalidServerURL:
            return "Enter a valid Jellyfin server address."
        case JellyfinAPIError.unauthorized:
            return "The username or password was not accepted."
        case JellyfinAPIError.forbidden:
            return "This Jellyfin account cannot complete that request."
        case JellyfinAPIError.transport:
            return "The Jellyfin server could not be reached."
        case JellyfinAPIError.server:
            return "The Jellyfin server returned an error. Try again."
        case JellyfinAPIError.invalidResponse, JellyfinAPIError.decoding:
            return "The server response could not be verified."
        default:
            return "Jellyfin could not be connected. Try again."
        }
    }
}
