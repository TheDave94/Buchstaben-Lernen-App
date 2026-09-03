#!/bin/sh
# typecheck_package.sh — type-check the PrimaeNative package target without
# xcodebuild. POSIX sh: correct under sh, dash, bash and zsh.
#
# USAGE
#   scripts/typecheck_package.sh              check the tree
#   scripts/typecheck_package.sh --self-test  prove the checker can fail
#
# WHY THIS EXISTS. `swiftc -parse` is syntax-only. It accepts a call to a
# MainActor-isolated method from a nonisolated context, and `"a" + "b"`
# where a `Comment?` is expected. Both shipped here behind a clean -parse.
#
# IT MUST FAIL CLOSED. Three separate fail-opens have been found in this
# script and each is guarded below:
#   1. zsh-only syntax (`${VAR:h:h}`) under `sh` -> died at line 36, exit 0.
#      Fixed: POSIX only, `set -eu`, a __COMPILER_RAN__ sentinel.
#   2. `$SOURCES` unquoted splits under sh but NOT zsh, so the whole list
#      arrived as one filename. Fixed: positional parameters.
#   3. Unknown arguments were silently ignored — `--self-test` ran an
#      ordinary check and reported CLEAN. Fixed: unknown args exit 3.
#
# SCOPE LIMIT — READ BEFORE TRUSTING A CLEAN. Checks the PACKAGE target
# only, never PrimaeNativeTests. Covering tests needs `-emit-module`, which
# collapses the macro plugin server where -typecheck survives. Three
# String-vs-Comment? errors passed this check and failed the real build.
# `xcodebuild build-for-testing` is the only thing that checks test code.
#
# EXIT CODES
#   0 CLEAN     every package file checked, zero errors
#   1 DIRTY     real errors, listed
#   2 DEGRADED  macro plugin failed or disk full — UNVERIFIED, not a pass
#   3 SETUP     could not run the check at all (incl. bad arguments)
set -eu

SELF_TEST=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF_TEST=1 ;;
    -h|--help) sed -n '3,6p' "$0"; exit 0 ;;
    *) echo "FATAL: unknown argument '$1'"; exit 3 ;;
  esac
  shift
done

cd "$(dirname "$0")/.." || { echo "FATAL: cannot cd to repo root"; exit 3; }

command -v xcrun >/dev/null 2>&1 || { echo "FATAL: xcrun not found"; exit 3; }
SWIFTC=$(xcrun -f swiftc 2>/dev/null) || { echo "FATAL: swiftc not found"; exit 3; }
TOOLCHAIN=$(dirname "$(dirname "$SWIFTC")")
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path 2>/dev/null) || { echo "FATAL: no SDK"; exit 3; }
[ -d "$SDK" ] || { echo "FATAL: SDK missing: $SDK"; exit 3; }
IOSPLAT="$(dirname "$(dirname "$SDK")")/../iPhoneOS.platform/Developer/usr"

TMP="${TMPDIR:-/tmp}"
SHIM="$TMP/primae-bundle-module-shim.swift"
cat > "$SHIM" <<'SWIFT'
// TYPE-CHECK ONLY. SwiftPM generates this accessor; raw swiftc does not.
import Foundation
extension Bundle { static var module: Bundle { .main } }
SWIFT

compile() {
  cache="$1"; shift
  mkdir -p "$cache"
  set --
  while IFS= read -r f; do [ -n "$f" ] && set -- "$@" "$f"; done <<EOF
$(find PrimaeNative -name '*.swift' | sort)
EOF
  xcrun swiftc -typecheck \
    -sdk "$SDK" -target arm64-apple-ios26.0-simulator \
    -swift-version 6 -default-isolation MainActor \
    -module-name PrimaeNative -module-cache-path "$cache" \
    -external-plugin-path "$TOOLCHAIN/lib/swift/host/plugins#$TOOLCHAIN/bin/swift-plugin-server" \
    -external-plugin-path "$IOSPLAT/lib/swift/host/plugins#$IOSPLAT/bin/swift-plugin-server" \
    "$@" "$SHIM" 2>&1 || true
  echo "__COMPILER_RAN__"
}

