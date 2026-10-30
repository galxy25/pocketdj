#!/usr/bin/env python3
"""Build ../roadmap.json and ../roadmap.md from spec.py (single source).  Usage: python3 -I build_roadmap.py
Then run check_roadmap.py.  Same package schema as android/specs/parity/roadmap.json, plus answer-program fields
(q_refs, size, needs_levi, polish_gated, ledger_rows)."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)
import spec  # noqa: E402

PFX = {"A/": "android/app/src/main/java/com/levi/pocketdj/",
       "T/": "android/app/src/test/java/com/levi/pocketdj/",
       "AT/": "android/app/src/androidTest/java/com/levi/pocketdj/"}

WAVE_NAMES = {
    1: "Edition safety, game AM, playback settings + dead-air, Auto-DJ cooldown, SAF materializer, amPlaylistId",
    2: "Imported supersede + setlist export, burn-folder mirror, native Mix stretch, streaming bake, jukebox picker, golden scorer",
    3: "Activity cap, paginated ratings pull, Studio session owner + park/resume, Discover play/adds, skip consumers, ITP stub removal",
    4: "Real iOS fixtures, runtime enroll secret, SAF samples, clip paging, Mix restore + off-main",
    5: "Deep links + assetlinks, jukebox AM match, AM playlist reconcile, backup merges, pockets Settings row, ShazamKit",
    6: "Profile source A, Discover/rec gaps, soft-cap prune, stem carve",
    7: "Profile sync go-live (C1), Demux save, Recently-added producer",
    8: "POLISH GATE: PlaybackController pass, HeldQueue resumption, clause op, studio rows, games deep links, Mix sessions gaps",
    9: "Playback off-main",
    10: "Minimal background graph",
    11: "Location per C2, Mix on Oboe",
    12: "No-PARTIAL verification sweep + device checklist",
}


def ex(p):
    for k, v in PFX.items():
        if p.startswith(k):
            return v + p[len(k):]
    return p


GATED = [ex(g) for g in spec.POLISH_GATED]
HOT = [ex(h) for h in spec.HOT_FILES]


def gated(path):
    return any(path == g or (g.endswith("/") and path.startswith(g)) for g in GATED)


def build():
    pkgs = []
    for s in spec.PACKAGES:
        files = [ex(f) for f in s["files"]]
        p = {
            "id": s["id"], "area": s["area"], "source_ids": s["q"], "q_refs": s["q"], "title": s["title"], "goal": s["goal"],
            "files": files, "shared_touchpoints": [ex(f) for f in s.get("shared", [])], "notes": s.get("notes", []),
            "depends_on": s["deps"], "acceptance": s["acc"] + spec.STD_ACC, "unit_tests": s["tests"], "emulator_steps": s["emu"],
            "device_only": s["device"], "est_lines": s["est"], "size": s["size"], "priority": s["prio"], "wave": s["wave"],
            "needs_levi": s["levi"], "polish_gated": any(gated(f) for f in files), "ledger_rows": s["ledger"],
        }
        pkgs.append(p)
    nwaves = max(p["wave"] for p in pkgs)
    waves = []
    for n in range(1, nwaves + 1):
        ids = [p["id"] for p in pkgs if p["wave"] == n]
        ps = [p for p in pkgs if p["wave"] == n]
        hot = sorted({os.path.basename(f) for p in ps for f in p["files"] if f in HOT})
        waves.append({"n": n, "name": WAVE_NAMES.get(n, ""), "gate": ("feat/android-ui-polish merged to main; rebase integration branch" if n == spec.POLISH_GATE_WAVE else None),
                      "rationale": f"{len(ids)} packages, {sum(p['est_lines'] for p in ps)} est. lines; files pairwise disjoint; hot files (one owner each): {', '.join(hot) or 'none'}",
                      "package_ids": ids})
    rm = {"program": spec.PROGRAM, "generated_by": "android/specs/answers/tools/build_roadmap.py (edit spec.py, re-run build + check_roadmap.py)",
          "integration_branch": spec.INTEGRATION_BRANCH, "polish_gate_wave": spec.POLISH_GATE_WAVE, "polish_gated": GATED, "hot_files": HOT,
          "conflicts": spec.CONFLICTS, "stale_premises": [{"q": q, "note": n} for q, n in spec.STALE_PREMISES],
          "micro_decisions": [{"q": q, "default": n} for q, n in spec.MICRO_DECISIONS],
          "external_deps": [{"q": q, "note": n} for q, n in spec.EXTERNAL_DEPS],
          "not_scheduled": [{"q": q, "note": n} for q, n in spec.NOT_SCHEDULED], "packages": pkgs, "waves": waves}
    json.dump(rm, open(os.path.join(ROOT, "roadmap.json"), "w"), indent=1, ensure_ascii=False)
    open(os.path.join(ROOT, "roadmap.md"), "w").write(md(rm))
    print(f"wrote roadmap.json + roadmap.md: {len(pkgs)} packages, {len(waves)} waves")


def md(rm):
    pk = {p["id"]: p for p in rm["packages"]}
    L = []
    w = L.append
    w("# Android answers program — roadmap\n")
    w("*Generated from `android/specs/answers/tools/spec.py` by `build_roadmap.py`; checked by `check_roadmap.py`. Do not hand-edit — edit spec.py and rebuild.*\n")
    w("Source: Levi's answers in `android/specs/parity/QUESTIONS.md` (ANSWERED, main `2e7fd5ee`, 2026-10-29). Every answer that needs code has a package below; "
      "answers that need no code, or belong to another program, are listed under *Not scheduled*. Sizing came from reading the code at `2e7fd5ee` (four read-only scouts: playback, mix/studio, collections/sync, browse/games/services).\n")
    tot = sum(p["est_lines"] for p in rm["packages"])
    w(f"**{len(rm['packages'])} packages · {len(rm['waves'])} waves · ~{tot:,} est. lines.** Sizes: S < 300 · M 300–1000 · L > 1000 (L items are split so no package exceeds ~900).\n")
    w("## How it runs\n")
    w(f"- Same machinery as the parity program: one worktree + branch `answers/<ID>` per package off the integration branch **`{rm['integration_branch']}`** (cut from `main`), Sonnet implements → Opus adversarial review → Sonnet fixes → one integrator merges, runs the full JVM suite (count must move), runs every emulator step on the `pocketdj` AVD, pushes, appends a wave section to `android/specs/answers/PROGRESS.md`.")
    w("- Reuse `android/specs/parity/wave-workflow.js` with three constants changed: `RM` → `android/specs/answers/roadmap.json`, status dir → `android/specs/answers/status/<ID>.md`, integration branch `feat/android-parity` → `feat/android-answers` (branch prefix `parity/` → `answers/`). Everything else (resume protocol, WIP commits, review/fix schema) is unchanged.")
    w("- Packages in one wave have pairwise-disjoint files and at most one owner per hot wiring file (`di/*Graph.kt`, `PlaybackService.kt`, `SetlistSequencer.kt`, `BurnStore.kt`, `DebugScreen.kt`, manifest, gradle). Every `depends_on` lands in a strictly earlier wave.")
    w(f"- **Polish gate (wave {rm['polish_gate_wave']}).** Waves 1–{rm['polish_gate_wave']-1} touch none of the files `feat/android-ui-polish` is editing or was handed (Q7 nav → More, Q14 permissions + Burn Stop). "
      f"Wave {rm['polish_gate_wave']} starts only after that branch merges to main and `{rm['integration_branch']}` is rebased/merged onto it. Gated paths:\n")
    for g in rm["polish_gated"]:
        w(f"  - `{g}`")
    w("")
    w("- New-file names in `files` are proposals; an implementer may rename a NEW file (status note) but must stay off other packages' files.\n")
    w("## Conflicts to resolve (need Levi) — proposed resolutions\n")
    for c in rm["conflicts"]:
        w(f"### {c['id']}. {c['title']}\n")
        for f in c["facts"]:
            w(f"- {f}")
        w(f"\n**Proposal (built by the plan):** {c['proposal']}\n")
        alt = c.get("if_levi_says_q5") or c.get("if_levi_says_keep_background")
        if alt:
            w(f"**If Levi picks the other side:** {alt}\n")
        w(f"Affected packages: {', '.join(c['packages'])}.\n")
    w("## Premises that turned out stale (tell Levi; packages are sized to the real gap)\n")
    for s in rm["stale_premises"]:
        w(f"- **{s['q']}** — {s['note']}")
    w("\n## Micro-decisions taken as defaults (override any)\n")
    for s in rm["micro_decisions"]:
        w(f"- **{s['q']}** — {s['default']}")
    w("\n## Needs Levi\n")
    w("| Package | Wave | What |\n|---|---|---|")
    for p in rm["packages"]:
        if p["needs_levi"]:
            w(f"| {p['id']} | {p['wave']} | {p['needs_levi']} |")
    w("\nAll other packages are fully agent-drivable (emulator, JVM, iOS simulator / My Mac on this iMac).\n")
    w("## External dependencies\n")
    for s in rm["external_deps"]:
        w(f"- **{s['q']}** — {s['note']}")
    w("")
    w("## Waves\n")
    w("| Wave | Theme | Packages | Est. lines |\n|---|---|---|---|")
    for wv in rm["waves"]:
        est = sum(pk[i]["est_lines"] for i in wv["package_ids"])
        gate = " **(gate)**" if wv["gate"] else ""
        w(f"| {wv['n']}{gate} | {wv['name']} | {' · '.join(wv['package_ids'])} | {est} |")
    w("\n## Answer → package index\n")
    idx = {}
    for p in rm["packages"]:
        for q in p["q_refs"]:
            idx.setdefault(q, []).append(p["id"])
    def qkey(q):
        try:
            return int(q[1:])
        except ValueError:
            return 999
    w("| Q | Packages |\n|---|---|")
    for q in sorted(idx, key=qkey):
        w(f"| {q} | {', '.join(idx[q])} |")
    w("\n## Packages\n")
    for wv in rm["waves"]:
        w(f"### Wave {wv['n']} — {wv['name']}\n")
        if wv["gate"]:
            w(f"> **Gate:** {wv['gate']}.\n")
        for i in wv["package_ids"]:
            p = pk[i]
            w(f"#### {p['id']} — {p['title']}\n")
            w(f"- **Answers:** {', '.join(p['q_refs'])} · **Area:** {p['area']} · **Size:** {p['size']} (~{p['est_lines']} lines) · **Priority:** {p['priority']}"
              f" · **Depends on:** {', '.join(p['depends_on']) or '—'}{' · **Polish-gated**' if p['polish_gated'] else ''}")
            w(f"- **Goal:** {p['goal']}")
            if p["needs_levi"]:
                w(f"- **Needs Levi:** {p['needs_levi']}")
            w("- **Files:**")
            for f in p["files"]:
                w(f"  - `{f}`")
            w("- **Acceptance:**")
            for a in p["acceptance"]:
                w(f"  - {a}")
            w("- **Unit tests:** " + "; ".join(p["unit_tests"]))
            w("- **Emulator / device verification:**")
            for e in p["emulator_steps"]:
                w(f"  - {e}")
            w(f"  - Device-only: {p['device_only']}")
            w(f"- **Ledger rows to update:** {', '.join(p['ledger_rows'])}\n")
    w("## Not scheduled\n")
    for s in rm["not_scheduled"]:
        w(f"- **{s['q']}** — {s['note']}")
    w("")
    return "\n".join(L)


if __name__ == "__main__":
    build()
