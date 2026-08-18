#!/bin/sh
# build_study.sh — the ONLY blessed way to produce a Primae study build.
#
# Why a script rather than "select the scheme and press build":
# `STUDY_BUILD` has to arrive as an xcodebuild command-line override.
# A project-level SWIFT_ACTIVE_COMPILATION_CONDITIONS reaches the app
# target but NOT the PrimaeNative SwiftPM package target (measured,
# spike ed055db — app=ON / package=OFF), and the package is where every
# compiled-out view lives.
#
# Pressing ⌘R on the Primae-Study scheme in Xcode therefore does NOT
# produce a study build. It fails at link time instead: the Debug-Study
# configuration links with `-u _primae_build_identity_study`, a symbol
# that exists only when the package itself was compiled with the flag.
# Fail-closed by construction — the trap cannot be walked into. The
# normal configurations name `-u _primae_build_identity_normal` for the
# same reason, so neither binary can be built carrying the other half's
# identity, and `nm` can attest which one it is holding.
#
# Usage:
#   scripts/build_study.sh build  [extra xcodebuild args...]
#   scripts/build_study.sh test   [extra xcodebuild args...]
#
# Env:
#   PRIMAE_CONFIGURATION  Debug-Study (default) or Release-Study
#   PRIMAE_DESTINATION    xcodebuild -destination (default: generic simulator)
#   PRIMAE_DERIVED_DATA   -derivedDataPath       (default: /tmp/DerivedData-Primae-Study)
#   PRIMAE_CODE_SIGNING   NO (default, simulator) or YES (device)
#
# THE PILOT ARTEFACT is Release-Study on a device. Debug-Study is a DEBUG
# build: `#if DEBUG` surfaces are compiled IN, -Onone, ENABLE_TESTABILITY.
# It is for the simulator and for CI, not for a child's iPad. The full
# device procedure — including which toolchain it must be pinned to, and
# why that matters — is in CLAUDE.md under "Study builds".
set -eu

ACTION="${1:-build}"
[ $# -gt 0 ] && shift

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIGURATION="${PRIMAE_CONFIGURATION:-Debug-Study}"
DESTINATION="${PRIMAE_DESTINATION:-generic/platform=iOS Simulator}"
DERIVED="${PRIMAE_DERIVED_DATA:-/tmp/DerivedData-Primae-Study}"
SIGNING="${PRIMAE_CODE_SIGNING:-NO}"

case "$CONFIGURATION" in
    Debug-Study|Release-Study) ;;
    *) echo "FATAL: PRIMAE_CONFIGURATION must be Debug-Study or Release-Study (got '$CONFIGURATION')" >&2
       exit 1 ;;
esac

# Record what was actually built. A study binary whose provenance is a
# shell history entry is not a provenance.
echo "build_study.sh: action=$ACTION configuration=$CONFIGURATION signing=$SIGNING"
echo "build_study.sh: destination=$DESTINATION"
echo "build_study.sh: xcodebuild=$(xcodebuild -version | tr '\n' ' ')"

exec xcodebuild "$ACTION" \
    -project "$ROOT/Primae/Primae.xcodeproj" \
    -scheme Primae-Study \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) STUDY_BUILD' \
    CODE_SIGNING_ALLOWED="$SIGNING" \
    ENABLE_DEBUG_DYLIB=NO \
    "$@"
