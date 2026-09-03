#!/bin/sh
# check_unwired_guards.sh — fail the build on a guard that exists but is
# never dispatched to.
#
# USAGE
#   scripts/check_unwired_guards.sh              scan the tree
#   scripts/check_unwired_guards.sh --self-test  prove the gate can fail
#
# WHY THIS EXISTS. Writing a guard and wiring it are two separate acts, and
# reading the source shows only the first. A guard that is never reached is
# indistinguishable, to a reviewer, from one that works — it sits in the
# diff looking correct and asserts nothing. This repo has shipped several:
# an empty SURFACES list a scan iterated over zero times, a `>= 0` assertion
# on a quantity that cannot be negative, typecheck_package.sh's --self-test
# swallowed by its own argument parser, and land.sh's --self-test in its
# first draft.
#
# IT FAILS THE BUILD. Exit 1 on any finding, never a warning. A gate that
# reports is a gate that gets ignored — the same defect it is looking for.
#
# ---------------------------------------------------------------- design
#
# TWO DECISIONS, BOTH LEARNED THE HARD WAY.
#
# 1. IT EXCLUDES ITSELF from discovery. A detector whose source contains
#    `--self-test` — as a search pattern — finds itself, probes itself, and
#    recurses. Worse, it reports itself as a finding: a false positive that
#    teaches the reader to ignore the gate.
#
#    What proves THIS script's own --self-test is reachable, then? CASE 0
#    re-enters it in a child process and requires the token back, the same
#    shape as land.sh CASE 11; and CI invokes --self-test as its own step,
#    so the branch is dispatched to on every run rather than when someone
#    remembers.
#
# 2. IT INVOKES each --self-test and demands a reachability token, rather
#    than grepping for the dispatch line. A textual check would have PASSED
#    land.sh's broken draft: the `--self-test)` case existed, the dispatch
#    block existed, and the argument guard fired first so neither ever ran.
#    Only running it establishes reachability.
#
#    The token is the contract. A script carrying a --self-test must answer
#    GUARD_SELFTEST_PROBE=1 with SELFTEST_REACHABLE and exit 0 as the FIRST
#    act INSIDE its self-test branch — inside, because a token printed from
#    anywhere else proves the file ran, not that the branch was reached.
#
#    TWO CONSEQUENCES OF INVOKING RATHER THAN GREPPING, both real:
#
#    A non-compliant script gets its self-test RUN IN FULL before it is
#    flagged, because nothing stops it early. That is survivable — it is how
#    the script is flagged at all — but a new --self-test that is slow or
#    that touches the tree will do so here. Answer the probe and it costs
#    nothing: compliant scripts exit on the first line of the branch.
#
#    The gate needs the environment each probed script needs. This is why CI
#    runs it on macos with Xcode selected: typecheck_package.sh checks for
#    xcrun before it dispatches, so on a bare runner it would exit early and
#    be reported unreachable when it is only unhosted.
#
# ---------------------------------------------------------------- checks
#
#   1  a --self-test branch that cannot be reached
#   2  an empty list that a scan iterates over (zero iterations, always ok)
#   3  an assertion that holds in both directions
#
# WAIVERS. A line carrying `unwired-guard-ok: <reason>` is exempted and
# REPORTED, so a waiver stays visible instead of going silent. A waiver with
# no reason after the colon is itself a finding.
#
# EXIT CODES
#   0  clean
#   1  findings — the build must fail
#   3  could not run the scan at all (incl. bad arguments)

set -eu

TOKEN=SELFTEST_REACHABLE
SELF_BASE=check_unwired_guards.sh

F_FILE=$(mktemp "${TMPDIR:-/tmp}/unwired-findings.XXXXXX")
W_FILE=$(mktemp "${TMPDIR:-/tmp}/unwired-waivers.XXXXXX")
trap 'rm -f "$F_FILE" "$W_FILE"' EXIT INT TERM

