---
name: development
description: "How to start ANY development work in PocketDJ: always on a feature branch off main, NEVER directly on main. Use at the start of any task that will edit code/config/scripts/docs, before the first commit. Pairs with create-pr (the branch → merge-back flow)."
---

# development (branch-first workflow)

**Rule: never commit work to `main` directly. Every change starts on a feature branch.**
`main` is the shipping branch — it only ever receives code via the `create-pr` merge flow
(review + docs gate + tests + explicit approval). Working on a branch keeps `main` releasable,
makes the change reviewable as a unit, and lets a build/test fail in isolation.

## Do this BEFORE your first edit/commit

```bash
BRANCH=$(git branch --show-current)
if [ "$BRANCH" = "main" ]; then
  # Name it for the work: feat/…, fix/…, skills/…, docs/…, chore/…
  git checkout -b fix/<short-description>
fi
git branch --show-current      # confirm you're NOT on main
```

- If you're **already on a feature branch**, stay on it (don't branch off a branch unless
  the new work is genuinely unrelated — then finish/PR the current one first).
- Pick a descriptive branch name: `feat/recognizer-add`, `fix/rip-race`, `skills/branch-workflow`.
- This repo may use git **worktrees** (`.claude/worktrees/…`) where `main` is checked out
  elsewhere; you still just create and work on your own branch in the current checkout.

## During the work
- Commit in logical chunks **on the branch**. End commit messages with the repo's standard
  `Co-Authored-By` / `Claude-Session` trailers.
- Push the branch when you want it backed up / shared (`git push -u origin "$BRANCH"`).

## Finishing
- Use **`create-pr`** to land the work: it pushes the branch, syncs the books
  (`docs/STORYBOOK.md` + `docs/ARCHITECTURE.md`), runs the targeted tests, asks for merge
  approval, then merges into `main` — and ships the TestFlight builds (iOS + macOS).

## The one exception
If the user **explicitly** says to commit straight to `main` (e.g. a hotfix to a server
script the running service pulls from `main`), honor that — but it must be their explicit
call each time, not a default. Otherwise: branch.
