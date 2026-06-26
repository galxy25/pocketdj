#!/usr/bin/env bash
# fetch-switchboard.sh — download + merge the Switchboard DJ-engine modules into
# UNIVERSAL xcframeworks (iOS device + iOS simulator + macOS) under
# apple/Vendor/Switchboard/.
#
# Switchboard's public SPM package ships iOS-only xcframeworks, but Switchboard
# ALSO publishes native macOS xcframeworks at a different S3 path. We merge the
# two so the SAME multiplatform target links Switchboard on iPhone, iPad, AND Mac
# — no `#if os` gating of the engine or the Mix tab.
#
# The merged binaries are reproducible from this script, so Vendor/Switchboard is
# gitignored. Idempotent: re-run any time (each module is wiped + rebuilt).
set -euo pipefail

# NOTE on the player's tempo/pitch/seek limits (verified by an in-app SBDIAG probe across
# 3.2.0–3.2.3, all identical): the `Superpowered.AdvancedAudioPlayer` node exposes ONLY
# open/play/pause through this string-config API. Its C++ `setPlaybackRate`/`setSyncModeTempoAndBeat`
# methods exist but are NOT bridged to setValue/callAction, and no typed `SBAdvancedAudioPlayerNode`
# class is shipped in these builds (the dj-app-ios reference's playbackRate slider is a no-op on its
# own pinned 3.2.2). So tempo / pitch / beat-sync / arbitrary seek are NOT achievable here — they'd
# need a newer (gated) SDK that exposes the typed node API. The Mix tab ships without them.
VERSION="3.2.3"
MODULES=(SwitchboardSDK SwitchboardSuperpowered)
BASE_URL="https://switchboard-sdk-public.s3.amazonaws.com/builds/release/${VERSION}"

# Anchor paths to this script so it runs from anywhere.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"          # .../apple
VENDOR_DIR="${APPLE_DIR}/Vendor/Switchboard"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT

mkdir -p "${VENDOR_DIR}"

for M in "${MODULES[@]}"; do
  echo "==> ${M} ${VERSION}"
  mdir="${WORK_DIR}/${M}"
  mkdir -p "${mdir}/ios" "${mdir}/mac"

  # 1) iOS xcframework (device + simulator slices).
  curl -fsSL "${BASE_URL}/spm/${M}.xcframework.zip" -o "${mdir}/ios.zip"
  unzip -q "${mdir}/ios.zip" -d "${mdir}/ios"
  iosXC="${mdir}/ios/${M}.xcframework"

  # 2) macOS xcframework (universal arm64+x86_64 slice).
  curl -fsSL "${BASE_URL}/macos/${M}.zip" -o "${mdir}/mac.zip"
  unzip -q "${mdir}/mac.zip" -d "${mdir}/mac"
  macFW="${mdir}/mac/Release/${M}.xcframework/macos-arm64_x86_64/${M}.framework"

  # 2a) The macOS zip ships a VERSIONED bundle but OMITS the Versions/Current
  #     symlink AND ships the top-level binary + Headers/Modules/Resources as REAL
  #     files instead of symlinks into Versions/Current. A real top-level Mach-O
  #     binary makes the embedded bundle "ambiguous" (codesign --deep can't tell
  #     app from framework) and -create-xcframework rejects the malformed bundle,
  #     so REPLACE every top-level entry with a symlink into Versions/Current.
  (
    cd "${macFW}"
    # tail -n1 (not head) consumes all input so the pipe can't SIGPIPE under
    # `set -o pipefail`.
    ver="$(/bin/ls Versions | grep -vx Current | tail -n1)"
    ln -sfn "${ver}" Versions/Current
    for i in "${M}" Headers Modules Resources; do
      # Only the binary (M) + the dirs that actually live under the version.
      if [ -e "Versions/Current/${i}" ] && [ ! -L "${i}" ]; then
        rm -rf "${i}"                              # drop the real top-level copy
        ln -sfn "Versions/Current/${i}" "${i}"     # ...and link into Versions/Current
      fi
    done
  )

  # 3) Merge the 3 slices into ONE universal xcframework. Rebuild from scratch so
  #    re-runs don't hit "output path already exists".
  out="${VENDOR_DIR}/${M}.xcframework"
  rm -rf "${out}"
  xcodebuild -create-xcframework \
    -framework "${iosXC}/ios-arm64/${M}.framework" \
    -framework "${iosXC}/ios-arm64_x86_64-simulator/${M}.framework" \
    -framework "${macFW}" \
    -output "${out}"

  # 3a) The SwitchboardSuperpowered umbrella header ships INCOMPLETE: it imports only
  #     SBSuperpoweredExtension.h, yet the Headers dir also ships
  #     AutomaticVocalPitchCorrectionNodeParameters.h + FilterParameters.h. `import
  #     SwitchboardSuperpowered` then warns -Wincomplete-umbrella ("umbrella header does not
  #     include header ..."), which Xcode can treat as a build error. Add the missing imports to
  #     every slice's umbrella (idempotent — find skips the macOS Versions/Current symlinks).
  if [ "${M}" = "SwitchboardSuperpowered" ]; then
    while IFS= read -r h; do
      grep -q 'FilterParameters.h' "${h}" || \
        printf '#import <SwitchboardSuperpowered/AutomaticVocalPitchCorrectionNodeParameters.h>\n#import <SwitchboardSuperpowered/FilterParameters.h>\n' >> "${h}"
    done < <(find "${out}" -path '*/Headers/SwitchboardSuperpowered.h' -type f)
  fi
done

echo "==> Done. Universal xcframeworks in: ${VENDOR_DIR}"
ls -1 "${VENDOR_DIR}"