# Findings are APPENDED TO A FILE, never counted in a shell variable. Every
# check below runs its per-line loop in a pipeline, and a pipeline is a
# subshell: `n=$((n+1))` inside one is discarded when it ends. A count that
# silently stays zero is precisely the defect this script hunts, so it is
# designed out rather than commented around.
finding() { # $1=file:line $2=headline [$3..=detail]
	printf '%s\n' "$1" >> "$F_FILE"
	echo "FAIL  $1"
	echo "      $2"
	shift 2
	for _d in "$@"; do echo "      $_d"; done
}

waiver() { # $1=file:line
	printf '%s\n' "$1" >> "$W_FILE"
	echo "waive $1"
}

# A waiver must carry a reason. `unwired-guard-ok:` with nothing after it is
# a finding, not an exemption — otherwise the waiver becomes the new way to
# write a guard that asserts nothing.
has_reasoned_waiver() { # $1=line text
	case "$1" in
		*unwired-guard-ok:*)
			_r=$(printf '%s' "$1" | sed 's/.*unwired-guard-ok://' | tr -d '[:space:]')
			[ -n "$_r" ] ;;
		*) return 1 ;;
	esac
}

# ------------------------------------------------------- 1  self-test reach
check_selftest_reachability() { # $1=root
	echo "--- CHECK 1  --self-test reachability"
	_found=0
	for _s in $(find "$1" -name '*.sh' -type f 2>/dev/null | sort); do
		[ "$(basename "$_s")" = "$SELF_BASE" ] && continue   # design note 1
		grep -q -- '--self-test' "$_s" || continue
		_found=$((_found + 1))

		set +e
		_out=$(GUARD_SELFTEST_PROBE=1 sh "$_s" --self-test 2>&1); _code=$?
		set -e

		case "$_out" in
			*"$TOKEN"*)
				if [ "$_code" -eq 0 ]; then
					echo "ok    $_s — branch reached, token returned"
				else
					finding "$_s" "--self-test returned the token but exited $_code (want 0)"
				fi ;;
			*)
				finding "$_s" \
					"--self-test carries a branch that was NEVER REACHED." \
					"Probed with GUARD_SELFTEST_PROBE=1; no $TOKEN came back (exit $_code)." \
					"Either an earlier guard fires first — the land.sh draft failure —" \
					"or the branch does not answer the probe. As the FIRST act inside" \
					"the self-test branch, add:" \
					"  [ \"\${GUARD_SELFTEST_PROBE:-0}\" = 1 ] && { echo $TOKEN; exit 0; }" \
					"probe said: $(printf '%s' "$_out" | head -3 | tr '\n' ' ')" ;;
		esac
	done
	[ "$_found" -eq 0 ] && echo "      (no scripts carry a --self-test)"
	return 0
}

