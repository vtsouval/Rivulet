// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AuthenticationServices
import Foundation
import UIKit

@MainActor
final class IOSJellyfinPasskeyCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {

    static let shared = IOSJellyfinPasskeyCoordinator()

    static var isAvailableInThisBuild: Bool {
        #if FREE_PROVISIONING
        false
        #else
        true
        #endif
    }

    private var continuation: CheckedContinuation<any ASAuthorizationCredential, Error>?
    private var authorizationController: ASAuthorizationController?

    func assertion(
        options: JellyfinPasskeyAssertionOptions,
        fallbackRelyingPartyID: String
    ) async throws -> JellyfinPasskeyCredentialPayload {
        guard let challenge = options.challenge.jellyfinBase64URLData else {
            throw JellyfinAPIError.decoding(message: "The passkey challenge was invalid.")
        }
        let relyingPartyID = options.rpId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let relyingPartyID, !relyingPartyID.isEmpty,
           relyingPartyID.caseInsensitiveCompare(fallbackRelyingPartyID) != .orderedSame {
            throw JellyfinAPIError.forbidden(
                message: "The passkey relying party does not match this Jellyfin server."
            )
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyID?.isEmpty == false ? relyingPartyID! : fallbackRelyingPartyID
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.userVerificationPreference = .required
        request.allowedCredentials = options.allowCredentials.compactMap { descriptor in
            guard let id = descriptor.id.jellyfinBase64URLData else { return nil }
            return ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: id)
        }

        let credential = try await authorize(request)
        guard let assertion = credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            throw JellyfinAPIError.invalidAuthenticationResponse
        }
        let credentialID = assertion.credentialID.jellyfinBase64URLString
        return JellyfinPasskeyCredentialPayload(
            id: credentialID,
            rawId: credentialID,
            type: "public-key",
            authenticatorAttachment: "platform",
            response: JellyfinPasskeyCredentialResponse(
                clientDataJSON: assertion.rawClientDataJSON.jellyfinBase64URLString,
                authenticatorData: assertion.rawAuthenticatorData.jellyfinBase64URLString,
                signature: assertion.signature.jellyfinBase64URLString,
                userHandle: assertion.userID.isEmpty ? nil : assertion.userID.jellyfinBase64URLString,
                attestationObject: nil,
                transports: nil
            ),
            clientExtensionResults: [:]
        )
    }

    func registration(
        options: JellyfinPasskeyRegistrationOptions,
        fallbackRelyingPartyID: String
    ) async throws -> JellyfinPasskeyCredentialPayload {
        guard let challenge = options.challenge.jellyfinBase64URLData,
              let userID = options.user.id.jellyfinBase64URLData else {
            throw JellyfinAPIError.decoding(message: "The passkey enrollment challenge was invalid.")
        }
        let relyingPartyID = options.rp.id?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let relyingPartyID, !relyingPartyID.isEmpty,
           relyingPartyID.caseInsensitiveCompare(fallbackRelyingPartyID) != .orderedSame {
            throw JellyfinAPIError.forbidden(
                message: "The passkey relying party does not match this Jellyfin server."
            )
        }
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyID?.isEmpty == false ? relyingPartyID! : fallbackRelyingPartyID
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challenge,
            name: options.user.name,
            userID: userID
        )
        request.displayName = options.user.displayName
        request.userVerificationPreference = .required
        request.attestationPreference = .none

        let credential = try await authorize(request)
        guard let registration = credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration,
              let attestation = registration.rawAttestationObject else {
            throw JellyfinAPIError.invalidAuthenticationResponse
        }
        let credentialID = registration.credentialID.jellyfinBase64URLString
        return JellyfinPasskeyCredentialPayload(
            id: credentialID,
            rawId: credentialID,
            type: "public-key",
            authenticatorAttachment: "platform",
            response: JellyfinPasskeyCredentialResponse(
                clientDataJSON: registration.rawClientDataJSON.jellyfinBase64URLString,
                authenticatorData: nil,
                signature: nil,
                userHandle: nil,
                attestationObject: attestation.jellyfinBase64URLString,
                transports: ["internal"]
            ),
            clientExtensionResults: [:]
        )
    }

    private func authorize(
        _ request: ASAuthorizationRequest
    ) async throws -> any ASAuthorizationCredential {
        guard continuation == nil else {
            throw JellyfinAPIError.http(statusCode: 409, message: "Another passkey request is already active.")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            authorizationController = controller
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        finish(.success(authorization.credential))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        finish(.failure(error))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
            ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<any ASAuthorizationCredential, Error>) {
        let pending = continuation
        continuation = nil
        authorizationController = nil
        pending?.resume(with: result)
    }
}
