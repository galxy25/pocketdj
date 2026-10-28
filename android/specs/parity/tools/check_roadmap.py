#!/usr/bin/env python3
"""Verify ../roadmap.json: shape, unique ids, deps exist + strictly earlier wave, ≤6 per wave,
per-wave disjointness of files ∪ shared_touchpoints, one owner per hot file per wave, no hot-file
edits after wave 1 except the allowed list, est ≤ 2500, every audit package represented, every
source_id resolvable.  Exit 1 on any violation."""
import glob
import json
import os
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
PARITY = os.path.dirname(HERE)
ROADMAP = os.path.join(PARITY, "roadmap.json")

REQ_PKG = ["id", "area", "source_ids", "title", "goal", "files", "shared_touchpoints", "depends_on", "acceptance",
           "unit_tests", "emulator_steps", "device_only", "est_lines", "priority", "wave"]
AREAS = {"playback", "mix", "studio", "games", "collections", "browse", "services", "surfaces"}
# Hot files that a package other than SURF-1 may still edit (decision D4), by basename.
ALLOWED_LATER = {
    "AndroidManifest.xml": {"SURF-2", "SURF-4", "SURF-7", "SURF-8", "COL-20"},
    "build.gradle.kts": {"STU-2", "BRW-17"},
    "libs.versions.toml": {"STU-2"},
    "ShellNavigation.kt": {"SURF-3"},
}
NEVER_LATER = {"MainActivity.kt", "AppGraph.kt", "AppSettingsStore.kt", "SettingsScreen.kt", "SettingsSections.kt", "PocketDjDestination.kt"}


def main():
    errs = []
    rm = json.load(open(ROADMAP))
    for k in ("decisions", "na_on_android", "packages", "waves"):
        if k not in rm:
            errs.append(f"missing top-level key {k}")
    pkgs = rm["packages"]
    hot = set(rm.get("hot_files", []))
    ids = [p["id"] for p in pkgs]
    dup = [i for i, c in Counter(ids).items() if c > 1]
    if dup:
        errs.append(f"duplicate ids {dup}")
    byid = {p["id"]: p for p in pkgs}
    for p in pkgs:
        for k in REQ_PKG:
            if k not in p:
                errs.append(f"{p['id']}: missing field {k}")
        if p["area"] not in AREAS:
            errs.append(f"{p['id']}: bad area {p['area']}")
        if p["priority"] not in ("P0", "P1", "P2"):
            errs.append(f"{p['id']}: bad priority")
        if not isinstance(p["wave"], int) or p["wave"] < 1:
            errs.append(f"{p['id']}: bad wave")
        if p["est_lines"] > 2500:
            errs.append(f"{p['id']}: est_lines {p['est_lines']} > 2500")
        if not p["files"]:
            errs.append(f"{p['id']}: no files")
        if not p["acceptance"] or not p["unit_tests"] or not p["emulator_steps"]:
            errs.append(f"{p['id']}: acceptance/unit_tests/emulator_steps must be non-empty")
        for d in p["depends_on"]:
            if d not in byid:
                errs.append(f"{p['id']}: unknown dep {d}")
            elif byid[d]["wave"] >= p["wave"]:
                errs.append(f"{p['id']} (wave {p['wave']}) depends on {d} (wave {byid[d]['wave']}) — not strictly earlier")
    # waves
    waves = rm["waves"]
    seen = set()
    for w in waves:
        if len(w["package_ids"]) > 6:
            errs.append(f"wave {w['n']} has {len(w['package_ids'])} > 6 packages")
        owner = {}
        for pid in w["package_ids"]:
            if pid in seen:
                errs.append(f"{pid} appears in two waves")
            seen.add(pid)
            p = byid.get(pid)
            if not p:
                errs.append(f"wave {w['n']} lists unknown {pid}")
                continue
            if p["wave"] != w["n"]:
                errs.append(f"{pid}.wave={p['wave']} but listed in wave {w['n']}")
            for f in set(p["files"]) | set(p["shared_touchpoints"]):
                if f in owner:
                    errs.append(f"wave {w['n']}: {f} touched by both {owner[f]} and {pid}")
                owner[f] = pid
        hot_count = Counter(os.path.basename(f) for f in owner if f in hot)
        for f, c in hot_count.items():
            if c > 1:
                errs.append(f"wave {w['n']}: hot file {f} edited by {c} packages")
    if seen != set(ids):
        errs.append(f"packages not in any wave: {sorted(set(ids) - seen)}")
    # hot-file discipline after wave 1
    for p in pkgs:
        if p["id"] == "SURF-1":
            continue
        for f in set(p["files"]) | set(p["shared_touchpoints"]):
            if f in hot:
                b = os.path.basename(f)
                if b in NEVER_LATER:
                    errs.append(f"{p['id']} edits {b} — only SURF-1 may (decision D3)")
                elif p["id"] not in ALLOWED_LATER.get(b, set()):
                    errs.append(f"{p['id']} edits hot file {b} but is not in the allowed list (decision D4)")
    # coverage of audit packages
    index = defaultdict(list)
    for f in glob.glob(os.path.join(PARITY, "audits", "*.json")):
        area = os.path.splitext(os.path.basename(f))[0]
        for ap in json.load(open(f))["packages"]:
            index[ap["id"]].append(area)
    covered = set()
    for p in pkgs:
        for s in p["source_ids"]:
            base, _, area = s.partition("@")
            if base not in index:
                errs.append(f"{p['id']}: source id {s} not in any audit")
            elif area and area not in index[base]:
                errs.append(f"{p['id']}: source id {s} area mismatch")
            covered.add(s)
    for base, areas in index.items():
        if len(areas) == 1:
            if base not in covered:
                errs.append(f"audit package {base} dropped")
        else:
            for a in areas:
                if f"{base}@{a}" not in covered:
                    errs.append(f"audit package {base}@{a} dropped")
    # dependency ordering sanity: foundations before consumers
    for p in pkgs:
        if p["priority"] == "P0" and p["wave"] > max(q["wave"] for q in pkgs if q["priority"] == "P2"):
            errs.append(f"{p['id']} is P0 but scheduled after the last P2 wave")
    # report
    n_src = len([k for k, v in index.items() for _ in v])
    print(f"packages={len(pkgs)} waves={len(waves)} audit_packages={n_src} est_total={sum(p['est_lines'] for p in pkgs)}")
    pc = Counter(p['priority'] for p in pkgs)
    print("priority:", dict(pc), "| areas:", dict(Counter(p['area'] for p in pkgs)))
    for w in waves:
        ps = [byid[i] for i in w["package_ids"] if i in byid]
        print(f"wave {w['n']:2d} [{'/'.join(sorted({p['priority'] for p in ps}))}] {' '.join(w['package_ids'])}")
    if errs:
        print(f"\n{len(errs)} VIOLATION(S):")
        for e in errs:
            print(" -", e)
        sys.exit(1)
    print("\nOK: disjointness, dependency ordering, wave size, hot-file discipline, coverage all clean")


if __name__ == "__main__":
    main()
