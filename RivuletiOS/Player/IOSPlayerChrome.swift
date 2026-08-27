// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit
import AVKit
import MediaPlayer

struct IOSPlayerControlButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var compact = true
    var dense = false
    var grouped = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: dense ? 16 : (compact ? 18 : 22), weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: diameter, height: diameter)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(
                    prominent ? Color.white : (grouped ? Color.clear : Color.white.opacity(0.10)),
                    in: Circle()
                )
                .overlay {
                    if !prominent, !grouped {
                        Circle().stroke(.white.opacity(0.10), lineWidth: 1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .accessibilityLabel(title)
    }

    private var diameter: CGFloat { dense ? 44 : (compact ? 48 : 60) }
}

/// Apple's native route picker. Native AVPlayer/HLS playback can hand video
/// directly to AirPlay, while software-decoded playback retains system audio
/// routing and screen mirroring. Device discovery and selection remain inside
/// the system UI and no receiver information is stored by the app.
struct IOSAirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = true
        view.activeTintColor = .systemCyan
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

/// System volume is intentionally used instead of a private player scalar so
/// hardware volume buttons and the on-screen slider always stay synchronized.
struct IOSSystemVolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> IOSVolumeControlView {
        IOSVolumeControlView()
    }

    func updateUIView(_ uiView: IOSVolumeControlView, context: Context) {}
}

/// `MPVolumeView` remains the interactive system control while a synchronized
/// public `UISlider` supplies a stable Liquid Glass visual on iOS versions
/// where the system slider's track is transparent. Hardware-button changes
/// are mirrored through the audio session's documented output-volume value.
final class IOSVolumeControlView: UIView {
    private let systemVolumeView = MPVolumeView(frame: .zero)
    private let visibleSlider = UISlider(frame: .zero)
    private var volumeObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)

        systemVolumeView.showsRouteButton = false
        systemVolumeView.showsVolumeSlider = true
        addSubview(systemVolumeView)

        visibleSlider.minimumValue = 0
        visibleSlider.maximumValue = 1
        visibleSlider.minimumTrackTintColor = .white
        visibleSlider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.30)
        visibleSlider.thumbTintColor = .white
        visibleSlider.isUserInteractionEnabled = false
        addSubview(visibleSlider)

        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.initial, .new]
        ) { [weak self] _, change in
            guard let value = change.newValue else { return }
            DispatchQueue.main.async { self?.visibleSlider.value = value }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        systemVolumeView.frame = bounds
        visibleSlider.frame = bounds
    }
}

/// A transport action positioned by `IOSAdaptivePlayerChrome`. Keeping the
/// action model independent from a specific player lets Jellyfin, Plex and
/// both Live TV paths use one predictable touch layout.
struct IOSPlayerTransportAction {
    let title: String
    let systemImage: String
    var prominent = false
    var disabled = false
    let action: () -> Void
}

enum IOSPlayerSkipSymbol {
    static func backward(_ seconds: Int) -> String {
        skipSymbol(prefix: "gobackward", seconds: seconds)
    }

    static func forward(_ seconds: Int) -> String {
        skipSymbol(prefix: "goforward", seconds: seconds)
    }

    private static func skipSymbol(prefix: String, seconds: Int) -> String {
        switch seconds {
        case 5, 10, 15, 30, 45, 60, 75, 90:
            return "\(prefix).\(seconds)"
        default:
            return prefix
        }
    }
}

/// Shared iPhone and iPad player chrome modelled after the system iOS player:
/// utilities float at the top, transport remains centered over the video, and
/// metadata/progress/secondary controls live in a restrained bottom layer.
/// This avoids the single oversized rail that previously overlapped content.
struct IOSAdaptivePlayerChrome<SecondaryControls: View>: View {
    let eyebrow: String?
    let title: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isSeekable: Bool
    let leadingAction: IOSPlayerTransportAction?
    let primaryAction: IOSPlayerTransportAction
    let trailingAction: IOSPlayerTransportAction?
    let onClose: () -> Void
    let onSeek: (TimeInterval) -> Void
    @ViewBuilder let secondaryControls: () -> SecondaryControls

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            let wide = horizontalSizeClass == .regular || geometry.size.width >= 700
            let leadingInset = max(14, geometry.safeAreaInsets.leading + 12)
            let trailingInset = max(14, geometry.safeAreaInsets.trailing + 12)
            let bottomInset = max(12, geometry.safeAreaInsets.bottom + 8)

            ZStack {
                topUtilities(landscape: landscape, wide: wide)
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .padding(.top, max(10, geometry.safeAreaInsets.top + 8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                transportControls(landscape: landscape, wide: wide)
                    .opacity(primaryAction.disabled ? 0 : 1)
                    .animation(.easeInOut(duration: 0.18), value: primaryAction.disabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                bottomChrome(landscape: landscape, wide: wide)
                    .frame(maxWidth: wide ? min(1_080, geometry.size.width - leadingInset - trailingInset) : .infinity)
                    .padding(.leading, leadingInset)
                    .padding(.trailing, trailingInset)
                    .padding(.bottom, bottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: IOSPlayerRailTopPreferenceKey.self,
                                value: proxy.frame(in: .named(IOSPlayerChromeCoordinateSpace.name)).minY
                            )
                        }
                    }
            }
            .background {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.58), location: 0),
                        .init(color: .clear, location: 0.28),
                        .init(color: .clear, location: 0.54),
                        .init(color: .black.opacity(0.82), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }

