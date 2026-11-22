#!/usr/bin/env python3
"""K3 and R7 (TF-05): detection time per drift scenario.

Inputs
  tests/drift/t0.csv            written by tests/drift/drift.sh (id,action,utc)
  results.json                  output of query 'K3_EXPORT' in kql/metrics.kql (-o json)
Output: one row per scenario = table 2.17 (t0, first 'neatitinka', K3 min, 'atitinka' after restore).
"""
from __future__ import annotations

import csv
import json
import statistics
import sys
from datetime import datetime, timedelta
from pathlib import Path

CONTROL = {"D01": "A.8.2", "D02": "A.8.3", "D03": "A.8.5", "D04": "A.8.9", "D05": "A.8.13",
           "D06": "A.8.15", "D07": "A.8.16", "D08": "A.8.20", "D09": "A.8.21", "D10": "A.8.22",
           "D11": "A.8.24"}
LIMIT = timedelta(hours=1)


def ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def main(t0_csv: str, results_json: str) -> None:
    events = {}
    for row in csv.DictReader(Path(t0_csv).open(encoding="utf-8")):
        events.setdefault(row["id"], {})[row["action"]] = ts(row["utc"])
    rows = json.loads(Path(results_json).read_text(encoding="utf-8"))
    for r in rows:
        r["_t"] = ts(r["CollectedAt"])
    rows.sort(key=lambda r: r["_t"])

    k3_values = []
    print("ID;Kontrolė;t0 (UTC);Pirmas neatitinka (UTC);K3 min;Po atkūrimo atitinka (UTC)")
    for d, ctrl in CONTROL.items():
        ev = events.get(d, {})
        t0, tr = ev.get("apply"), ev.get("restore")
        if not t0:
            print(f"{d};{ctrl};NENURODYTA;;;")
            continue
        first_nc = next((r["_t"] for r in rows if r["ControlId"] == ctrl
                         and r["Result"] == "neatitinka" and t0 <= r["_t"] <= t0 + LIMIT), None)
        k3 = round((first_nc - t0).total_seconds() / 60, 1) if first_nc else None
        if k3 is not None:
            k3_values.append(k3)
        back = None
        if tr:
            cycles = {}
            for r in rows:
                if r["ControlId"] == ctrl and r["_t"] >= tr:
                    cycles.setdefault(r["CycleId"], []).append(r)
            for cid in sorted(cycles, key=lambda c: cycles[c][0]["_t"]):
                if all(x["Result"] == "atitinka" for x in cycles[cid]):
                    back = cycles[cid][0]["_t"]
                    break
        cells = [d, ctrl, f"{t0:%Y-%m-%d %H:%M:%S}",
                 f"{first_nc:%H:%M:%S}" if first_nc else "neaptikta per 1 val.",
                 "" if k3 is None else f"{k3:.1f}",
                 f"{back:%H:%M:%S}" if back else "NENURODYTA"]
        print(";".join(cells))
    if k3_values:
        print(f"\nAptikta: {len(k3_values)} iš {len(CONTROL)}; K3 mediana {statistics.median(k3_values):.1f} min; "
              f"min {min(k3_values):.1f}; maks {max(k3_values):.1f}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