# ------------------------------------------------------- 2  empty scan list
#
# `for sym in $SURFACES` with SURFACES="" runs its body zero times and
# reports success. The loop is present, the assertions inside it are
# present, and nothing is ever checked.
check_empty_scan_lists() { # $1=root
	echo "--- CHECK 2  lists a scan iterates over"
	find "$1" \( -name '*.sh' -o -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null \
		| sort | while IFS= read -r _f; do
		[ "$(basename "$_f")" = "$SELF_BASE" ] && continue
		grep -n 'for  *[A-Za-z_][A-Za-z0-9_]*  *in  *\$' "$_f" 2>/dev/null | while IFS= read -r _hit; do
			_ln=${_hit%%:*}
			_txt=${_hit#*:}
			if has_reasoned_waiver "$_txt"; then waiver "$_f:$_ln"; continue; fi
			_var=$(printf '%s' "$_txt" | sed -n 's/.*in  *\${\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p')
			[ -n "$_var" ] || continue

			_asg=$(grep -n "^[[:space:]]*$_var=" "$_f" 2>/dev/null || true)
			[ -n "$_asg" ] || continue    # never assigned here — may arrive from env

			# Non-empty if ANY assignment in the file carries a value.
			_val=$(printf '%s\n' "$_asg" \
				| sed 's/^[0-9]*:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=//' \
				| sed 's/^"//; s/"$//; s/^'\''//; s/'\''$//' \
				| tr -d '[:space:]')
			if [ -z "$_val" ]; then
				finding "$_f:$_ln" \
					"\$$_var is EMPTY and this loop iterates over it — zero iterations," \
					"so every assertion in the body is vacuous." \
					"assigned at: $(printf '%s' "$_asg" | tr '\n' ' ')"
			fi
		done
	done
	return 0
}

# --------------------------------------------------- 3  both-directions test
#
# `#expect(distance >= 0)` on a quantity that is non-negative by
# construction passes whether the code is right or wrong. It reads as a
# bound and asserts nothing.
#
# Narrow on purpose: only comparisons against zero, and only when no upper
# bound appears on the same line or the next. `#expect(x >= 0 && x <= 1)` is
# a real interval and is left alone.
check_tautological_assertions() { # $1=root
	echo "--- CHECK 3  assertions that hold in both directions"
	find "$1" -name '*.swift' -type f 2>/dev/null | sort | while IFS= read -r _f; do
		grep -n '#expect(' "$_f" 2>/dev/null \
			| grep '>=[[:space:]]*0\(\.0*\)\{0,1\}[[:space:]]*[,)]' \
			| grep -v '<' \
			| while IFS= read -r _hit; do
				_ln=${_hit%%:*}
				_txt=${_hit#*:}
				if has_reasoned_waiver "$_txt"; then waiver "$_f:$_ln"; continue; fi
				# A companion upper bound on EITHER adjacent line makes this
				# an interval assertion, not a tautology. Looking only
				# forward was the detector's own first bug: it flagged two
				# `>= 0.0` lines whose `< 1.0` sat on the line ABOVE.
				_next=$(sed -n "$((_ln + 1))p" "$_f" 2>/dev/null || true)
				_prev=""
				[ "$_ln" -gt 1 ] && _prev=$(sed -n "$((_ln - 1))p" "$_f" 2>/dev/null || true)
				case "$_next" in *'<'*) continue ;; esac
				case "$_prev" in *'<'*) continue ;; esac
				finding "$_f:$_ln" \
					"asserts >= 0 on a quantity that cannot be negative — it holds" \
					"whether the code is right or wrong." \
					"$(printf '%s' "$_txt" | sed 's/^[[:space:]]*//')" \
					"Assert the property that can fail, or waive on the line with" \
					"// unwired-guard-ok: <why this bound is real>"
			done
	done
	return 0
}

scan() { # $1=root
	check_selftest_reachability "$1"
	check_empty_scan_lists "$1"
	check_tautological_assertions "$1"
}

report() { # -> 0 clean, 1 findings
	_n=$(wc -l < "$F_FILE" | tr -d ' ')
	_w=$(wc -l < "$W_FILE" | tr -d ' ')
	echo ""
	echo "waivers  : $_w"
	echo "findings : $_n"
	if [ "$_n" -eq 0 ]; then
		echo "UNWIRED-GUARD SCAN: CLEAN"
		return 0
	fi
	echo "UNWIRED-GUARD SCAN: FAILED — $_n guard(s) assert nothing"
	return 1
}

# ---------------------------------------------------------------- self-test
#
# Every check below is driven to RED against a fixture that carries the
# defect, and to GREEN against one that does not. A detector proven only on
# clean input is a detector that has never been shown to fail — which is the
# condition it exists to report.
#
# CASE 0 is the one that keeps this honest: it re-enters --self-test in a
# child and requires the token back. If the dispatch is ever moved below the
# argument catch-all, the child answers with the unknown-argument FATAL and
# CASE 0 fails — the exact bug typecheck_package.sh and land.sh each shipped.

ST_TOTAL=0
ST_FAIL=0

st_assert() { # $1=label $2=want $3=got
	ST_TOTAL=$((ST_TOTAL + 1))
	if [ "$2" = "$3" ]; then
		echo "  pass  $1"
	else
		echo "  FAIL  $1 — wanted $2, got $3"
		ST_FAIL=$((ST_FAIL + 1))
	fi
}

# Run one check against one root and return the number of findings it filed.
st_count() { # $1=check-fn $2=root
	: > "$F_FILE"
	: > "$W_FILE"
	"$1" "$2" > "$ST_LOG" 2>&1 || true
	wc -l < "$F_FILE" | tr -d ' '
}

st_waivers() { wc -l < "$W_FILE" | tr -d ' '; }

self_test() {
	SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	# The sandbox is deliberately NOT deleted: after a failure the fixture
	# that produced it is the first thing you want to read. Its path is
	# printed at the end.
	ST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/unwired-selftest.XXXXXX")
	ST_LOG="$ST_DIR/check.log"

	DIRTY="$ST_DIR/dirty"
	CLEAN="$ST_DIR/clean"
	mkdir -p "$DIRTY" "$CLEAN"

	echo "check_unwired_guards.sh --self-test"
	echo ""

	# ---- CASE 0: this branch is itself reachable.
	set +e
	_o=$(GUARD_SELFTEST_PROBE=1 sh "$SELF" --self-test 2>&1); _c=$?
	set -e
	case "$_o" in
		*"$TOKEN"*) st_assert "0  --self-test is itself reachable" "0" "$_c" ;;
		*) st_assert "0  --self-test is itself reachable" "token" "no-token(exit $_c)" ;;
	esac

	# ---- Fixtures carrying the defect.

	# An unwired --self-test: the branch exists, the dispatch exists, and the
	# argument catch-all fires first. This is land.sh's broken draft.
	cat > "$DIRTY/unwired.sh" <<'FIX'
