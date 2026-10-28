#!/usr/bin/env python3
"""Build ../roadmap.json from the eight area audits + the hand-authored spec_*.py.

Usage:  python3 -I build_roadmap.py            (writes ../roadmap.json)
Re-runnable; nothing is kept in memory between runs, so a cut session loses nothing.
"""
import glob
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
PARITY = os.path.dirname(HERE)
OUT = os.path.join(PARITY, "roadmap.json")

from spec_common import DECISIONS, NA_ON_ANDROID, HOT_FILES  # noqa: E402
import spec_part1, spec_part2, spec_part3  # noqa: E402

MAX_PER_WAVE = 6
MAX_EST = 2500
PRIO_RANK = {"P0": 0, "P1": 1, "P2": 2}
STANDARD_ACC = [
    "The JVM unit-test COUNT increased by this package's new tests (not just exit 0) and `./gradlew :app:testDebugUnitTest` is green at the committed tip",
    "docs/ARCHITECTURE-ANDROID.md status ledger row for this package updated (DONE/PARTIAL + what is device-only)",
]


def load_audits():
    """{area_short: {pkg_id: pkg}} plus a flat index of 'ID' and 'ID@area'."""
    by_area, index = {}, {}
    for f in sorted(glob.glob(os.path.join(PARITY, "audits", "*.json"))):
        area = os.path.splitext(os.path.basename(f))[0]
        d = json.load(open(f))
        by_area[area] = {p["id"]: p for p in d["packages"]}
        for pid, p in by_area[area].items():
            p = dict(p)
            p["_area"] = area
            index.setdefault(pid, []).append(p)
            index[f"{pid}@{area}"] = [p]
    return by_area, index


def resolve(index, sid):
    hits = index.get(sid)
    if not hits:
        raise SystemExit(f"unknown source id {sid}")
    if len(hits) > 1:
        raise SystemExit(f"ambiguous source id {sid}: use {sid}@<area> ({', '.join(h['_area'] for h in hits)})")
    return hits[0]


def clean_path(s):
    """'path (annotation)' → 'path'; 'a, b (note)' → ['a','b']."""
    s = s.strip()
    note = ""
    mt = re.match(r"^(.*?)\s*\((.*)\)\s*$", s, re.S)
    if mt:
        s, note = mt.group(1).strip(), mt.group(2).strip()
    parts = [p.strip() for p in s.split(",") if p.strip()]
    return parts, note


def dedupe(seq):
    out, seen = [], set()
    for x in seq:
        k = x.strip()
        if k and k not in seen:
            seen.add(k)
            out.append(k)
    return out


def build_packages():
    _, index = load_audits()
    specs = spec_part1.PACKAGES + spec_part2.PACKAGES + spec_part3.PACKAGES
    ids = [s["id"] for s in specs]
    if len(ids) != len(set(ids)):
        raise SystemExit("duplicate final ids: " + str([i for i in ids if ids.count(i) > 1]))
    idset = set(ids)
    pkgs = []
    for s in specs:
        srcs = [resolve(index, x) for x in s["src"]]
        partials = [resolve(index, x) for x in s["partial"]]
        src_ids = dedupe([f"{p['id']}@{p['_area']}" if len(index[p["id"]]) > 1 else p["id"] for p in srcs + partials])
        title = s["title"] or (srcs[0]["title"] if srcs else "")
        goal = s["goal"] or " | ".join(dedupe(p["goal"] for p in srcs))
        acc = dedupe(sum((p.get("acceptance", []) for p in srcs), []) + s["acc"] + STANDARD_ACC)
        ut = dedupe(sum((p.get("unit_tests", []) for p in srcs), []) + s["ut"])
        emu = dedupe(sum((p.get("emulator_steps", []) for p in srcs), []) + s["emu"])
        if s["device"] is not None:
            device = s["device"]
        else:
            ds = dedupe(str(p.get("device_only") or "") for p in srcs)
            ds = [d for d in ds if d.lower().strip(". ") not in ("", "none", "no", "nothing")]
            device = " ".join(ds) if ds else "None (emulator-verifiable)."
        files = dedupe(s["files"])
        shared, notes = [], []
        for x in s["shared"]:
            paths, note = clean_path(x)
            shared += paths
            if note:
                notes.append(f"{', '.join(paths)}: {note}")
        shared = [p for p in dedupe(shared) if p not in files]
        for d in s["deps"]:
            if d not in idset:
                raise SystemExit(f"{s['id']} depends on unknown {d}")
        if s["id"] in s["deps"]:
            raise SystemExit(f"{s['id']} depends on itself")
        if s["est"] > MAX_EST:
            raise SystemExit(f"{s['id']} est_lines {s['est']} > {MAX_EST}: split it")
        pkgs.append({
            "id": s["id"], "area": s["area"], "source_ids": src_ids, "title": title, "goal": goal,
            "files": files, "shared_touchpoints": shared, "notes": notes, "depends_on": dedupe(s["deps"]),
            "acceptance": acc, "unit_tests": ut, "emulator_steps": emu, "device_only": device,
            "est_lines": s["est"], "priority": s["prio"], "wave": None, "_rank": s["rank"],
        })
    # nothing dropped: every audit package must be referenced by some final package
    covered = set()
    for p in pkgs:
        for sid in p["source_ids"]:
            covered.add(sid)
    missing = []
    for key, hits in index.items():
        if "@" in key:
            continue
        for h in hits:
            k = f"{h['id']}@{h['_area']}" if len(hits) > 1 else h["id"]
            if k not in covered:
                missing.append(k)
    if missing:
        raise SystemExit("audit packages not represented in the roadmap: " + ", ".join(sorted(missing)))
    return pkgs


