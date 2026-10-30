export const meta = {
  name: 'android-answers-wave',
  description: 'Implement one Android answers wave: Sonnet implements each package on its own branch/worktree, Opus adversarially reviews, Sonnet fixes, then one integrator merges + tests + emulator-verifies',
  phases: [
    { title: 'Implement', detail: 'Sonnet, one worktree + branch answers/<ID> per package, WIP commits', model: 'sonnet' },
    { title: 'Review', detail: 'Opus adversarial review of each package diff', model: 'opus' },
    { title: 'Fix', detail: 'Sonnet applies MAJOR/MINOR findings', model: 'sonnet' },
    { title: 'Integrate', detail: 'merge into feat/android-answers, full tests, emulator, push', model: 'sonnet' },
  ],
}

// args: { wave: n, ids: [package ids] } — agents read their own entry from roadmap.json
// RESUMABILITY: every agent is idempotent — progress lives in git (branch answers/<ID>, WIP commits)
// and in android/specs/answers/status/<ID>.md, so a run killed by a session limit can be re-launched
// (same or new session) and each agent picks up from what is already committed.

const REPO = '/Users/deepspacenine/forges/levi/pocketdj'
const WT = '/Users/deepspacenine/forges/levi/pocketdj-answers-int'
const PW = '/Users/deepspacenine/forges/levi/pocketdj-answers-pkgs'
const ENV = 'export JAVA_HOME=/opt/homebrew/opt/openjdk@21 ANDROID_HOME=$HOME/Library/Android/sdk ANDROID_SERIAL=emulator-5556; export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"'
const TRAILER = 'Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>\nClaude-Session: https://claude.ai/code/session_01Uu1uQACmegGg8FWrQT7vxC'

const wave = args.wave
const pkgs = args.ids.map(id => ({ id, title: id }))
const RM = `${WT}/android/specs/answers/roadmap.json`
const entry = (id) => `ROADMAP ENTRY: read it with \`jq '.packages[] | select(.id=="${id}")' ${RM}\` (title, goal, files you OWN, shared_touchpoints, depends_on, acceptance, unit_tests, emulator_steps, device_only).`

const DOCS = `Design sources: the roadmap entry below; the area audit ${WT}/android/specs/parity/audits/<area>.json (inventory + architecture markdown for the area — read the parts relevant to you); ${WT}/docs/architecture/android-parity.md (cross-cutting decisions — follow them); ${WT}/android/specs/answers/roadmap.json (decisions + other packages, for context only). iOS reference code: ${REPO}/apple/PocketDJ (port BEHAVIOR faithfully, including hard-won invariants the audit names).`

const BUILD = `Build/test (run from <worktree>/android, env every shell: ${ENV}):
  ./gradlew :app:testDebugUnitTest :app:assembleDebug
Count tests from app/build/test-results/testDebugUnitTest/*.xml and confirm the count MOVED by the tests you added (a test file not picked up still exits 0). Use --tests "<pattern>" for fast inner loops. Do NOT boot or use the emulator (one shared emulator, the integrator owns it).`

const IOSNOTE = `If your package also touches iOS (apple/), run: cd <worktree>/apple && xcodegen generate && xcodebuild test -project PocketDJ.xcodeproj -scheme PocketDJ -destination 'id=3FE7AC66-C9C2-4495-9AC4-0DC7CE5E3DAD' -derivedDataPath build -only-testing:PocketDJTests and verify the executed count rose; delete <worktree>/apple/build afterwards (disk is tight). The UI-polish branch and the release build (feat/android-release-build) are MERGED into this branch — polish gating no longer applies, but respect their work. LEVI DECISIONS (2026-10-29, override the roadmap where they differ): C1 profile sync = deploy pocketdj-profile-sync to GREEN with its own secret (AWS_PROFILE=llc; Levi approved), opt-in, OFF by default (release build already flipped the default). C2 REVERSED = the app DOES declare/request ACCESS_BACKGROUND_LOCATION and every permission needed to be full-featured; keep the prominent-disclosure flow the release build added (disclosure → foreground → separate background step); location FGS while playing with places&trips on. The app is live in Google Play review (versionCode scheme = unix timestamp; release script android/scripts/release-aab.sh) — never break release builds: run assembleRelease too when you touch manifest/proguard/build files.`
const st = (id) => `android/specs/answers/status/${id}.md`

const IMPL_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' }, status: { type: 'string', enum: ['implemented', 'already-done', 'blocked'] },
  head_sha: { type: 'string' }, tests_total: { type: 'number' }, tests_failed: { type: 'number' },
  summary: { type: 'string' }, deviations: { type: 'string' } }, required: ['id', 'status', 'summary'] }
const REVIEW_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' }, skipped: { type: 'boolean' },
  findings: { type: 'array', items: { type: 'object', properties: {
    severity: { type: 'string', enum: ['MAJOR', 'MINOR', 'NIT'] }, file: { type: 'string' }, line: { type: 'number' },
    issue: { type: 'string' }, failure_scenario: { type: 'string' }, fix: { type: 'string' } },
    required: ['severity', 'file', 'issue', 'fix'] } } }, required: ['id', 'findings'] }
