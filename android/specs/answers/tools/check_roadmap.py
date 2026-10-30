#!/usr/bin/env python3
"""Verify ../roadmap.json: required fields, unique ids, deps exist + strictly earlier wave, <= 6 per wave,
per-wave disjoint files, one owner per hot file per wave, polish-gated files only at/after the gate wave,
est <= 1000 per package, every answered Q that needs code is covered.  Exit 1 on any violation."""
import json
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
ROADMAP = os.path.join(os.path.dirname(HERE), "roadmap.json")
REQ = ["id", "area", "source_ids", "q_refs", "title", "goal", "files", "shared_touchpoints", "depends_on", "acceptance",
       "unit_tests", "emulator_steps", "device_only", "est_lines", "size", "priority", "wave", "needs_levi", "polish_gated", "ledger_rows"]
AREAS = {"playback", "mix", "studio", "games", "collections", "browse", "services", "surfaces"}
# Answers Levi gave that require code (the brief's list minus Q7/Q14, which went to the polish branch).
MUST_COVER = {"Q2", "Q3", "Q5", "Q6", "Q11", "Q12", "Q15", "Q17", "Q18", "Q20", "Q21", "Q23", "Q24", "Q29", "Q31", "Q32",
              "Q36", "Q38", "Q40", "Q41", "Q42", "Q43", "Q50", "Q60", "Q61", "Q63", "Q69", "Q72", "Q75", "Q76", "Q79", "Q81", "Q84",
              "Q85", "Q86", "Q89", "Q94", "Q95", "Q96", "Q97", "Q98", "Q101"}


def gated(path, gl):
    return any(path == g or (g.endswith("/") and path.startswith(g)) for g in gl)


def main():
    rm = json.load(open(ROADMAP))
    errs = []
    pkgs, waves, gate, gl, hot = rm["packages"], rm["waves"], rm["polish_gate_wave"], rm["polish_gated"], set(rm["hot_files"])
    byid = {p["id"]: p for p in pkgs}
    for i, c in Counter(p["id"] for p in pkgs).items():
        if c > 1:
            errs.append(f"duplicate id {i}")
    for p in pkgs:
        for k in REQ:
            if k not in p:
                errs.append(f"{p['id']}: missing {k}")
        if p["area"] not in AREAS:
            errs.append(f"{p['id']}: bad area")
        if p["size"] not in ("S", "M", "L"):
            errs.append(f"{p['id']}: bad size")
        if p["est_lines"] > 1000:
            errs.append(f"{p['id']}: est {p['est_lines']} > 1000 - split it")
        if not (p["files"] and p["acceptance"] and p["unit_tests"] and p["emulator_steps"]):
            errs.append(f"{p['id']}: empty files/acceptance/tests/emulator_steps")
        for d in p["depends_on"]:
            if d not in byid:
                errs.append(f"{p['id']}: unknown dep {d}")
            elif byid[d]["wave"] >= p["wave"]:
                errs.append(f"{p['id']} (w{p['wave']}) depends on {d} (w{byid[d]['wave']}) - not strictly earlier")
        if p["wave"] < gate:
            for f in p["files"] + p["shared_touchpoints"]:
                if gated(f, gl):
                    errs.append(f"{p['id']} (w{p['wave']}) touches polish-gated {f} before gate wave {gate}")
    seen = set()
    for w in waves:
        if len(w["package_ids"]) > 6:
            errs.append(f"wave {w['n']}: {len(w['package_ids'])} > 6 packages")
        owner = {}
        for pid in w["package_ids"]:
            if pid in seen:
                errs.append(f"{pid} in two waves")
            seen.add(pid)
            p = byid.get(pid)
            if not p:
                errs.append(f"wave {w['n']}: unknown {pid}")
                continue
            if p["wave"] != w["n"]:
                errs.append(f"{pid}.wave={p['wave']} listed in wave {w['n']}")
            for f in set(p["files"]) | set(p["shared_touchpoints"]):
                if f in owner:
                    errs.append(f"wave {w['n']}: {f} touched by {owner[f]} and {pid}" + (" (HOT)" if f in hot else ""))
                owner[f] = pid
    if seen != set(byid):
        errs.append(f"not in any wave: {sorted(set(byid) - seen)}")
    covered = {q for p in pkgs for q in p["q_refs"]}
    for q in sorted(MUST_COVER - covered):
        errs.append(f"answer {q} not covered by any package")
    print(f"packages={len(pkgs)} waves={len(waves)} est_total={sum(p['est_lines'] for p in pkgs)} gate_wave={gate}")
    print("sizes:", dict(Counter(p['size'] for p in pkgs)), "| areas:", dict(Counter(p['area'] for p in pkgs)))
    for w in waves:
        print(f"wave {w['n']:2d}{' [GATE]' if w.get('gate') else '       '} {' '.join(w['package_ids'])}")
    print("needs Levi:", ", ".join(p["id"] for p in pkgs if p["needs_levi"]))
    if errs:
        print(f"\n{len(errs)} VIOLATION(S):")
        for e in errs:
            print(" -", e)
        sys.exit(1)
    print("\nOK: coverage, dependency order, wave size, disjointness, hot-file owners, polish gate all clean")


if __name__ == "__main__":
    main()
