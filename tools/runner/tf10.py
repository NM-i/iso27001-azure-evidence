#!/usr/bin/env python3
"""TF-10 (R14): time from the first 'neatitinka' record to the Azure Monitor alert firing.

  python3 tools/runner/tf10.py tests/drift/t0.csv build/results.json build/alerts.json
alerts.json = GET .../providers/Microsoft.AlertsManagement/alerts (az rest). The alert of a scenario is
the first alert of rule 'sqr-noncompliant' fired within 70 min after t0 (scenarios run one at a time).
"""
from __future__ import annotations

import csv
import json
import sys
from datetime import datetime, timedelta

CONTROL = {"D01": "A.8.2", "D02": "A.8.3", "D03": "A.8.5", "D04": "A.8.9", "D05": "A.8.13",
           "D06": "A.8.15", "D07": "A.8.16", "D08": "A.8.20", "D09": "A.8.21", "D10": "A.8.22",
           "D11": "A.8.24"}


def ts(s: str) -> datetime:
    s = s.replace("Z", "+00:00")
    if "." in s:  # trim fractional seconds to 6 digits for fromisoformat
        head, tail = s.split(".", 1)
        frac, _, tz = tail.partition("+")
        s = f"{head}.{frac[:6]}+{tz}" if tz else f"{head}.{frac[:6]}"
    return datetime.fromisoformat(s)


def main(t0_csv: str, results_json: str, alerts_json: str) -> None:
    t0s = {r["id"]: ts(r["utc"]) for r in csv.DictReader(open(t0_csv, encoding="utf-8")) if r["action"] == "apply"}
    rows = json.load(open(results_json, encoding="utf-8"))
    alerts = [a["properties"]["essentials"] for a in json.load(open(alerts_json, encoding="utf-8")).get("value", [])
              if "sqr-noncompliant" in a["properties"]["essentials"].get("alertRule", "").lower()]
    print("ID;Kontrolė;Pirmas neatitinka (UTC);Įspėjimas suveikė (UTC);Skirtumas min;Kriterijus ≤ 10 min")
    for d, ctrl in CONTROL.items():
        t0 = t0s.get(d)
        if not t0:
            print(f"{d};{ctrl};;;;scenarijus nevykdytas"); continue
        nc = min((ts(r["CollectedAt"]) for r in rows if r["ControlId"] == ctrl and r["Result"] == "neatitinka"
                  and t0 <= ts(r["CollectedAt"]) <= t0 + timedelta(hours=1)), default=None)
        fired = min((ts(a["startDateTime"]) for a in alerts
                     if t0 <= ts(a["startDateTime"]) <= t0 + timedelta(minutes=70)), default=None)
        if nc and fired:
            diff = (fired - nc).total_seconds() / 60
            print(f"{d};{ctrl};{nc:%H:%M:%S};{fired:%H:%M:%S};{diff:.1f};{'taip' if diff <= 10 else 'ne'}")
        else:
            print(f"{d};{ctrl};{nc:%H:%M:%S}" if nc else f"{d};{ctrl};", end="")
            print(f";{fired:%H:%M:%S};;" if fired else ";nesuveikė per 70 min.;;ne")


if __name__ == "__main__":
    main(*sys.argv[1:4])
