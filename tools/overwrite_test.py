#!/usr/bin/env python3
"""TS-01 / TS-02 (R3): tries to overwrite and delete the given evidence blobs with the SDK and prints the
service error code. (Azure CLI shows every HTTP 409 as "add --overwrite", which hides the real reason.)

  python3 tools/overwrite_test.py --account stevidXXXX --names <blob> <blob> <blob>
Exit code 1 if any attempt succeeded.
"""
import argparse
import sys

from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential
from azure.storage.blob import ContainerClient

ap = argparse.ArgumentParser()
ap.add_argument("--account", required=True)
ap.add_argument("--names", nargs="+", required=True)
a = ap.parse_args()
cc = ContainerClient(f"https://{a.account}.blob.core.windows.net", "evidence", credential=DefaultAzureCredential())
ok = True
for name in a.names:
    attempts = (("TS-01 perrašymas", lambda: cc.upload_blob(name, b'{"tampered":true}', overwrite=True)),
                ("TS-02 trynimas", lambda: cc.delete_blob(name)))
    for test, action in attempts:
        try:
            action()
            print(f"{test} {name}: PAVYKO – NEATITINKA")
            ok = False
        except HttpResponseError as e:
            print(f"{test} {name}: atmesta, HTTP {e.status_code}, {e.error_code}")
sys.exit(0 if ok else 1)