# Runs one check and prints a verdict. Returns the exit code, never exits,
# so --self-test can call it twice.
check() {
  OUT=$(compile "$TMP/primae-tc-cache")
  if printf '%s\n' "$OUT" | grep -q 'external macro implementation'; then
    OUT=$(compile "$TMP/primae-tc-cold-$$")   # warm cache can poison the plugin
  fi
  printf '%s\n' "$OUT" | grep -q '__COMPILER_RAN__' || { echo "FATAL: compiler did not run"; return 3; }
  n=$(find PrimaeNative -name '*.swift' | wc -l | tr -d ' ')
  MACRO=$(printf '%s\n' "$OUT" | grep -c 'external macro implementation' || true)
  DISK=$(printf  '%s\n' "$OUT" | grep -c 'No space left on device' || true)
  REAL=$(printf  '%s\n' "$OUT" | grep 'error:' | grep -v 'external macro implementation' | grep -vc '^ ' || true)
  echo "sources      : $n"
  echo "macro-plugin : $MACRO"
  echo "real errors  : $REAL"
  [ "$REAL" -gt 0 ] && printf '%s\n' "$OUT" | grep 'error:' | grep -v 'external macro implementation' | grep -v '^ ' | head -8
  if   [ "$DISK"  -gt 0 ]; then echo "VERDICT: DEGRADED — DISK FULL"; return 2
  elif [ "$MACRO" -gt 0 ]; then echo "VERDICT: DEGRADED — macro plugin failed; @Observable files UNVERIFIED"; return 2
  elif [ "$REAL"  -gt 0 ]; then echo "VERDICT: DIRTY"; return 1
  else echo "VERDICT: CLEAN"; return 0; fi
}

if [ "$SELF_TEST" -eq 1 ]; then
  # The probe answer check_unwired_guards.sh demands, as the FIRST act
  # inside this branch. Placed here rather than beside the argument loop
  # deliberately: a token printed earlier would prove only that the parser
  # set SELF_TEST, not that this block is still reachable from it.
  if [ "${GUARD_SELFTEST_PROBE:-0}" = "1" ]; then
    echo "SELFTEST_REACHABLE"
    exit 0
  fi
  # Induce a KNOWN ActorIsolatedCall in a throwaway file rather than editing
  # a real one: a self-test that mutates tracked source can destroy work if
  # it dies mid-run. The trap guarantees removal on any exit path.
  PROBE=PrimaeNative/__selftest_probe.swift
  trap 'rm -f "$PROBE"' EXIT INT TERM
  cat > "$PROBE" <<'SWIFT'
// Throwaway self-test probe. Induces a known ActorIsolatedCall.
@MainActor func __selfTestIsolatedCallee() -> Int { 0 }
nonisolated func __selfTestNonisolatedCaller() -> Int { __selfTestIsolatedCallee() }
SWIFT
  echo "=== SELF-TEST 1/2: induced ActorIsolatedCall (expect DIRTY, exit 1) ==="
  set +e; check; INDUCED=$?; set -e
  echo ">>> exit=$INDUCED"
  rm -f "$PROBE"; trap - EXIT INT TERM
  echo
  echo "=== SELF-TEST 2/2: probe removed (expect the tree's own verdict) ==="
  set +e; check; RESTORED=$?; set -e
  echo ">>> exit=$RESTORED"
  echo
  echo "=== SELF-TEST RESULT ==="
  echo "  induced : exit $INDUCED (must be 1)"
  echo "  restored: exit $RESTORED"
  if [ "$INDUCED" -eq 1 ]; then
    echo "  HARNESS CAN FAIL: yes — it detected the induced error"
    [ "$RESTORED" -eq 0 ] && echo "  SELF-TEST: PASS" || { echo "  SELF-TEST: INCONCLUSIVE — restored run was not CLEAN"; exit 2; }
  else
    echo "  HARNESS CAN FAIL: NO — it is BLIND. Do not trust any verdict."; exit 3
  fi
  exit 0
fi

set +e; check; rc=$?; set -e
exit $rc
