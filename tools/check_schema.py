#!/usr/bin/env python3
"""R2 / TF-02: checks that every evidence record has all required, non-empty fields.

  python3 tools/check_schema.py --account stevidXXXX --date 2026-12-01 [--date 2026-12-02 ...]
"""
from __future__ import annotations

import argparse
import json
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from evidence import REQUIRED_FIELDS  # noqa: E402


def main() -> int:
    from azure.identity import DefaultAzureCredential
    from azure.storage.blob import ContainerClient
    ap = argparse.ArgumentParser()
    ap.add_argument("--account", required=True)
    ap.add_argument("--date", action="append", required=True, help="UTC day yyyy-mm-dd")
    a = ap.parse_args()
    cc = ContainerClient(f"https://{a.account}.blob.core.windows.net", "evidence",
                         credential=DefaultAzureCredential())
    days = {tuple(d.split("-")) for d in a.date}
    names = [b.name for b in cc.list_blobs()
             if tuple(b.name.split("/")[1:4]) in days]

    def missing(name: str) -> list[str]:
        rec = json.loads(cc.download_blob(name).readall())
        return [f for f in REQUIRED_FIELDS if rec.get(f) in (None, "")]

    bad = 0
    with ThreadPoolExecutor(max_workers=16) as pool:
        for name, miss in zip(names, pool.map(missing, names)):
            if miss:
                bad += 1
                print(f"{name}: trūksta {', '.join(miss)}")
    print(f"Patikrinta įrašų: {len(names)}; su trūkstamais laukais: {bad}")
    return 0 if names and bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
