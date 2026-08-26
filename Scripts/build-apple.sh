#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${ROOT_DIR}/build/DerivedData"
PROJECT="${ROOT_DIR}/Rivulet.xcodeproj"
COMMAND="${1:-help}"
DEVICE_ID="${2:-}"

build_ios_device() {
  if [[ -z "${DEVICE_ID}" ]]; then
    echo "Usage: $0 ios-device DEVICE_IDENTIFIER" >&2
    exit 64
  fi
  xcodebuild -project "${PROJECT}" -scheme "Rivulet iOS" \
    -configuration Debug -destination "id=${DEVICE_ID}" \
    -derivedDataPath "${DERIVED_DATA}" -allowProvisioningUpdates build
  local app="${DERIVED_DATA}/Build/Products/Debug-iphoneos/Rivulet iOS.app"
  xcrun devicectl device install app --device "${DEVICE_ID}" "${app}"
  xcrun devicectl device process launch --device "${DEVICE_ID}" \
    com.vtsouval.jellyplugs.rivulet
}

build_tvos_device() {
  if [[ -z "${DEVICE_ID}" ]]; then
    echo "Usage: $0 tvos-device DEVICE_IDENTIFIER" >&2
    exit 64
  fi
  xcodebuild -project "${PROJECT}" -scheme Rivulet \
    -configuration Debug -destination "id=${DEVICE_ID}" \
    -derivedDataPath "${DERIVED_DATA}" -allowProvisioningUpdates build
  local app="${DERIVED_DATA}/Build/Products/Debug-appletvos/Rivulet.app"
  xcrun devicectl device install app --device "${DEVICE_ID}" "${app}"
  xcrun devicectl device process launch --device "${DEVICE_ID}" \
    com.vtsouval.jellyplugs.rivulet
}

package_ios() {
  local app="${DERIVED_DATA}/Build/Products/Debug-iphoneos/Rivulet iOS.app"
  [[ -d "${app}" ]] || { echo "Build the iOS device app first." >&2; exit 66; }
  local version build_number package_dir stage ipa
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Info.plist")"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Info.plist")"
  package_dir="${ROOT_DIR}/build/packages"
  stage="$(mktemp -d)"
  # Expand the function-local path now. A deferred reference to `stage`
  # becomes unbound after this function returns under `set -u`.
  trap "rm -rf '${stage}'" EXIT
  mkdir -p "${stage}/Payload" "${package_dir}"
  ditto "${app}" "${stage}/Payload/Rivulet.app"
  ipa="${package_dir}/Rivulet-iOS-${version}-build${build_number}-device.ipa"
  rm -f "${ipa}"
  (cd "${stage}" && ditto -c -k --sequesterRsrc Payload "${ipa}")
  echo "${ipa}"
}

package_macos() {
  local app="${DERIVED_DATA}/Build/Products/Debug-maccatalyst/Rivulet iOS.app"
  [[ -d "${app}" ]] || { echo "Build the Mac Catalyst app first." >&2; exit 66; }
  local version build_number package_dir archive
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${app}/Contents/Info.plist")"
  build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${app}/Contents/Info.plist")"
  package_dir="${ROOT_DIR}/build/packages"
  mkdir -p "${package_dir}"
  archive="${package_dir}/Rivulet-macOS-${version}-build${build_number}.zip"
  rm -f "${archive}"
  ditto -c -k --sequesterRsrc --keepParent "${app}" "${archive}"
  echo "${archive}"
}

case "${COMMAND}" in
  ios-simulator)
    xcodebuild -project "${PROJECT}" -scheme "Rivulet iOS" \
      -configuration Debug -destination "generic/platform=iOS Simulator" \
      -derivedDataPath "${DERIVED_DATA}" build
    ;;
  ios-device)
    build_ios_device
    ;;
  macos)
    xcodebuild -project "${PROJECT}" -scheme "Rivulet iOS" \
      -configuration Debug -destination "platform=macOS,variant=Mac Catalyst" \
      -derivedDataPath "${DERIVED_DATA}" -allowProvisioningUpdates build
    ;;
  macos-install)
    "$0" macos
    ditto "${DERIVED_DATA}/Build/Products/Debug-maccatalyst/Rivulet iOS.app" "/Applications/Rivulet.app"
    open "/Applications/Rivulet.app"
    ;;
  tvos-simulator)
    xcodebuild -project "${PROJECT}" -scheme Rivulet \
      -configuration Debug -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" \
      -derivedDataPath "${DERIVED_DATA}" build
    ;;
  tvos-device)
    build_tvos_device
    ;;
  package-ios)
    package_ios
    ;;
  package-macos)
    package_macos
    ;;
  test)
    xcodebuild test -project "${PROJECT}" -scheme Rivulet \
      -destination "platform=tvOS Simulator,name=Apple TV 4K (3rd generation)" \
      -derivedDataPath "${DERIVED_DATA}" -only-testing:RivuletTests
    ;;
  help|-h|--help)
    cat <<'USAGE'
Usage: ./Scripts/build-apple.sh COMMAND [DEVICE_IDENTIFIER]

Commands:
  ios-simulator   Build the iPhone/iPad simulator app
  ios-device ID   Build, install, and launch on a connected iPhone/iPad
  macos           Build the Mac Catalyst app
  macos-install   Build, install, and launch the Mac Catalyst app
  tvos-simulator  Build the Apple TV simulator app
  tvos-device ID  Build, install, and launch on a paired Apple TV
  package-ios     Package the last signed iPhone/iPad device build as an IPA
  package-macos   Package the last Mac Catalyst build as a ZIP
  test            Run the complete RivuletTests suite on tvOS Simulator
USAGE
    ;;
  *)
    echo "Unknown command: ${COMMAND}" >&2
    "$0" help
    exit 64
    ;;
esac