const FIX_SCHEMA = { type: 'object', properties: {
  id: { type: 'string' }, fixed: { type: 'number' }, rejected: { type: 'string' }, head_sha: { type: 'string' },
  tests_total: { type: 'number' }, tests_failed: { type: 'number' } }, required: ['id', 'fixed'] }

const implement = (p) => agent(`You are implementing Android answers work package (implements Levi's 2026-10-29 answer(s) named in the entry's q_refs; see android/specs/answers/roadmap.md + android/specs/parity/QUESTIONS.md ANSWERED) ${p.id} (wave ${wave}) for PocketDJ.

${entry(p.id)}

${DOCS}\n${IOSNOTE}

WORKSPACE + RESUME PROTOCOL (follow exactly — a previous attempt may have been killed mid-way):
1. W=${PW}/${p.id}. If ${WT}/${st(p.id)} exists on feat/android-answers and says "state: merged" → return status already-done.
2. If W exists, cd there and continue: read W/${st(p.id)} (your progress checklist) and \`git log feat/android-answers..HEAD\`; do not redo committed steps. Else if branch answers/${p.id} exists: \`git -C ${REPO} worktree add ${W_(p)} answers/${p.id}\`. Else: \`git -C ${REPO} worktree add -b answers/${p.id} ${W_(p)} feat/android-answers\`.
3. Work ONLY in W. Write/maintain W/${st(p.id)}: header \`state: in-progress\`, then a checklist of sub-steps with [x]/[ ], plus notes on deviations and any file you had to touch outside your owned files. COMMIT EARLY AND OFTEN (after each sub-step that compiles: \`git add -A && git commit -m "WIP ${p.id}: <step>"\`) so nothing is lost if you are killed. Never commit build outputs. Do not push.
4. Do NOT edit docs/ARCHITECTURE-ANDROID.md (the integrator updates its status ledger for every package — ignore that acceptance line). Stay inside your owned files + shared_touchpoints; other packages in this wave run in parallel on other files. If you must touch another file, keep the edit minimal and additive and note it in the status file.
5. Write real JVM unit tests for the logic (pure functions/state machines/serialization/iOS-shape JSON compat); no tests that assert nothing.
6. ${BUILD}
7. If something needs a product/infra decision from Levi, pick a sensible default, keep going, and list it under "## Questions for Levi" in the status file (the integrator collects them). Finish: status file \`state: implemented\` + summary + test count; final commit "${p.id}: <roadmap title>" with trailer lines:
${TRAILER}
Return the result object (head_sha = git rev-parse HEAD).`, { label: `impl:${p.id}`, phase: 'Implement', schema: IMPL_SCHEMA, model: 'sonnet' })

function W_(p) { return `${PW}/${p.id}` }

const review = (p, impl) => agent(`You are an ADVERSARIAL senior reviewer (Android + the iOS original) for PocketDJ Android parity package ${p.id}.
Worktree ${W_(p)} (branch answers/${p.id}); review \`git -C ${W_(p)} diff feat/android-answers...HEAD\`. READ ONLY — do not edit or commit.
If ${W_(p)}/${st(p.id)} already contains a "## Review" section with "fixes applied", return skipped=true and findings=[].
Implementer's report: ${JSON.stringify(impl)}
${entry(p.id)}
${DOCS}\n${IOSNOTE}
Hunt for REAL defects, and verify each by reading the code (and the iOS original it claims to port) before reporting:
- behavior divergence from iOS that the user would notice; dropped invariants the audit calls out (dead-air/stall discipline, generation counters, sync-clobber guards, iOS JSON shape compatibility)
- correctness: races, coroutine scope/lifecycle leaks, main-thread blocking IO, process-death/state restore, Media3/MediaSession misuse, permission handling, null/empty edge cases
- acceptance criteria not actually met; stubs/TODOs passed off as done; tests that cannot fail or don't exercise the logic
- edits outside owned files that will conflict with other packages
Default to skepticism, but do not report style nits as MAJOR. Return findings (severity MAJOR = user-visible bug/crash/data loss/missing acceptance; MINOR = real but smaller; NIT = optional).`, { label: `review:${p.id}`, phase: 'Review', schema: REVIEW_SCHEMA, model: 'opus' })

const fix = (p, rev) => agent(`Apply review fixes for PocketDJ Android parity package ${p.id} in worktree ${W_(p)} (branch answers/${p.id}).
Findings (Opus adversarial review):
${JSON.stringify(rev.findings, null, 1)}
Fix every MAJOR and MINOR (NITs optional). If you believe a finding is wrong, verify against the code + iOS original and explain in 'rejected' — don't silently skip. Add/adjust tests that would have caught each MAJOR.
${BUILD}
Then append to ${W_(p)}/${st(p.id)} a "## Review" section listing each finding → fixed/rejected(reason), write "fixes applied", set \`state: reviewed\`, commit "${p.id}: review fixes" with trailer lines:
${TRAILER}
If the status file already shows "fixes applied", just verify the build/tests and return.`, { label: `fix:${p.id}`, phase: 'Fix', schema: FIX_SCHEMA, model: 'sonnet' })

