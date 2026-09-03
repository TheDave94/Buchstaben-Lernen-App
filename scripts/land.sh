#!/bin/sh
# land.sh — one command per change: commit, push, PR, squash-merge, report.
#
# WHY THIS EXISTS. Landing a change used to be three commands handed over
# one at a time, and each hand-off had its own way of going wrong: a branch
# name invented at the prompt that did not match the one checked out, a
# commit message written to a path that did not exist, and commit / push /
# gitflow drifting apart because three commands are three chances to be
# wrong instead of one. This collapses them into a single call.
#
# WHO RUNS THIS, AND WHY THE STEPS AREN'T PAUSED BETWEEN. Directly, by
# whichever seat prepared the change — a Claude Code session included.
# Earlier drafts of this comment claimed "reading the verification output
# afterwards" could ONLY be done by a human at a terminal; that was never
# re-tested before being written, and a session invoking this script does
# read its own stdout/stderr and act on the printed verdict, the same way
# a person would (measured 2026-09-03, six commits signed and pushed this
# way in one session — b2d5397 through a4f4c9b).
#
# What that measurement does NOT establish: that the physical half is
# reliable regardless of who invokes this. The same evening, the seventh
# attempt failed differently — yubi-sign's notification channel to David
# threw an AppleScript error trying to raise the cue, and the signing step
# then reported the public key as unreadable and never wrote the commit.
# Six successes and one clean failure (land.sh's own discipline: nothing
# was committed, nothing pushed) is not evidence the notification path is
# solid; it is evidence the boundary is narrower than "always works" and
# narrower than "always needs a human's terminal" both. Treat a stall or
# an unreadable-key failure as something to look at, not something to
# route around by reverting to a handover — and not something to paper
# over as certainly transient either.
#
# The absence of a pause between steps (commit -> push -> gitflow --go,
# no "are you sure") is a separate, older, and still-independent choice:
# it assumes whoever staged the diff already reviewed it before writing
# the commit message, so a second confirmation prompt would just be a
# step the invoker learns to click through. That holds for a session that
# reviewed its own diff exactly as much as it holds for a person who
# reviewed theirs — it was never about which one is typing.
#
# USAGE
#   sh scripts/land.sh <<'MSG'
#   type(scope): subject line, which becomes the PR title
#
#   Body. This becomes the PR body: gitflow carries HEAD's commit body into
#   the PR, so anything below the subject travels with the merge.
#   MSG
#
# The message arrives on STDIN and nowhere else. There is no --file flag and
# no default path, so "the commit message file does not exist" is not a
# failure this script is capable of having.
#
# WHAT IT DELIBERATELY DOES NOT DO. It does not run the tests. Verification
# is the other thing that stays yours — a script that both lands a change and
# grades it is a script that can report a green it never earned.
#
# FAILURE DISCIPLINE. Every step is checked explicitly and stops the run at
# the first error. No `&&` chains, which fall through to the next command
# when an earlier one fails, and no pipes on any step whose exit status
# matters — in `a | b` the status is b's, so a piped `git commit` reports the
# health of `tee`, not of the commit.
#
# EXIT CODES
#   2  precondition refused (on main, empty message, nothing to commit, …)
#   3  environment missing (not a git checkout, gitflow.sh absent)
#   1  a step failed (commit, push, gitflow, fetch)

set -eu

GITFLOW="${GITFLOW:-$HOME/repos/homelab-ops/bin/gitflow.sh}"

# die CODE "first line" ["further lines" …]
die() {
	code=$1
	shift
	echo "FATAL: $1" >&2
	shift
	for line in "$@"; do
		echo "  $line" >&2
	done
	exit "$code"
}

