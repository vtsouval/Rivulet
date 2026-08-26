// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import LocalAuthentication
import SwiftUI

@MainActor
enum IOSDeviceAuthentication {
    static func availableBiometryName() -> String? {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    static func authenticate(reason: String) async throws {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Device Passcode"
        var error: NSError?
        let biometricPolicyAvailable = context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &error
        )
        let policy: LAPolicy = biometricPolicyAvailable
            ? .deviceOwnerAuthenticationWithBiometrics
            : .deviceOwnerAuthentication
        guard context.canEvaluatePolicy(policy, error: &error) else {
            throw error ?? LAError(.biometryNotAvailable)
        }
        guard try await context.evaluatePolicy(policy, localizedReason: reason) else {
            throw LAError(.authenticationFailed)
        }
    }
}

struct IOSAppLockGate<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("ios.requireDeviceAuthentication") private var requiresAuthentication = false
    @State private var isLocked = false
    @State private var isAuthenticating = false
    @State private var error: String?

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .privacySensitive()
                .blur(radius: isLocked ? 18 : 0)
                .allowsHitTesting(!isLocked)

            if isLocked {
                LinearGradient(
                    colors: [.black, Color(red: 0.03, green: 0.12, blue: 0.18)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                VStack(spacing: 18) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text("Rivulet is locked").font(.title2.bold())
                    if let error {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await unlock() }
                    } label: {
                        Label(isAuthenticating ? "Unlocking…" : "Unlock", systemImage: "faceid")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isAuthenticating)
                }
                .padding(28)
            }
        }
        .task {
            guard requiresAuthentication else { return }
            isLocked = true
            await unlock()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .inactive, .background:
                if requiresAuthentication {
                    isLocked = true
                }
            case .active:
                guard requiresAuthentication, isLocked else { return }
                Task { await unlock() }
            @unknown default:
                if requiresAuthentication { isLocked = true }
            }
        }
        .onChange(of: requiresAuthentication) { _, enabled in
            if !enabled { isLocked = false; error = nil }
        }
    }

    private func unlock() async {
        guard requiresAuthentication, !isAuthenticating else {
            if !requiresAuthentication { isLocked = false }
            return
        }
        isAuthenticating = true
        defer { isAuthenticating = false }
        do {
            try await IOSDeviceAuthentication.authenticate(reason: "Unlock your Jellyfin profile")
            withAnimation(.smooth(duration: 0.28)) { isLocked = false }
            error = nil
        } catch let localError as LAError where localError.code == .userCancel || localError.code == .appCancel {
            error = nil
        } catch {
            self.error = "Authentication was not completed."
        }
    }
}
