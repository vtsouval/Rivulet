# Apple builds and installation

Rivulet contains two application targets that share the same media-provider,
authentication, playback-negotiation, and security code:

- `Rivulet` is the native tvOS application.
- `Rivulet iOS` is the touch application for iPhone and iPad and also builds as
  a native Mac Catalyst application.

The Jellyfin client supports password sign-in and Quick Connect on every
platform. Passwords are used only for the authentication request. The returned
revocable Jellyfin token is stored in the app-scoped Apple Keychain using
`AfterFirstUnlockThisDeviceOnly`; it is revalidated on launch and is deleted on
sign-out or after rejection by the server.

## One-time Xcode setup

1. Install Xcode 26 or newer and the iOS and tvOS 26 platform runtimes.
2. In Xcode, open **Settings > Accounts** and add the Apple ID used for local
   development.
3. Open `Rivulet.xcodeproj`. Select each app target and choose your team under
   **Signing & Capabilities**. Use unique bundle identifiers if Xcode reports a
   conflict.
4. Copy the safe placeholder configuration if it does not exist:

   ```bash
   cp RivuletCore/Config/Secrets.swift.template RivuletCore/Config/Secrets.swift
   ```

5. On each physical device, enable Developer Mode. The first launch from a
   free Personal Team may also require trusting the developer profile in
   **Settings > General > VPN & Device Management**.

## Reproducible command-line builds

The helper keeps every platform in one DerivedData directory so Xcode does not
duplicate several gigabytes of Swift-package artifacts:

```bash
./Scripts/build-apple.sh ios-simulator
./Scripts/build-apple.sh macos
./Scripts/build-apple.sh macos-install
./Scripts/build-apple.sh tvos-simulator
./Scripts/build-apple.sh test
```

For a connected iPhone or iPad, list devices and pass its CoreDevice identifier:

```bash
xcrun devicectl list devices
./Scripts/build-apple.sh ios-device DEVICE_IDENTIFIER
./Scripts/build-apple.sh package-ios
```

For a paired Apple TV with Developer Mode enabled:

```bash
xcrun devicectl list devices
./Scripts/build-apple.sh tvos-device DEVICE_IDENTIFIER
```

The device commands build, install, and launch the app. A Personal Team build
is intended only for local testing and normally expires after a short period;
TestFlight/App Store distribution requires a paid Apple Developer membership
and an archive signed with a distribution profile.

If installation succeeds but automatic launch reports that the device is
locked, unlock the device and open **Rivulet** from the Home Screen. The signed
installation is already complete; no rebuild or profile-trust step is needed.

Debug builds use free-development entitlements. On Apple TV this means App
Attest and the Top Shelf shared App Group are disabled; the main Jellyfin,
playback, and Live TV experience remains available. Release builds retain the
full App Attest and App Group entitlements for a paid team.

## macOS

`./Scripts/build-apple.sh macos` produces:

`build/DerivedData/Build/Products/Debug-maccatalyst/Rivulet iOS.app`

To create redistributable local-development artifacts after the signed builds:

```bash
./Scripts/build-apple.sh package-ios
./Scripts/build-apple.sh package-macos
```

Artifacts are written under `build/packages/`. Development-signed IPAs can be
installed only on devices registered to the signing team; they are not App
Store or public sideloading packages.

The Catalyst build uses AVPlayer and Jellyfin's Apple-compatible HLS/remux
route because the bundled AetherEngine FFmpeg artifacts do not contain Catalyst
slices. iPhone, iPad, and tvOS retain AetherEngine direct play where supported.

## Face ID, passkeys, and Sign in with Apple

- Face ID/Touch ID app lock works with local development signing and protects
  access to an already authenticated profile. Biometric data never leaves the
  device.
- Native passkeys are compiled into Release builds. They require the
  `webcredentials:flix.isma.sbs` Associated Domains entitlement, a paid
  provisioning profile that authorizes that entitlement, an Apple App Site
  Association file at `https://flix.isma.sbs/.well-known/apple-app-site-association`,
  and matching server endpoints. Debug Personal Team builds deliberately omit
  this unavailable capability and hide the passkey action.
- Sign in with Apple is not a secure drop-in replacement for a Jellyfin login.
  It would require a server component that validates Apple's identity token and
  explicitly links its stable subject to a Jellyfin user. Rivulet does not
  impersonate that flow or store an Apple password.

## Security and diagnostics

- Never commit `Secrets.swift`, provisioning profiles, access tokens, passwords,
  build products, or exported `.ipa` files.
- Keychain diagnostics may log an Apple `OSStatus` integer but never the account
  key or credential value.
- Upstream resolver/debrid credentials remain on the Jellyfin server. The app
  receives only Jellyfin metadata and the playback URL negotiated for its own
  authenticated session.
- Revoke a lost device from Jellyfin's device/session management; the next app
  launch rejects the stored token and returns to sign-in.
