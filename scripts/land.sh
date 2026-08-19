#!/bin/sh
# land.sh — one command per change: commit, push, PR, squash-merge, report.
#
# WHY THIS EXISTS. Landing a change used to be three commands handed over
# one at a time, and each hand-off had its own way of going wrong: a branch
# name invented at the prompt that did not match the one checked out, a
# commit message written to a path that did not exist, and commit / push /
# gitflow drifting apart because three commands are three chances to be
# wrong instead of one. This collapses them into a single call whose only
# manual acts are the two that can ONLY be manual — the YubiKey tap on the
# commit, and reading the verification output afterwards.
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

	# A stub gitflow, so the environment check passes and no real PR is ever
	# created by a self-test.
	printf '#!/bin/sh\necho "STUB gitflow: $*"\nexit 0\n' > "$ST_TMP/gitflow.sh"
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
	_o=$(cd "$R" && LAND_SELFTEST_CHILD=1 sh "$SELF" --self-test < /dev/null 2>&1); _c=$?
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
	_st_assert "12 happy path reaches gitflow and reports a SHA" 0 "landed :" "$_c" "$_o"

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
	# The child half of CASE 11. Reaching this line is the assertion.
	if [ "${LAND_SELFTEST_CHILD:-0}" = "1" ]; then
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
trap 'rm -f "$MSGFILE"' EXIT INT TERM
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
echo "landed : $BASE is now $SHA"
git --no-pager log -1 --format='         %h %s' "origin/$BASE"
