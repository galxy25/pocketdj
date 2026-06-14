---
name: create-pr
description: "PocketDJ's local 'PR' flow — NOT a GitHub PR. Push the current branch, ask the user if it's OK to merge, then merge into main locally and push. Use when the user says 'create a pr', 'open a pr', 'pr this branch', 'push and merge', or runs /create-pr."
---

# create-pr (local push → ask → merge)

For this repo, "PR" means a **local** review-and-merge flow, **not** a GitHub pull
request (the GitHub API isn't reliably reachable here; SSH push works). The flow:

1. **Push** the current branch.
2. **Ask** the user if it's OK to merge.
3. On yes, **merge into `main`** and push `main`. On no, stop (branch stays pushed).

## Steps

### 1. Sanity + push
```bash
BRANCH=$(git branch --show-current)
[ "$BRANCH" = "main" ] && { echo "already on main — nothing to PR"; exit 0; }
git status --short          # warn if there are uncommitted changes; commit first if needed
git push -u origin "$BRANCH"
```
If there are uncommitted changes, commit them first (or tell the user) before pushing.

### 2. Ask for merge approval
Use the **AskUserQuestion** tool: "Merge `$BRANCH` into `main`?" with options
**Merge** / **Not yet**. Do not merge without an explicit yes.

### 3. Merge into main (worktree-aware)
This project uses git worktrees (`.claude/worktrees/…`), so `main` is checked out
in a **different** worktree and can't be checked out here. Merge in the worktree
that owns `main`:
```bash
# find the worktree where main is checked out (falls back to current dir)
MAIN_WT=$(git worktree list --porcelain | awk '/^worktree /{wt=$2} /^branch refs\/heads\/main$/{print wt}')
MAIN_WT=${MAIN_WT:-$(git rev-parse --show-toplevel)}

git -C "$MAIN_WT" status --short            # ensure main worktree is clean
git -C "$MAIN_WT" fetch origin
git -C "$MAIN_WT" merge --no-ff "$BRANCH" -m "Merge $BRANCH into main"
git -C "$MAIN_WT" push origin main
echo "✓ merged $BRANCH into main and pushed"
```
- `--no-ff` keeps a merge commit so the branch's history is visible.
- If the merge conflicts, stop and surface the conflict to the user (don't force).
- If the main worktree has uncommitted changes, stop and ask the user to resolve first.

### Notes
- No `gh pr create` / no GitHub PR is opened — intentional.
- The feature branch is left intact after merging (delete it manually if desired).
- Pushing uses the SSH remote (`levi.github.com:galxy25/pocketdj`), which is the
  working git transport here.