    private func topUtilities(landscape: Bool, wide: Bool) -> some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 48)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("Close player")

            IOSAirPlayRouteButton()
                .frame(width: 48, height: 48)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("AirPlay and output devices")

            Spacer(minLength: 12)

            HStack(spacing: 9) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .accessibilityHidden(true)
                IOSSystemVolumeSlider()
                    .frame(width: wide ? 160 : (landscape ? 135 : 62), height: 34)
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
            .glassEffect(.regular.interactive(), in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("System volume")
        }
    }

    private func transportControls(landscape: Bool, wide: Bool) -> some View {
        HStack(spacing: wide ? 26 : (landscape ? 22 : 18)) {
            if let leadingAction {
                transportButton(leadingAction, diameter: wide ? 62 : 54)
            }
            transportButton(primaryAction, diameter: wide ? 78 : 68)
            if let trailingAction {
                transportButton(trailingAction, diameter: wide ? 62 : 54)
            }
        }
        .padding(.horizontal, 10)
        .offset(y: landscape ? -4 : -10)
    }

    private func transportButton(_ action: IOSPlayerTransportAction, diameter: CGFloat) -> some View {
        Button(action: action.action) {
            Image(systemName: action.systemImage)
                .font(.system(size: action.prominent ? diameter * 0.42 : diameter * 0.34, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(action.prominent ? Color.black : Color.white)
                .frame(width: diameter, height: diameter)
                .background(action.prominent ? Color.white.opacity(0.94) : Color.clear, in: Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(action.disabled)
        .opacity(action.disabled ? 0.42 : 1)
        .accessibilityLabel(action.title)
    }

    @ViewBuilder
    private func bottomChrome(landscape: Bool, wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: landscape ? 9 : 12) {
            if landscape || wide {
                HStack(alignment: .bottom, spacing: 18) {
                    metadataBlock(wide: wide)
                    Spacer(minLength: 18)
                    secondaryPill
                }
            } else {
                metadataBlock(wide: false)
            }

            if duration > 0 {
                IOSPlayerProgressScrubber(
                    currentTime: currentTime,
                    duration: duration,
                    isSeekable: isSeekable,
                    leadingLabel: nil,
                    trailingLabel: nil,
                    onSeek: onSeek
                )
            }

            if !landscape, !wide {
                secondaryPill
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func metadataBlock(wide: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(.system(size: wide ? 16 : 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            Text(title)
                .font(.system(size: wide ? 27 : 21, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .shadow(color: .black.opacity(0.55), radius: 8, y: 2)
        .frame(maxWidth: wide ? 520 : .infinity, alignment: .leading)
    }

    private var secondaryPill: some View {
        HStack(spacing: 2) {
            secondaryControls()
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .fixedSize(horizontal: true, vertical: false)
    }
}

enum IOSMediaAudioSession {
    static func activateForVideo() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playback,
            mode: .moviePlayback,
            policy: .longFormAudio
        )
        try session.setActive(true)
    }
}

private struct IOSPlayerProgressScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isSeekable: Bool
    let leadingLabel: String?
    let trailingLabel: String?
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: CGFloat?

    private var progress: CGFloat {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width * progress)

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(red: 0x7f / 255, green: 0xb8 / 255, blue: 0xff / 255), location: 0),
                                    .init(color: Color(red: 0xb9 / 255, green: 0xa3 / 255, blue: 0xff / 255), location: 0.45),
                                    .init(color: Color(red: 0xff / 255, green: 0xce / 255, blue: 0x93 / 255), location: 0.80),
                                    .init(color: Color(red: 0x8f / 255, green: 0xe9 / 255, blue: 0xd4 / 255), location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width)

                    Circle()
                        .fill(.white)
                        .frame(width: isSeekable ? 12 : 8, height: isSeekable ? 12 : 8)
                        .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 4) }
                        .offset(x: min(max(0, width - (isSeekable ? 6 : 4)), max(0, geometry.size.width - (isSeekable ? 12 : 8))))
                }
                .frame(height: isSeekable ? 8 : 6)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isSeekable, geometry.size.width > 0 else { return }
                            dragFraction = min(max(value.location.x / geometry.size.width, 0), 1)
                        }
                        .onEnded { value in
                            guard isSeekable, geometry.size.width > 0 else { return }
                            let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            dragFraction = nil
                            onSeek(duration * fraction)
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Self.format(currentTime)) of \(Self.format(duration))")
            }
            .frame(height: 18)

            HStack {
                Text(leadingLabel ?? Self.format(currentTime))
                Spacer()
                Text(trailingLabel ?? "−\(Self.format(max(0, duration - currentTime)))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum IOSPlayerChromeCoordinateSpace {
    static let name = "ios-player-chrome"
}

struct IOSPlayerRailTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else { return }
        value = min(value ?? next, next)
    }
}

/// UIKit recognizers provide reliable single-vs-double-tap arbitration and
/// retain the touch location, which SwiftUI's simple `onTapGesture(count:)`
/// does not expose. The player controls are layered above this surface.
struct IOSPlayerTapSurface: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTapLeft: () -> Void
    let onDoubleTapRight: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onDoubleTapLeft: onDoubleTapLeft,
            onDoubleTapRight: onDoubleTapRight
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.singleTap)
        )
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTapLeft = onDoubleTapLeft
        context.coordinator.onDoubleTapRight = onDoubleTapRight
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onDoubleTapLeft: () -> Void
        var onDoubleTapRight: () -> Void

        init(
            onSingleTap: @escaping () -> Void,
            onDoubleTapLeft: @escaping () -> Void,
            onDoubleTapRight: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTapLeft = onDoubleTapLeft
            self.onDoubleTapRight = onDoubleTapRight
        }

        @objc func singleTap() {
            onSingleTap()
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            if location.x < view.bounds.midX {
                onDoubleTapLeft()
            } else {
                onDoubleTapRight()
            }
        }
    }
}