const results = await pipeline(pkgs,
  (p) => implement(p),
  async (impl, p) => {
    if (!impl || impl.status === 'blocked') return { impl, rev: null }
    if (impl.status === 'already-done') return { impl, rev: { id: p.id, findings: [], skipped: true } }
    return { impl, rev: await review(p, impl) }
  },
  async ({ impl, rev }, p) => {
    if (!rev || rev.skipped) return { id: p.id, impl, rev, fx: null }
    const actionable = rev.findings.filter(f => f.severity !== 'NIT')
    const fx = actionable.length ? await fix(p, rev) : null
    return { id: p.id, impl, rev, fx, actionable: actionable.length }
  })

const done = results.filter(Boolean)
const blocked = pkgs.filter(p => !done.find(d => d.id === p.id && d.impl && d.impl.status !== 'blocked')).map(p => p.id)
log(`wave ${wave}: ${done.length}/${pkgs.length} packages through review; blocked/failed: ${blocked.join(', ') || 'none'}`)

phase('Integrate')
const mergeable = done.filter(d => d.impl && d.impl.status === 'implemented').map(d => d.id)
const integ = await agent(`You are the INTEGRATOR for PocketDJ Android answers wave ${wave}. Integration worktree: ${WT} (branch feat/android-answers).
Packages to merge (each on local branch answers/<ID>, worktree ${PW}/<ID>): ${JSON.stringify(mergeable)}.
Per-package reports: ${JSON.stringify(done.map(d => ({ id: d.id, impl: d.impl && d.impl.summary, actionable_findings: d.actionable, fix: d.fx })))}
Roadmap entries (emulator_steps, device_only, acceptance): read from ${RM} by id.

RESUME-SAFE PROTOCOL:
1. cd ${WT}. Ensure a clean tree (\`git status\`); if a merge is in progress from a killed run, finish or abort it sensibly. For each ID: skip if \`git merge-base --is-ancestor answers/<ID> HEAD\` (already merged). Else if the branch has uncommitted work in ${PW}/<ID>, commit it there first ("WIP <ID>: integrator rescue"). Then \`git merge --no-ff answers/<ID> -m "Merge answers/<ID>"\`; resolve conflicts preserving BOTH sides' intent (hot files: nav graph, DI container, settings registry, gradle files, manifest).
2. After merges: in the merged ${WT}/android/specs/answers/status/<ID>.md set \`state: merged\` for each merged ID. ${BUILD.replace('Do NOT boot or use the emulator (one shared emulator, the integrator owns it).', '')} Fix any integration breakage (commit "Wave ${wave}: integration fixes"). Then commit status files and \`git push origin feat/android-answers\` (pull --no-rebase first if rejected).
3. Emulator: if \`adb devices\` shows no emulator, boot headless: \`emulator -avd pocketdj-ans -port 5556 -no-window -no-audio -no-boot-anim &\` then \`adb wait-for-device\` and wait for sys.boot_completed=1. Install app/build/outputs/apk/debug/app-debug.apk, launch com.levi.pocketdj/.MainActivity, and run each package's emulator_steps (adb shell input tap/swipe/text, uiautomator dump to find elements, screencap to ${PW}/_shots/wave${wave}/). Check \`adb logcat -d\` for FATAL EXCEPTION / ANR from com.levi.pocketdj. Fix crashes/blocking bugs you find (commit, push). Run EVERY emulator step of every merged package (seed data with adb push/run-as or debug intents when a step needs it) — 'not run' is not acceptable — if a step can't run because something is broken (e.g. playback never starts), that IS a bug: find and fix it (regression test), don't record it as not run. Debug seed actions live in screens/settings/DebugScreen.kt (Seed rip playlist / Play seed queue / Burn first 3) — reuse/extend them; NPLog lanes mirror to logcat tag PocketDJ.<lane>; if a step is genuinely impossible on the emulator, say exactly why. Device-only steps: mark as not verifiable.
4. If anything needs a product/infra decision from Levi (from package status files' deviations/open issues or your own findings), append it to the OPEN list in ${WT}/android/specs/parity/QUESTIONS.md in that file's format (next Q number, package, default being used meanwhile) — never block on it. Append a "Wave ${wave}" section to ${WT}/android/specs/parity/PROGRESS.md (packages merged, test count, emulator results per package, open issues), commit + push.
Return a concise report: merged ids, test total/failures, emulator pass/fail per package, open issues, head sha.`, { label: `integrate:wave${wave}`, phase: 'Integrate', model: 'sonnet' })

return { wave, merged: mergeable, blocked, reviews: done.map(d => ({ id: d.id, findings: d.rev && d.rev.findings ? d.rev.findings.length : 0, actionable: d.actionable || 0, fixed: d.fx && d.fx.fixed })), integ }