usage() {
	sed -n '/^# USAGE/,/^# The message arrives/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

# ---------------------------------------------------------------- verified
#
# WHY THIS EXISTS, PRECISELY. Two SHAs were reported merged in one session
# on the strength of narrative rather than output — against a main that had
# not moved and PRs that did not exist. `landed : main is now $SHA` printed
# a SHA it had never checked resolves, so the line read identically whether
# the merge happened or not. That incident was a session asserting success
# without checking, full stop — nothing about who signed the commit or
# whether a human ran the script. This check would be exactly as necessary
# in a world where every commit here was always signed by a Claude Code
# session directly, because the failure it guards against is a REPORT
# drifting from REALITY, not a boundary about who is allowed to type
# `git commit`. Keep it on that basis.
#
# Four assertions, each answering a different way the claim can be false:
# the object exists, origin/BASE contains it, BASE actually MOVED, and the
# subject is this change rather than someone else's.
#
# verify_landed SHA BASE BEFORE TITLE -> 0 verified, 1 not
verify_landed() {
	_sha=$1; _base=$2; _before=$3; _title=$4

	if ! git cat-file -e "${_sha}^{commit}" 2>/dev/null; then
		echo "NOT LANDED: $_sha is not a commit object in this repository" >&2
		return 1
	fi
	if ! git merge-base --is-ancestor "$_sha" "refs/remotes/origin/$_base" 2>/dev/null; then
		echo "NOT LANDED: origin/$_base does not contain $_sha" >&2
		return 1
	fi
	if [ -n "$_before" ] && [ "$_sha" = "$_before" ]; then
		echo "NOT LANDED: origin/$_base has not moved — still $_before" >&2
		return 1
	fi
	_subj=$(git --no-pager log -1 --format='%s' "$_sha" 2>/dev/null || true)
	case "$_subj" in
		*"$_title"*) : ;;
		*)
			echo "NOT LANDED: origin/$_base moved to $_sha, but its subject is not this change" >&2
			echo "  wanted to contain: $_title" >&2
			echo "  actual subject   : $_subj" >&2
			return 1 ;;
	esac

	echo "VERIFIED: $_base is now $_sha"
	git --no-pager log -1 --format='          %h %s' "$_sha"
	return 0
}

# The verdict runs on EVERY exit path, not only the successful one. The case
# that most needs a verdict is the one where the land did NOT happen and
# something might still believe it did — so silence on failure is the bug.
LANDED=0
MSGFILE=""
cleanup() {
	[ -n "$MSGFILE" ] && rm -f "$MSGFILE"
	if [ "$LANDED" != "1" ]; then
		echo "" >&2
		echo "NOT LANDED: nothing was merged. origin/${BASE:-main} is $(git rev-parse --short "refs/remotes/origin/${BASE:-main}" 2>/dev/null || echo "unknown")" >&2
	fi
	return 0
}

# ---------------------------------------------------------------- self-test
#
# WHY THIS EXISTS. Every refusal below was driven by hand once, from outside
# the script, and that proof expired the moment the file was next edited. A
# guard that is written but never dispatched to is indistinguishable, to a
# reviewer reading the source, from a guard that works: writing the branch
# and writing the dispatch are two acts and only one of them is visible.
# This repo has now shipped three of those (an empty SURFACES, a `>= 0`
# assertion that held in both directions, and typecheck_package.sh's own
# --self-test silently swallowed by an argument parser).
#
# So the drives live in the script, and CASE 11 is the one that would have
# caught all three: it proves --self-test is REACHABLE, by re-entering this
# branch in a child process and requiring the token back. If --self-test is
# ever moved below the catch-all, the child answers with the unknown-argument
# FATAL instead and this fails.

ST_TOTAL=0
ST_FAIL=0

_st_assert() {
	_label=$1; _want_code=$2; _want_text=$3; _got_code=$4; _got_out=$5
	ST_TOTAL=$((ST_TOTAL + 1))
	if [ "$_got_code" != "$_want_code" ]; then
		echo "  FAIL  $_label — exit $_got_code, expected $_want_code"
		printf '%s\n' "$_got_out" | sed 's/^/          /'
		ST_FAIL=$((ST_FAIL + 1))
		return 0
	fi
	case "$_got_out" in
		*"$_want_text"*)
			echo "  pass  $_label — exit $_got_code" ;;
		*)
			echo "  FAIL  $_label — exit $_got_code (correct) but message lacked: $_want_text"
			printf '%s\n' "$_got_out" | sed 's/^/          /'
			ST_FAIL=$((ST_FAIL + 1)) ;;
	esac
}

