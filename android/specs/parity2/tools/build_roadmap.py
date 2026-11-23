#!/usr/bin/env python3
"""Build ../roadmap.json from spec.py (packages) + meta.py (decisions, conflicts, not_scheduled, wave names).

Usage: python3 -I build_roadmap.py && python3 -I check_roadmap.py

Waves are COMPUTED, not hand-typed: packages are placed greedily in priority order (P0 > P1 > P2 > P3, then spec order)
into the earliest wave that (a) comes after every dependency's wave, (b) has < MAX_PER_WAVE packages, (c) shares no
OWNED file with another package in the wave, and (d) keeps every non-registration file touched (owned or shared) by at
most 2 packages in the wave. Registration files (DI graphs, manifest, gradle, DebugScreen, nav/deep-link tables) may
be shared by any number of packages but owned by at most one per wave.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
ROOT = os.path.dirname(HERE)
import meta  # noqa: E402
import spec  # noqa: E402

MAX_PER_WAVE = 8
PFX = {"A/": "android/app/src/main/java/com/levi/pocketdj/",
       "T/": "android/app/src/test/java/com/levi/pocketdj/"}
PRIO = {"P0": 0, "P1": 1, "P2": 2, "P3": 3}


def ex(p):
    for k, v in PFX.items():
        if p.startswith(k):
            return v + p[len(k):]
    return p


REG = {ex(f) for f in spec.REGISTRATION}
HOT = [ex(f) for f in spec.HOT_FILES]


def size(est):
    return "S" if est < 400 else ("M" if est < 900 else "L")


def schedule(pkgs):
    ids = [p["id"] for p in pkgs]
    byid = {p["id"]: p for p in pkgs}
    order = {pid: i for i, pid in enumerate(ids)}
    wave_of = {}
    waves = {}  # n -> list of ids

    def fits(p, n):
        members = [byid[i] for i in waves.get(n, [])]
        if len(members) >= MAX_PER_WAVE:
            return False
        own = set(p["files"])
        touch = set(p["shared_touchpoints"])
        for m in members:
            mown, mtouch = set(m["files"]), set(m["shared_touchpoints"])
            if own & mown:
                return False
            for f in (own | touch) & (mown | mtouch):
                if f in REG:
                    continue
                # count all packages in the wave touching f (owned or shared), including p
                cnt = 1 + sum(1 for q in members if f in q["files"] or f in q["shared_touchpoints"])
                if cnt > 2:
                    return False
        return True

    pending = set(ids)
    while pending:
        ready = [i for i in pending if all(d in wave_of for d in byid[i]["depends_on"])]
        if not ready:
            raise SystemExit(f"dependency cycle among {sorted(pending)}")
        ready.sort(key=lambda i: (PRIO[byid[i]["priority"]], order[i]))
        pid = ready[0]
        p = byid[pid]
        n = max([wave_of[d] for d in p["depends_on"]] + [0]) + 1
        n = max(n, p.get("_min_wave", 1))
        while not fits(p, n):
            n += 1
        wave_of[pid] = n
        waves.setdefault(n, []).append(pid)
        pending.discard(pid)
    return wave_of, waves


def build():
    pkgs = []
    for s in spec.PACKAGES:
        p = {
            "id": s["id"], "area": s["area"], "source_ids": s["src"], "title": s["title"], "goal": s["goal"],
            "files": [ex(f) for f in s["files"]], "shared_touchpoints": [ex(f) for f in s.get("shared", [])],
            "notes": s.get("notes", []), "depends_on": list(s["deps"]),
            "acceptance": s["acc"] + spec.STD_ACC, "unit_tests": s["tests"], "emulator_steps": s["emu"],
            "device_only": s["device"], "est_lines": s["est"], "size": size(s["est"]), "priority": s["prio"],
            "wave": None, "needs_levi": s.get("levi"), "ios_refs": s.get("ios", []),
        }
        if "min_wave" in s:
            p["_min_wave"] = s["min_wave"]
        pkgs.append(p)
    # The release package depends on every package nothing else depends on (it runs last).
    rel = [p for p in pkgs if p["id"] == "P2-REL-1"][0]
    depended = {d for p in pkgs if p is not rel for d in p["depends_on"]}
    rel["depends_on"] = sorted(p["id"] for p in pkgs if p["id"] != rel["id"] and p["id"] not in depended)

    wave_of, waves = schedule(pkgs)
    for p in pkgs:
        p["wave"] = wave_of[p["id"]]
        p.pop("_min_wave", None)
    byid = {p["id"]: p for p in pkgs}
    wave_list = []
    for n in sorted(waves):
        ids = sorted(waves[n], key=lambda i: (PRIO[byid[i]["priority"]], i))
        hot_owned = sorted({f.split("/")[-1] for i in ids for f in byid[i]["files"] if f in HOT})
        lines = sum(byid[i]["est_lines"] for i in ids)
        wave_list.append({
            "wave": n, "name": meta.WAVE_NAMES.get(n, ""), "ids": ids,
            "titles": {i: byid[i]["title"] for i in ids},
            "rationale": f"{len(ids)} packages, {lines} est. lines; owned files pairwise disjoint; hot files owned this wave: "
                         + (", ".join(hot_owned) or "none"),
            "release_cut": meta.RELEASE_CUTS.get(n),
        })
    pkgs.sort(key=lambda p: (p["wave"], PRIO[p["priority"]], p["id"]))
    doc = {
        "program": spec.PROGRAM,
        "generated_by": "android/specs/parity2/tools/build_roadmap.py (edit spec.py / meta.py, re-run build + check_roadmap.py)",
        "design": "docs/architecture/android-parity2.md",
        "audits": "android/specs/parity2/audits/{playback,pockets,vinyl-library,remote-social,surfaces}.md",
        "integration_branch": "feat/android-parity2",
        "workflow": "android/specs/parity2/wave-workflow.js (args {wave, ids})",
        "hot_files": HOT,
        "registration_files": sorted(REG),
        "decisions": meta.DECISIONS,
        "micro_decisions": meta.MICRO_DECISIONS,
        "conflicts": meta.CONFLICTS,
        "stale_premises": meta.STALE_PREMISES,
        "external_deps": meta.EXTERNAL_DEPS,
        "not_scheduled": meta.NOT_SCHEDULED,
        "release_cuts": [{"after_wave": n, "note": t} for n, t in sorted(meta.RELEASE_CUTS.items())],
        "packages": pkgs,
        "waves": wave_list,
    }
    with open(os.path.join(ROOT, "roadmap.json"), "w") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    for w in wave_list:
        print(f"W{w['wave']}: " + ", ".join(w["ids"]))
    print(f"{len(pkgs)} packages, {len(wave_list)} waves, {sum(p['est_lines'] for p in pkgs)} est lines")


if __name__ == "__main__":
    build()
