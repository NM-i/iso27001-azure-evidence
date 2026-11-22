#!/usr/bin/env python3
"""R10 / TS-03: downloads evidence records and verifies their SHA-256 hashes.

Examples
  python3 tools/verify_evidence.py --account stevidXXXX --control A.8.24 --date 2026-12-01 --out build/A.8.24
  python3 tools/verify_evidence.py --account stevidXXXX --control A.8.24 --date 2026-12-01 --la-export la.json
  python3 tools/verify_evidence.py --account stevidXXXX --names <blob> <blob> <blob>
  python3 tools/verify_evidence.py --tamper-test build/A.8.24
  python3 tools/verify_evidence.py --account stevidXXXX --cycle 20261202T100000Z-a1b2c3 --out build/k2_run1
The --cycle mode exports all records of one collection cycle (all 11 controls) and prints K2:
the time from the cycle start (encoded in the cycle ID) to the end of the export.
The --la-export file is the JSON output of the 'R10_LA_HASHES' query in kql/metrics.kql
(az monitor log-analytics query ... -o json). Requires 'Storage Blob Data Reader' on the container.
"""
from __future__ import annotations

import argparse
import copy
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from evidence import sha256_of  # noqa: E402


def cycle_start(cycle_id: str) -> datetime:
    """Cycle IDs look like 20261202T100000Z-a1b2c3; the first part is the cycle start (UTC)."""
    return datetime.strptime(cycle_id.split("-")[0], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def cycle_prefixes(cycle_id: str) -> list[str]:
    """Blob prefixes of one cycle for every catalog control (start day and next day, for cycles at midnight)."""
    catalog = json.loads((Path(__file__).resolve().parents[1] / "src" / "catalog.json").read_text(encoding="utf-8"))
    start = cycle_start(cycle_id)
    days = [start, start + timedelta(days=1)]
    return [f"{c['controlId']}/{d:%Y/%m/%d}/{cycle_id}_"
            for c in catalog["controls"] for d in days]


def check(record: dict) -> bool:
    return record.get("sha256") == sha256_of(record)


def download(account: str, names: list[str] | None, prefix, out: Path | None):
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import ContainerClient
    cc = ContainerClient(f"https://{account}.blob.core.windows.net", "evidence",
                         credential=DefaultAzureCredential())
    if names is None:
        prefixes = prefix if isinstance(prefix, list) else [prefix]
        names = [b.name for p in prefixes for b in cc.list_blobs(name_starts_with=p)]
    for n in names:
        data = cc.download_blob(n).readall()
        if out:
            p = out / n
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        yield n, json.loads(data)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--account")
    ap.add_argument("--control", help="e.g. A.8.24")
    ap.add_argument("--date", help="UTC day yyyy-mm-dd")
    ap.add_argument("--names", nargs="*")
    ap.add_argument("--cycle", help="cycle ID from EvidenceCycle_CL; exports the whole cycle and prints K2")
    ap.add_argument("--out", type=Path)
    ap.add_argument("--la-export", type=Path)
    ap.add_argument("--tamper-test", type=Path, help="folder with downloaded records")
    a = ap.parse_args()

    if a.tamper_test:
        files = sorted(a.tamper_test.rglob("*.json"))
        original = json.loads(files[0].read_text(encoding="utf-8"))
        tampered = copy.deepcopy(original)
        tampered["result"] = "atitinka" if original["result"] == "neatitinka" else "neatitinka"
        print(f"Original {files[0].name}: {'sutampa' if check(original) else 'NESUTAMPA'}")
        print(f"Changed copy (result -> {tampered['result']}): "
              f"{'sutampa' if check(tampered) else 'NESUTAMPA (pakeitimas aptiktas)'}")
        return 0 if check(original) and not check(tampered) else 1

    prefix = None
    if a.cycle:
        prefix = cycle_prefixes(a.cycle)
    elif a.control and a.date:
        y, m, d = a.date.split("-")
        prefix = f"{a.control}/{y}/{m}/{d}/"
    la = {}
    if a.la_export:
        for row in json.loads(a.la_export.read_text(encoding="utf-8")):
            la[row["BlobPath"]] = row["Sha256"]

    t0 = time.monotonic()
    total = ok = la_ok = la_missing = 0
    for name, rec in download(a.account, a.names, prefix, a.out):
        total += 1
        good = check(rec)
        ok += good
        if la:
            if name not in la:
                la_missing += 1
            elif la[name] == rec["sha256"]:
                la_ok += 1
        if not good:
            print(f"NESUTAMPA: {name}")
    pct = 100.0 * ok / total if total else 0.0
    print(f"Įrašų: {total}; maiša sutampa: {ok} ({pct:.1f} %)")
    if la:
        print(f"Sutampa su EvidenceResult_CL: {la_ok}; žurnale nerasta: {la_missing}")
    print(f"Trukmė: {time.monotonic() - t0:.1f} s")
    if a.cycle:
        controls = {f.relative_to(a.out).parts[0] for f in a.out.rglob("*.json")} if a.out else set()
        k2 = (datetime.now(timezone.utc) - cycle_start(a.cycle)).total_seconds() / 60
        print(f"Kontrolių rinkinyje: {len(controls) if a.out else 'NENURODYTA (naudokite --out)'}")
        print(f"K2 (nuo ciklo pradžios iki eksporto pabaigos): {k2:.1f} min")
    return 0 if total and ok == total else 1


if __name__ == "__main__":
    sys.exit(main())