self_test() {
	SELF=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	ST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/land-selftest.XXXXXX")
	trap 'rm -rf "$ST_TMP"' EXIT INT TERM

	# A stub gitflow that REALLY squash-merges into the local origin, so the
	# happy path exercises verify_landed instead of bypassing it. An echo-only
	# stub would now fail CASE 12 — correctly, since origin/main would not move.
	# No real PR is ever created: origin here is a bare repo in the sandbox.
	cat > "$ST_TMP/gitflow.sh" <<'STUB'
#!/bin/sh
set -eu
_title=$2
_br=$(git rev-parse --abbrev-ref HEAD)
git checkout -q main
git merge -q --squash "$_br"
git commit -qm "$_title (#1)"
git push -q origin main
git checkout -q "$_br"
echo "STUB gitflow: squash-merged $_br into main"
STUB
	chmod +x "$ST_TMP/gitflow.sh"
	GITFLOW="$ST_TMP/gitflow.sh"
	export GITFLOW

	R="$ST_TMP/repo"
	mkdir -p "$R"
	cd "$R"
	git init -q -b main
	git config user.email selftest@example.invalid
	git config user.name "land.sh self-test"
	git config commit.gpgsign false
	printf 'seed\n' > seed.txt
	git add -A
	git commit -qm "seed: initial"

	printf 'feat: a valid subject\n\nbody\n' > "$ST_TMP/msg_ok"
	: > "$ST_TMP/msg_empty"
	printf '   \n\t\n'                       > "$ST_TMP/msg_blank"
	printf '\nbody with no subject\n'        > "$ST_TMP/msg_nosubject"
	printf -- '--title sneaky\n\nbody\n'     > "$ST_TMP/msg_dash"

	echo "land.sh --self-test"
	echo ""

	# 1 — on the default branch
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_ok" 2>&1); _c=$?
	set -e
	_st_assert "1  refuses on the default branch" 2 "on the default branch" "$_c" "$_o"

	git checkout -q -b feat/selftest

	# 2 — detached HEAD
	set +e
	_o=$(cd "$R" && git checkout -q --detach HEAD && sh "$SELF" < "$ST_TMP/msg_ok" 2>&1); _c=$?
	set -e
	_st_assert "2  refuses on detached HEAD" 2 "detached HEAD" "$_c" "$_o"
	git checkout -q feat/selftest

	# 3 — a merge is in progress
	git checkout -q main
	printf 'base\n' > conflict.txt; git add -A; git commit -qm "c: base"
	git checkout -q -b selftest-other
	printf 'theirs\n' > conflict.txt; git add -A; git commit -qm "c: theirs"
	git checkout -q main
	printf 'ours\n' > conflict.txt; git add -A; git commit -qm "c: ours"
	git checkout -q -b feat/selftest-merge
	git merge selftest-other >/dev/null 2>&1 || true
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_ok" 2>&1); _c=$?
	set -e
	_st_assert "3  refuses mid-merge" 2 "a git operation is in progress" "$_c" "$_o"
	git merge --abort >/dev/null 2>&1 || true
	git checkout -q feat/selftest

	# 4 — an argument instead of a heredoc
	set +e
	_o=$(cd "$R" && sh "$SELF" --bogus < /dev/null 2>&1); _c=$?
	set -e
	_st_assert "4  refuses an argument" 2 "takes no arguments" "$_c" "$_o"

	# 5 — empty message
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_empty" 2>&1); _c=$?
	set -e
	_st_assert "5  refuses an empty message" 2 "empty commit message" "$_c" "$_o"

	# 6 — whitespace-only message
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_blank" 2>&1); _c=$?
	set -e
	_st_assert "6  refuses a whitespace-only message" 2 "empty commit message" "$_c" "$_o"

	# 7 — blank subject line
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_nosubject" 2>&1); _c=$?
	set -e
	_st_assert "7  refuses a blank subject line" 2 "first line is blank" "$_c" "$_o"

	# 8 — title gitflow would refuse positionally
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_dash" 2>&1); _c=$?
	set -e
	_st_assert "8  refuses a title beginning with '-'" 2 "begins with '-'" "$_c" "$_o"

	# 9 — nothing staged
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_ok" 2>&1); _c=$?
	set -e
	_st_assert "9  refuses when nothing is staged" 2 "nothing to commit" "$_c" "$_o"

	# 10 — tree dirty AFTER the commit. Induced with a post-commit hook that
	# touches a tracked file: `git add -A` sweeps everything, so without an
	# inducer this branch cannot be reached and would be exactly the kind of
	# guard this self-test exists to distrust.
	printf '#!/bin/sh\nprintf "residue\\n" >> seed.txt\n' > "$R/.git/hooks/post-commit"
	chmod +x "$R/.git/hooks/post-commit"
	printf 'work\n' > work.txt
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_ok" 2>&1); _c=$?
	set -e
	_st_assert "10 refuses a dirty tree after the commit" 2 "not clean after the commit" "$_c" "$_o"
	rm -f "$R/.git/hooks/post-commit"
	git checkout -q -- seed.txt

	# 11 — THE ONE THAT WOULD HAVE CAUGHT THE OTHER THREE.
	# Re-enter --self-test in a child. Reaching the branch is what prints the
	# token, so the token coming back IS the proof of dispatch.
	set +e
	_o=$(cd "$R" && GUARD_SELFTEST_PROBE=1 sh "$SELF" --self-test < /dev/null 2>&1); _c=$?
	set -e
	_st_assert "11 --self-test is itself reachable" 0 "SELFTEST_REACHABLE" "$_c" "$_o"

	# 12 — the happy path still works. A self-test made only of refusals
	# would pass on a script that refuses everything.
	git init -q --bare "$ST_TMP/origin.git"
	git remote add origin "$ST_TMP/origin.git"
	git push -q origin main
	printf 'landed\n' > landed.txt
	set +e
	_o=$(cd "$R" && sh "$SELF" < "$ST_TMP/msg_ok" 2>&1); _c=$?
	set -e
	_st_assert "12 happy path merges and VERIFIES the SHA" 0 "VERIFIED:" "$_c" "$_o"

	# 13 — a fabricated SHA. This is the exact failure this check exists for:
	# a SHA that reads plausibly and has no object behind it.
	set +e
	_o=$(verify_landed 0123456789abcdef0123456789abcdef01234567 main "" "any" 2>&1); _c=$?
	set -e
	_st_assert "13 refuses a fabricated SHA" 1 "is not a commit object" "$_c" "$_o"

	# 14 — a REAL commit that origin/main does not contain. Object existence
	# alone would pass this one, which is why containment is asserted too.
	_absent=$(git rev-parse selftest-other)
	set +e
	_o=$(verify_landed "$_absent" main "" "any" 2>&1); _c=$?
	set -e
	_st_assert "14 refuses a real SHA absent from origin/main" 1 "does not contain" "$_c" "$_o"

	echo ""
	if [ "$ST_FAIL" -eq 0 ]; then
		echo "SELF-TEST: PASS — $ST_TOTAL/$ST_TOTAL"
		return 0
	fi
	echo "SELF-TEST: FAIL — $ST_FAIL of $ST_TOTAL"
	return 1
}

