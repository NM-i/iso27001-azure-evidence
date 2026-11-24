"""Local unit tests (no Azure access needed): python -m pytest tests/unit"""
import copy
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools"))

from collector import evaluate, load_catalog, render  # noqa: E402
from evidence import REQUIRED_FIELDS, blob_path, build_record, sha256_of  # noqa: E402

CONTROL = {"controlId": "A.8.24", "name": "Use of cryptography", "table": "resources"}
ROW = {"resourceId": "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st",
       "compliant": True, "observed": {"minimumTlsVersion": "TLS1_2", "supportsHttpsTrafficOnly": True}}
TS = datetime(2026, 11, 21, 12, 0, 5, tzinfo=timezone.utc)


def make():
    return build_record(cycle_id="c1", control=CONTROL, query="q", row=dict(ROW), collected_at=TS)


def test_record_has_all_fields():  # R2
    rec = make()
    assert all(rec.get(f) not in (None, "") for f in REQUIRED_FIELDS)


def test_hash_is_stable_and_detects_change():  # R2, R10
    rec = make()
    assert sha256_of(rec) == rec["sha256"]
    tampered = copy.deepcopy(rec)
    tampered["result"] = "neatitinka"
    assert sha256_of(tampered) != rec["sha256"]


def test_hash_independent_of_key_order():
    rec = make()
    reordered = json.loads(json.dumps(dict(reversed(list(rec.items())))))
    assert sha256_of(reordered) == rec["sha256"]


def test_evaluate_only_literal_true_is_compliant():  # R7
    for v in (True, 1, "true"):
        assert evaluate({"compliant": v}) is True
    for v in (False, None, 0, "false", 2, 1.0):
        assert evaluate({"compliant": v}) is False


def test_blob_path_layout():
    assert blob_path(make()).startswith("A.8.24/2026/11/21/c1_")


def test_catalog_has_at_least_10_controls_with_placeholders():  # R1
    controls = load_catalog()
    assert len(controls) >= 10
    ids = [c["controlId"] for c in controls]
    assert len(ids) == len(set(ids))
    for c in controls:
        q = render(c["query"], "sub", "rg")
        assert "{" not in q.replace("dynamic([{}])", "")
        for col in ("resourceId", "compliant", "observed"):
            assert col in q


def test_cycle_prefixes_cover_all_controls_and_midnight():  # K2 export
    from verify_evidence import cycle_prefixes, cycle_start
    cid = "20261231T235500Z-a1b2c3"
    prefixes = cycle_prefixes(cid)
    assert len(prefixes) == 2 * len(load_catalog())
    assert "A.8.24/2027/01/01/" + cid + "_" in prefixes
    assert cycle_start(cid).hour == 23
