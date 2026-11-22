"""Evidence record construction, hashing and immutable storage (R2, R3)."""
from __future__ import annotations

import hashlib
import json
import uuid
from datetime import datetime, timezone

from azure.storage.blob import ContentSettings

SCHEMA_VERSION = "1.0"
REQUIRED_FIELDS = (
    "schemaVersion", "recordId", "cycleId", "controlId", "controlName",
    "collectedAt", "source", "queryHash", "resourceId", "result",
    "observed", "sha256",
)


def canonical(obj: dict) -> bytes:
    """Canonical JSON: sorted keys, no whitespace, UTF-8."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, default=str).encode("utf-8")


def sha256_of(record: dict) -> str:
    """SHA-256 over the canonical record without the sha256 field."""
    body = {k: v for k, v in record.items() if k != "sha256"}
    return hashlib.sha256(canonical(body)).hexdigest()


def query_hash(query: str) -> str:
    return hashlib.sha256(query.encode("utf-8")).hexdigest()


def build_record(*, cycle_id: str, control: dict, query: str, row: dict,
                 collected_at: datetime) -> dict:
    record = {
        "schemaVersion": SCHEMA_VERSION,
        "recordId": str(uuid.uuid4()),
        "cycleId": cycle_id,
        "controlId": control["controlId"],
        "controlName": control["name"],
        "collectedAt": collected_at.astimezone(timezone.utc).isoformat(timespec="seconds"),
        "source": f"Azure Resource Graph: {control['table']}",
        "queryHash": query_hash(query),
        "resourceId": str(row.get("resourceId", "")),
        "result": "atitinka" if row.get("compliant") is True else "neatitinka",
        "observed": row.get("observed"),
    }
    record["sha256"] = sha256_of(record)
    return record


def blob_path(record: dict) -> str:
    ts = datetime.fromisoformat(record["collectedAt"])
    res = hashlib.sha1(record["resourceId"].lower().encode("utf-8")).hexdigest()[:12]
    return (f"{record['controlId']}/{ts:%Y/%m/%d}/"
            f"{record['cycleId']}_{res}.json")


def write_record(container_client, record: dict) -> str:
    """Write one record as a new blob. overwrite=False: an existing blob is never replaced."""
    path = blob_path(record)
    container_client.upload_blob(name=path, data=canonical(record), overwrite=False,
                                 content_settings=ContentSettings(content_type="application/json"))
    return path