# ---------------------------------------------------------------- arguments
SELF_TEST=0
while [ $# -gt 0 ]; do
	case "$1" in
		--self-test) SELF_TEST=1 ;;
		-h|--help) usage; exit 0 ;;
		*) usage; die 2 "land.sh takes no arguments — the message arrives on stdin" "got: $1" ;;
	esac
	shift
done

if [ "$SELF_TEST" -eq 1 ]; then
	# The child half of CASE 11, and the probe answer that
	# check_unwired_guards.sh demands. Reaching this line is the assertion.
	if [ "${GUARD_SELFTEST_PROBE:-0}" = "1" ]; then
		echo "SELFTEST_REACHABLE"
		exit 0
	fi
	self_test
	exit $?
fi

# ---------------------------------------------------------------- repo
if ! ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
	die 3 "not inside a git checkout"
fi
cd "$ROOT" || die 3 "cannot cd to repo root: $ROOT"

[ -f "$GITFLOW" ] || die 3 "gitflow.sh not found at $GITFLOW" \
	"set GITFLOW=/path/to/gitflow.sh to override"

# The default branch, read from the remote rather than assumed, so this
# refuses on `master` too if that is ever what origin points at.
BASE=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
BASE="${BASE#origin/}"
[ -n "$BASE" ] || BASE="main"

BR=$(git rev-parse --abbrev-ref HEAD)

