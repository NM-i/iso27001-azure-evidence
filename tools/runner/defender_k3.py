#!/usr/bin/env python3
"""K3 for Defender for Cloud from tools/defender_poll.sh output (one CSV per scenario).

  python3 tools/runner/defender_k3.py tests/drift/t0.csv build > build/k3_defender.csv
The keyword per control follows appendix 3 of the practical part; controls without a matching
Defender recommendation are reported as '—'. Verify the keywords against build/defender_baseline.txt.
"""
from __future__ import annotations

import csv
import sys
from datetime import datetime, timedelta
from pathlib import Path

KEYWORDS = {  # scenario: (control, lower-case keyword in the recommendation name)
    "D01": ("A.8.2", None), "D02": ("A.8.3", "public access"), "D03": ("A.8.5", "shared key"),
    "D04": ("A.8.9", None), "D05": ("A.8.13", "deletion protection"), "D06": ("A.8.15", None),
    "D07": ("A.8.16", None), "D08": ("A.8.20", None), "D09": ("A.8.21", "public network access"),
    "D10": ("A.8.22", "network security group"), "D11": ("A.8.24", "secure transfer"),
}
LIMIT = timedelta(hours=1)


def ts(s: str) -> datetime | None:
    try:
        return datetime.fromisoformat(s.strip().replace("Z", "+00:00"))
    except ValueError:
        return None


def main(t0_csv: str, folder: str) -> None:
    t0s = {r["id"]: ts(r["utc"]) for r in csv.DictReader(open(t0_csv, encoding="utf-8")) if r["action"] == "apply"}
    print("ID;Kontrolė;t0 (UTC);Defender Unhealthy (UTC);K3 min;Pastaba")
    for d, (ctrl, kw) in KEYWORDS.items():
        t0 = t0s.get(d)
        if not t0:
            print(f"{d};{ctrl};NENURODYTA;;;scenarijus nevykdytas"); continue
        if kw is None:
            print(f"{d};{ctrl};{t0:%Y-%m-%d %H:%M:%S};;—;nėra atitinkamos rekomendacijos (3 priedas)"); continue
        path = Path(folder) / f"defender_{d}.csv"
        hit = None
        if path.exists():
            for r in csv.DictReader(open(path, encoding="utf-8")):
                if kw in r["name"].lower() and r["status"].lower() == "unhealthy":
                    changed, polled = ts(r["statusChangeDate"] or ""), ts(r["polledAt"])
                    cand = changed if changed and changed >= t0 else polled
                    if cand and t0 <= cand <= t0 + LIMIT and (hit is None or cand < hit):
                        hit = cand
        if hit:
            print(f"{d};{ctrl};{t0:%Y-%m-%d %H:%M:%S};{hit:%H:%M:%S};{(hit - t0).total_seconds() / 60:.1f};")
        else:
            note = "neaptikta per 1 val." if path.exists() else "nėra stebėjimo failo"
            print(f"{d};{ctrl};{t0:%Y-%m-%d %H:%M:%S};;;{note}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
