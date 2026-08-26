// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
#if !targetEnvironment(macCatalyst)
import Vision
import VisionKit
#endif

struct IOSJellyfinQuickConnectCodeView: View {
    let code: String
    let payloadURL: URL?

    var body: some View {
        VStack(spacing: 18) {
            if let payloadURL, let image = Self.qrImage(for: payloadURL) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210, height: 210)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .accessibilityLabel("Quick Connect QR code")
            }
            Text(code)
                .font(.system(.largeTitle, design: .monospaced, weight: .bold))
                .tracking(6)
                .contentTransition(.numericText())
            Text("Scan with your phone to approve securely")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    static func qrImage(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return nil
        }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct IOSJellyfinQuickConnectAuthorizerView: View {
    @EnvironmentObject private var jellyfin: IOSJellyfinSession
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var isWorking = false
    @State private var showsScanner = false
    @State private var message: String?
    @State private var succeeded = false
    @State private var pendingPayload: JellyfinQuickConnectPayload?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    #if !targetEnvironment(macCatalyst)
                    if DataScannerViewController.isSupported,
                       DataScannerViewController.isAvailable {
                        Button("Scan QR Code", systemImage: "qrcode.viewfinder") {
                            showsScanner = true
                        }
                        .disabled(isWorking)
                    }
                    #endif

                    HStack(spacing: 10) {
                        TextField("Quick Connect code", text: $code)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.system(.title3, design: .monospaced, weight: .semibold))
                            .onSubmit(prepareTypedCode)
                        Button(action: prepareTypedCode) {
                            Image(systemName: isWorking ? "hourglass" : "arrow.right")
                                .frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderedProminent)
                        .buttonBorderShape(.circle)
                        .disabled(isWorking || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Approve the code shown by an Apple TV, iPhone, iPad, or another Jellyfin client.")
                }

                if let message {
                    Section {
                        Label(message, systemImage: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(succeeded ? .green : .orange)
                    }
                }
            }
            .navigationTitle("Connect a Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        #if !targetEnvironment(macCatalyst)
        .fullScreenCover(isPresented: $showsScanner) {
            IOSJellyfinQRCodeScannerView { value in
                showsScanner = false
                Task { await authorizeScanned(value) }
            }
        }
        #endif
        .confirmationDialog(
            "Connect this device?",
            isPresented: Binding(
                get: { pendingPayload != nil },
                set: { if !$0 { pendingPayload = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Authorize") { Task { await authorizePendingPayload() } }
            Button("Cancel", role: .cancel) { pendingPayload = nil }
        } message: {
            Text(confirmationMessage)
        }
        .sensoryFeedback(.success, trigger: succeeded)
    }

    private var confirmationMessage: String {
        guard let pendingPayload else { return "" }
        return "Approve only if code \(pendingPayload.code) is visible on the device in front of you."
    }

    private func prepareTypedCode() {
        do {
            guard let session = jellyfin.provider?.session else { throw MediaProviderError.unauthorized }
            pendingPayload = try JellyfinQuickConnectPayload(serverURL: session.serverURL, code: code)
        } catch {
            succeeded = false
            message = IOSJellyfinSession.message(for: error)
        }
    }

    private func authorizeScanned(_ value: String) async {
        do {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let payload: JellyfinQuickConnectPayload
            if let url = URL(string: trimmed), url.scheme != nil {
                payload = try JellyfinQuickConnectPayload(url: url)
            } else {
                guard let session = jellyfin.provider?.session else { throw MediaProviderError.unauthorized }
                payload = try JellyfinQuickConnectPayload(serverURL: session.serverURL, code: trimmed)
            }
            guard let session = jellyfin.provider?.session, payload.belongs(to: session) else {
                throw JellyfinAPIError.forbidden(message: "This Quick Connect request belongs to another Jellyfin server.")
            }
            pendingPayload = payload
        } catch {
            succeeded = false
            message = IOSJellyfinSession.message(for: error)
        }
    }

    private func authorizePendingPayload() async {
        guard !isWorking, let payload = pendingPayload else { return }
        pendingPayload = nil
        isWorking = true
        defer { isWorking = false }
        do {
            try await jellyfin.authorizeQuickConnect(payload: payload)
            succeeded = true
            message = "Device connected"
            code = ""
        } catch {
            succeeded = false
            message = IOSJellyfinSession.message(for: error)
        }
    }
}

#if !targetEnvironment(macCatalyst)
private struct IOSJellyfinQRCodeScannerView: UIViewControllerRepresentable {
    let recognized: (String) -> Void

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let recognized: (String) -> Void
        private var completed = false

        init(recognized: @escaping (String) -> Void) { self.recognized = recognized }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !completed else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let value = barcode.payloadStringValue else { continue }
                completed = true
                dataScanner.stopScanning()
                recognized(value)
                return
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(recognized: recognized) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard DataScannerViewController.isAvailable else { return }
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }
}
#endif