# From here on every exit path reports a verdict.
trap cleanup EXIT INT TERM

# What origin/BASE was BEFORE this run. The "did it move" assertion is
# meaningless without it, and it has to be read before anything is pushed.
BASE_BEFORE=$(git rev-parse --verify --quiet "refs/remotes/origin/$BASE" 2>/dev/null || true)

[ "$BR" != "HEAD" ] || die 2 "detached HEAD — check out a branch first"
[ "$BR" != "$BASE" ] || die 2 "on the default branch '$BASE' — branch first" \
	"git checkout -b type/short-description"
[ "$BR" != "main" ] || die 2 "on 'main' — branch first"

# An interrupted merge / rebase / cherry-pick means `git add -A` would sweep
# conflict residue and unrelated work into this commit.
for state in MERGE_HEAD REBASE_HEAD CHERRY_PICK_HEAD BISECT_LOG; do
	if [ -e "$(git rev-parse --git-path "$state")" ]; then
		die 2 "a git operation is in progress ($state) — finish or abort it first"
	fi
done

# ---------------------------------------------------------------- message
if [ -t 0 ]; then
	usage
	die 2 "no message on stdin — land.sh reads the commit message from a heredoc"
fi

MSGFILE=$(mktemp "${TMPDIR:-/tmp}/land-msg.XXXXXX")
cat > "$MSGFILE"

if [ -z "$(tr -d '[:space:]' < "$MSGFILE")" ]; then
	die 2 "empty commit message on stdin — nothing to title the PR with"
fi

TITLE=$(head -n 1 "$MSGFILE")

[ -n "$TITLE" ] || die 2 "the message's first line is blank — it is the PR title" \
	"put the subject on line 1, the body below a blank line"

# gitflow's title is POSITIONAL and it refuses a leading '-'. Catch it here so
# the refusal arrives before the commit rather than after it.
case "$TITLE" in
	-*) die 2 "title begins with '-', which gitflow refuses (the title is positional)" \
	          "got: $TITLE" ;;
esac

# ---------------------------------------------------------------- commit
echo "branch : $BR  ->  $BASE"
echo "title  : $TITLE"

if ! git add -A; then
	die 1 "git add -A failed"
fi

# `--quiet` exits 0 when there is NO staged difference, so success here means
# there is nothing to land.
if git diff --cached --quiet; then
	die 2 "nothing to commit — the tree carries no change against HEAD"
fi

echo "commit : tap the key when it asks"
if ! git commit -F "$MSGFILE"; then
	die 1 "commit failed (signature not taken?) — nothing pushed"
fi

# gitflow squash-merges, which RESETS this branch: anything still in the
# working tree at that point is destroyed (gitflow.sh records 8 edits lost
# this way on 2026-08-01). Prove the tree is clean before going near it.
RESIDUE=$(git status --porcelain)
if [ -n "$RESIDUE" ]; then
	echo "$RESIDUE" >&2
	die 2 "working tree is not clean after the commit — a squash-merge would destroy the above" \
	      "commit or stash it, then re-run"
fi

# ---------------------------------------------------------------- push
# `HEAD` rather than "$BR": the branch name is never typed, so it cannot be
# typed wrong. This push is not strictly needed — gitflow pushes too — but it
# fails here, before any PR exists, if the remote is going to reject it.
echo "push   : origin HEAD"
if ! git push -u origin HEAD; then
	die 1 "push failed — no PR was created"
fi

# ---------------------------------------------------------------- land
echo "gitflow: pr \"$TITLE\" --go"
if ! sh "$GITFLOW" pr "$TITLE" --go; then
	die 1 "gitflow failed — the branch is pushed but NOT merged; inspect before retrying"
fi

# ---------------------------------------------------------------- report
if ! git fetch origin; then
	die 1 "merged, but the post-merge fetch failed — cannot report the $BASE SHA"
fi

SHA=$(git rev-parse "origin/$BASE")
echo ""
if ! verify_landed "$SHA" "$BASE" "$BASE_BEFORE" "$TITLE"; then
	die 1 "gitflow reported success but the merge is NOT on origin/$BASE" \
	      "do not trust the SHA above; inspect before retrying"
fi
LANDED=1