#!/bin/sh
set -eu
while [ $# -gt 0 ]; do
	case "$1" in
		*) echo "FATAL: takes no arguments"; exit 2 ;;
		--self-test) SELF_TEST=1 ;;
	esac
	shift
done
if [ "${SELF_TEST:-0}" = "1" ]; then
	[ "${GUARD_SELFTEST_PROBE:-0}" = 1 ] && { echo SELFTEST_REACHABLE; exit 0; }
	echo "self-test ran"
fi
FIX

	# A --self-test that IS reached and answers the probe.
	cat > "$CLEAN/wired.sh" <<'FIX'
#!/bin/sh
set -eu
SELF_TEST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--self-test) SELF_TEST=1 ;;
		*) echo "FATAL: unknown argument"; exit 3 ;;
	esac
	shift
done
if [ "$SELF_TEST" -eq 1 ]; then
	[ "${GUARD_SELFTEST_PROBE:-0}" = 1 ] && { echo SELFTEST_REACHABLE; exit 0; }
	echo "self-test ran"
fi
FIX

	# An empty list a scan iterates over, and a populated one.
	cat > "$DIRTY/scan.yml" <<'FIX'
          SURFACES=""
          for sym in $SURFACES; do
            echo "checking $sym"
          done
FIX
	cat > "$CLEAN/scan.yml" <<'FIX'
          SURFACES="debugPercentReadout"
          for sym in $SURFACES; do
            echo "checking $sym"
          done
FIX

	# An assertion that holds in both directions, and a real interval.
	cat > "$DIRTY/Tests.swift" <<'FIX'
@Test func distanceIsSane() {
    #expect(frechet >= 0, "frechetDistance is a distance")
}
FIX
	cat > "$CLEAN/Tests.swift" <<'FIX'
