---
name: create-pr
description: "PocketDJ's local 'PR' flow — NOT a GitHub PR. Push the current branch, ask the user if it's OK to merge, then merge into main locally and push. Use when the user says 'create a pr', 'open a pr', 'pr this branch', 'push and merge', or runs /create-pr."
---

# create-pr (local push → update docs → test → ask → merge → ship TestFlight)

For this repo, "PR" means a **local** review-and-merge flow, **not** a GitHub pull
request (the GitHub API isn't reliably reachable here; SSH push works). The flow:

1. **Push** the current branch.
2. **Update the books** — bring both the product book (`docs/STORYBOOK.md`) and the
   architecture book (`docs/ARCHITECTURE.md` + `docs/architecture/*.md`) in sync with
   the branch's changes. **This is a required gate: do not skip it.**
3. **Run the tests** — the targeted set that maps to what changed; **judgment call**
   to escalate to the full matrix for broad/risky changes (CI always runs all).
4. **Ask** the user if it's OK to merge.
5. On yes, **merge into `main`** and push `main`. On no, stop (branch stays pushed).
6. **Ship the TestFlight builds — BOTH iOS and macOS** (when the change touches the app),
   so device and Mac testers stay on the same code.

PocketDJ keeps two living docs that MUST stay current on `main`:
- **`docs/STORYBOOK.md`** — the outside-in product/customer view (screens, user
  stories, what's new). Update it when a change alters **what the user sees or does**.
- **`docs/ARCHITECTURE.md`** + **`docs/architecture/01-…07-*.md`** — the inside-out
  systems view (entities, data flows, schemas). Update it when a change alters **how
  the system works**: a new/changed entity, endpoint, message schema, data flow,
  pipeline stage, env/config, or a current-vs-deferred status.

## Steps

### 1. Sanity + push
```bash
BRANCH=$(git branch --show-current)
[ "$BRANCH" = "main" ] && { echo "already on main — nothing to PR"; exit 0; }
git status --short          # warn if there are uncommitted changes; commit first if needed
git push -u origin "$BRANCH"
```
If there are uncommitted changes, commit them first (or tell the user) before pushing.

### 2. Update the books (required gate)
Before asking to merge, make sure **both** books reflect this branch's changes. Do
this every time — even a small feature usually touches at least one book.

```bash
# What did this branch change vs main? Use it to decide which book(s) need edits.
git diff --stat origin/main...HEAD
git log --oneline origin/main..HEAD
```

Decide and act:
1. **Read the diff** (the commands above + `git diff origin/main...HEAD` on the
   relevant files) to understand what actually changed.
2. **Product book — `docs/STORYBOOK.md`:** if the change adds/alters a screen, an
   affordance, a user-visible flow, or counts/copy the user sees, update the matching
   section (or add one), matching its outside-in tone. New screenshots go under
   `docs/storybook/` if applicable.
3. **Architecture book — `docs/ARCHITECTURE.md` + `docs/architecture/*.md`:** if the
   change touches an entity, an endpoint, a message/document schema, a data flow, a
   pipeline stage, an env var/config, an AWS resource, or a current-vs-deferred
   status, update the right **chapter** (1 Foundations · 2 Ingest · 3 Catalog &
   Data Model · 4 Performance Engine · 5 Playback & Rip · 6 Search · 7 Distribution
   & Clients) and, if the pillar map / ToC / "current vs coming" / inconsistencies
   list in `ARCHITECTURE.md` is affected, update that too. Keep the **Why → What →
   How** structure and the rule that every ASCII diagram is explained in the prose
   beneath it. Cite real file paths, endpoints, and field names.
4. **If genuinely no doc change is warranted** (e.g. a pure refactor, test-only, or
   tooling change with zero user-facing or architectural effect), say so explicitly
   to the user in one line — don't silently skip the gate.
5. **Commit** any doc edits on this branch and push, so the books land with the code:
   ```bash
   git add docs/
   git commit -m "Docs: sync STORYBOOK + ARCHITECTURE with $BRANCH"
   git push
   ```

### 3. Run the tests (targeted, judgment to run-all)
Verify the branch before merging — but don't blindly run the whole matrix. Use the
`apple-test` map to run only what the change touches:

```bash
git diff --name-only origin/main...HEAD     # what changed → which test rows
```

- **Always** run the full unit bundle (`-only-testing:PocketDJTests`, ~0.3s).
- Run the **UI classes selected** from the changed paths via
  `apple/docs/storybook-test-map.md` §B, on the **device(s) the change implicates**
  (iPhone for logic; + macOS for keyboard paths; + iPad for layout).
- **Judgment call — escalate to the full matrix** (every class × iPhone + iPad +
  macOS) when the change hits a **shell/infra** row (`RootView`, `PocketDJApp`,
  `Theme`, `project.yml`, `XCUIHelpers`) or **≥3 feature rows**, or when you're not
  confident the targeted set covers the blast radius. When in doubt, widen.
- A **run-all is always the CI pipeline's job** — locally, reserve it for the above.
- Non-apple changes (server `scripts/`, web `src/`) run their own checks instead.

State which set you ran (and why) when you ask to merge. If anything fails, stop and
surface it — don't merge red.

### 4. Ask for merge approval
Use the **AskUserQuestion** tool: "Merge `$BRANCH` into `main`?" with options
**Merge** / **Not yet**. Do not merge without an explicit yes. (Confirm the books are
updated — or that no update was needed — and report the test set run, as part of this ask.)

### 5. Merge into main (worktree-aware)
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

### 6. Ship the TestFlight builds (iOS + macOS)
After `main` has the merge, push a fresh TestFlight build for **both** Apple platforms so
device and Mac testers run the same code — PocketDJ ships a native iOS app **and** a native
sandboxed macOS app (two separate platforms / build-number sequences in App Store Connect):

```bash
apple/scripts/testflight.sh            # iOS
apple/scripts/testflight-macos.sh      # macOS (native, sandboxed)
apple/scripts/testflight-visionos.sh   # visionOS (when the change reaches Vision Pro)
```

- **Fully headless — just run them.** Credentials auto-source from
  `~/.config/pocketdj/asc.env`; signing uses the dedicated `pocketdj-ci` keychain (no
  login-keychain access, no GUI prompts) — see the `apple-publish` skill's "Headless
  signing" section. The old "requires an interactive session / prompt Levi" caveat is
  obsolete (fixed 2026-07-16). Verify each script prints `Upload succeeded` — don't
  claim a build shipped that didn't.
- **Scope:** ship both only when the change touches the **app** (`apple/…`). Skip for pure
  server (`scripts/`), web (`src/`), or docs/tooling changes — same judgment as the test step.
- Build numbers default to a unix timestamp (`CURRENT_PROJECT_VERSION`), so uploads never
  collide; iOS and macOS sequence independently. See the `apple-publish` skill for prerequisites.
- The native macOS build is why we **disable "iPhone/iPad apps on Mac"** for the iOS app in
  App Store Connect — Mac users get the real sandboxed app, not the iOS-on-Mac variant (which
  can't `MusicLibrary.add` and crashed on it).

### Notes
- The **docs gate (Step 2) runs before every merge** — both books are kept current on
  `main` so they never drift behind the code that ships.
- No `gh pr create` / no GitHub PR is opened — intentional.
- The feature branch is left intact after merging (delete it manually if desired).
- Pushing uses the SSH remote (`levi.github.com:galxy25/pocketdj`), which is the
  working git transport here.
