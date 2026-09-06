# Preserved local state — Primae, 2026-09-06 (unattended pass)

MEASURED on this machine (`git -C /Users/musicbox/repos/Primae …`):

- `stash list` → one entry: `stash@{0}: On chore/handoff-hooks: held-out for sign-off: DECISIONS.md/STROKE_AUDIT.md`
- `log -1 'stash@{0}^'` → base `aa6590b feat(tooling): adopt the session-handoff Stop/PreCompact/SessionStart hooks`
- `stash show --stat` → `docs/DECISIONS.md | 20 ++++++++++++++++----`, `docs/STROKE_AUDIT.md | 12 +++++++++---`, 25 insertions, 7 deletions
- `stash show -p --include-untracked` is byte-identical to `stash show -p` → no untracked files in the stash
- `status --short | wc -l` → 0 (the checkout is clean); `main` = `origin/main` = `a6f59ae`

Contents of this directory:

- `primae-stash0-on-chore-handoff-hooks.patch` — the stash, verbatim (`git stash show -p stash@{0}`).

`git apply --3way --check` of that patch against `origin/main` (`a6f59ae`) applies
cleanly to both files. It is NOT applied here on purpose: the stash's own message says
the text was held out for David's sign-off, and a preservation commit must not decide
that. Applying it is one command, his: `git apply preserve/2026-09-06/primae-stash0-on-chore-handoff-hooks.patch`.

The stash itself is left in place in the main checkout (nothing there is reset, dropped
or rebased by the unattended seat). Dropping it after this lands is a DESTRUCTIVE act
for the tap queue: `git -C /Users/musicbox/repos/Primae stash drop 'stash@{0}'`.