@Test func accuracyIsAnInterval() {
    #expect(result.formAccuracy >= 0 && result.formAccuracy <= 1)
}
@Test func boundedOnTheNextLine() {
    #expect(cp.x >= 0.0)
    #expect(cp.x <= 1.0)
}
@Test func boundedOnThePreviousLine() {
    #expect(assessment.tempoConsistency < 1.0)
    #expect(assessment.tempoConsistency >= 0.0)
}
FIX

	chmod +x "$DIRTY/unwired.sh" "$CLEAN/wired.sh"

	# ---- CASE 1-2: check 1 red on the unwired branch, green on the wired one.
	st_assert "1  catches an unreachable --self-test" "1" "$(st_count check_selftest_reachability "$DIRTY")"
	st_assert "2  passes a reachable --self-test"     "0" "$(st_count check_selftest_reachability "$CLEAN")"

	# ---- CASE 3-4: check 2 red on the empty list, green on the populated one.
	st_assert "3  catches an empty scan list"         "1" "$(st_count check_empty_scan_lists "$DIRTY")"
	st_assert "4  passes a populated scan list"       "0" "$(st_count check_empty_scan_lists "$CLEAN")"

	# ---- CASE 5-6: check 3 red on the tautology, green on real bounds.
	st_assert "5  catches a both-directions assertion" "1" "$(st_count check_tautological_assertions "$DIRTY")"
	st_assert "6  passes a real interval"              "0" "$(st_count check_tautological_assertions "$CLEAN")"

	# ---- CASE 7: a reasoned waiver exempts; a bare one does NOT.
	W="$ST_DIR/waiver"
	mkdir -p "$W"
	cat > "$W/Tests.swift" <<'FIX'
@Test func waivedProperly() {
    #expect(frechet >= 0) // unwired-guard-ok: asserting the type is unsigned
}
FIX
	_n=$(st_count check_tautological_assertions "$W")
	st_assert "7a a reasoned waiver exempts the line" "0" "$_n"
	st_assert "7b the waiver is reported, not silent" "1" "$(st_waivers)"

	cat > "$W/Tests.swift" <<'FIX'
@Test func waivedWithNoReason() {
    #expect(frechet >= 0) // unwired-guard-ok:
}
FIX
	st_assert "7c a waiver with no reason still fails" "1" "$(st_count check_tautological_assertions "$W")"

	# ---- CASE 8: the whole scan is green on a clean tree. A self-test made
	# only of red drives would pass on a detector that flags everything.
	: > "$F_FILE"
	: > "$W_FILE"
	scan "$CLEAN" > "$ST_LOG" 2>&1 || true
	st_assert "8  a clean tree scans clean" "0" "$(wc -l < "$F_FILE" | tr -d ' ')"

	echo ""
	echo "  sandbox: $ST_DIR"
	if [ "$ST_FAIL" -eq 0 ]; then
		echo "SELF-TEST: PASS — $ST_TOTAL/$ST_TOTAL"
		return 0
	fi
	echo "SELF-TEST: FAIL — $ST_FAIL of $ST_TOTAL"
	return 1
}

# ---------------------------------------------------------------- arguments
#
# The dispatch sits ABOVE the catch-all, and CASE 0 proves it stays there.
SELF_TEST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--self-test) SELF_TEST=1 ;;
		-h|--help) sed -n '3,7p' "$0"; exit 0 ;;
		*) echo "FATAL: unknown argument '$1'" >&2; exit 3 ;;
	esac
	shift
done

if [ "$SELF_TEST" -eq 1 ]; then
	# The probe answer, as the FIRST act inside the branch. Reaching this
	# line is the assertion CASE 0 makes.
	if [ "${GUARD_SELFTEST_PROBE:-0}" = "1" ]; then
		echo "$TOKEN"
		exit 0
	fi
	set +e; self_test; rc=$?; set -e
	exit $rc
fi

cd "$(dirname "$0")/.." || { echo "FATAL: cannot cd to repo root" >&2; exit 3; }
scan .
set +e; report; rc=$?; set -e
exit $rc
