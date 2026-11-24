#!/usr/bin/env python3
"""Validate ../roadmap.json: ids unique, depends_on resolve, deps in EARLIER waves, waves cover every package exactly
once, package.wave matches, <= 8 per wave, owned files disjoint within each wave, hot/non-registration files touched by
<= 2 packages per wave, needs_levi has question + default, every package has the required fields.
Usage: python3 -I check_roadmap.py   (exit 1 on any failure)"""
import json
import os
import sys
from collections import Counter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
doc = json.load(open(os.path.join(ROOT, "roadmap.json")))
errs = []
REQ = ["id", "area", "title", "goal", "files", "shared_touchpoints", "depends_on", "acceptance", "unit_tests",
       "emulator_steps", "device_only", "est_lines", "size", "priority", "wave", "needs_levi"]
pk = doc["packages"]
ids = [p["id"] for p in pk]
for i, c in Counter(ids).items():
    if c > 1:
        errs.append(f"duplicate id {i}")
byid = {p["id"]: p for p in pk}
reg = set(doc["registration_files"])
for p in pk:
    for k in REQ:
        if k not in p:
            errs.append(f"{p['id']}: missing {k}")
    if not p["id"].startswith("P2-"):
        errs.append(f"{p['id']}: id prefix")
    for d in p["depends_on"]:
        if d not in byid:
            errs.append(f"{p['id']}: unknown dep {d}")
        elif byid[d]["wave"] >= p["wave"]:
            errs.append(f"{p['id']} (w{p['wave']}) depends on {d} (w{byid[d]['wave']}) not earlier")
    nl = p["needs_levi"]
    if nl is not None and not (isinstance(nl, dict) and nl.get("question") and nl.get("default")):
        errs.append(f"{p['id']}: needs_levi must be null or {{question, default}}")
    if not p["files"]:
        errs.append(f"{p['id']}: owns no files")
seen = Counter()
for w in doc["waves"]:
    n, wids = w["wave"], w["ids"]
    if len(wids) > 8:
        errs.append(f"wave {n}: {len(wids)} packages > 8")
    owned = {}
    touch = Counter()
    for i in wids:
        seen[i] += 1
        if i not in byid:
            errs.append(f"wave {n}: unknown id {i}")
            continue
        if byid[i]["wave"] != n:
            errs.append(f"{i}: package.wave {byid[i]['wave']} != wave {n}")
        for f in byid[i]["files"]:
            if f in owned:
                errs.append(f"wave {n}: {f} owned by {owned[f]} and {i}")
            owned[f] = i
        for f in set(byid[i]["files"]) | set(byid[i]["shared_touchpoints"]):
            touch[f] += 1
    for f, c in touch.items():
        if f not in reg and c > 2:
            errs.append(f"wave {n}: {f} touched by {c} packages (> 2)")
for i in ids:
    if seen[i] != 1:
        errs.append(f"{i}: appears in {seen[i]} waves")
for x in doc["not_scheduled"]:
    if x["reason"] not in ("platform-impossible", "out-of-scope"):
        errs.append(f"not_scheduled reason {x['reason']}")
if errs:
    print("\n".join(errs))
    sys.exit(1)
print(f"OK: {len(pk)} packages, {len(doc['waves'])} waves, deps earlier, owned files disjoint per wave, "
      f"{sum(1 for p in pk if p['needs_levi'])} needs_levi")