def footprint(p):
    return set(p["files"]) | set(p["shared_touchpoints"])


def schedule(pkgs):
    byid = {p["id"]: p for p in pkgs}
    order = sorted(pkgs, key=lambda p: (p["_rank"], PRIO_RANK[p["priority"]], -p["est_lines"], p["id"]))
    waves, wave_n = [], 0
    remaining = [p["id"] for p in order]
    while remaining:
        wave_n += 1
        used, chosen = set(), []
        for pid in list(remaining):
            p = byid[pid]
            if len(chosen) >= MAX_PER_WAVE:
                break
            if any(byid[d]["wave"] is None or byid[d]["wave"] >= wave_n for d in p["depends_on"]):
                continue
            fp = footprint(p)
            if fp & used:
                continue
            chosen.append(pid)
            used |= fp
        if not chosen:
            stuck = ", ".join(remaining[:8])
            raise SystemExit(f"scheduler stuck at wave {wave_n}; unschedulable: {stuck}")
        for pid in chosen:
            byid[pid]["wave"] = wave_n
            remaining.remove(pid)
        waves.append(chosen)
    return waves


def wave_meta(n, ids, byid):
    ps = [byid[i] for i in ids]
    areas = sorted({p["area"] for p in ps})
    prios = sorted({p["priority"] for p in ps})
    if n == 1:
        name = "Foundations: shell/DI extension points + pure cores"
    elif all(p["priority"] == "P0" for p in ps) and n <= 3:
        name = "Foundations: playback core, diag, rip client, offline store"
    elif all(p["priority"] == "P0" for p in ps):
        name = "P0 parity: " + ", ".join(areas)
    elif "P0" in prios:
        name = "P0 tail + P1 parity: " + ", ".join(areas)
    elif prios == ["P2"]:
        name = "P2 parity: " + ", ".join(areas)
    else:
        name = "P1 parity: " + ", ".join(areas)
    deps = sorted({d for p in ps for d in p["depends_on"]})
    hot = sorted({os.path.basename(f) for p in ps for f in footprint(p) if f in HOT_FILES})
    rationale = (f"{len(ps)} packages, {sum(p['est_lines'] for p in ps)} est. lines, priorities {'/'.join(prios)}; every depends_on ({', '.join(deps) if deps else 'none'}) "
                 f"lands in an earlier wave; files ∪ shared_touchpoints are pairwise disjoint so the packages run in parallel worktrees"
                 + (f"; hot files edited this wave: {', '.join(hot)} (one owner each)" if hot else "; no hot files edited"))
    return name, rationale


def main():
    pkgs = build_packages()
    waves = schedule(pkgs)
    byid = {p["id"]: p for p in pkgs}
    out_waves = []
    for n, ids in enumerate(waves, 1):
        name, rationale = wave_meta(n, ids, byid)
        out_waves.append({"n": n, "name": name, "rationale": rationale, "package_ids": ids})
    pkgs_out = sorted(pkgs, key=lambda p: (p["wave"], p["id"]))
    for p in pkgs_out:
        p.pop("_rank", None)
    roadmap = {
        "program": "PocketDJ Android parity",
        "generated_by": "android/specs/parity/tools/build_roadmap.py (edit spec_*.py, re-run build + check_roadmap.py)",
        "hot_files": HOT_FILES,
        "decisions": DECISIONS,
        "na_on_android": NA_ON_ANDROID,
        "packages": pkgs_out,
        "waves": out_waves,
    }
    with open(OUT, "w") as f:
        json.dump(roadmap, f, indent=1, ensure_ascii=False)
        f.write("\n")
    print(f"wrote {OUT}: {len(pkgs_out)} packages, {len(out_waves)} waves, {sum(p['est_lines'] for p in pkgs_out)} est lines")
    for w in out_waves:
        print(f"  wave {w['n']:2d} ({len(w['package_ids'])}): {' '.join(w['package_ids'])}")


if __name__ == "__main__":
    main()
