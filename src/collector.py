"""One collection cycle: query ARG per control, evaluate, store evidence, log (R1, R4, R7, R8, R12, R13)."""
from __future__ import annotations

import json
import logging
import os
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from azure.core.exceptions import HttpResponseError
from azure.identity import DefaultAzureCredential
from azure.mgmt.resourcegraph import ResourceGraphClient
from azure.mgmt.resourcegraph.models import QueryRequest, QueryRequestOptions
from azure.storage.blob import ContainerClient

from evidence import build_record, write_record
from ingest import LogWriter

CATALOG_PATH = Path(__file__).with_name("catalog.json")
MAX_RETRIES = 3


def load_catalog() -> list[dict]:
    return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))["controls"]


def render(query: str, subscription: str, target_rg: str) -> str:
    return query.replace("{subscription}", subscription).replace("{target_rg}", target_rg)


def _retry_after(err: HttpResponseError, attempt: int) -> float:
    """Wait time after HTTP 429: use x-ms-user-quota-resets-after (hh:mm:ss) if present."""
    try:
        value = err.response.headers.get("x-ms-user-quota-resets-after")
        h, m, s = (float(x) for x in value.split(":"))
        return max(1.0, h * 3600 + m * 60 + s)
    except Exception:  # header missing or malformed
        return 2.0 * (2 ** attempt)


def run_query(client: ResourceGraphClient, subscription: str, query: str,
              stats: dict) -> list[dict]:
    """Runs one ARG query with paging (T5) and retry on HTTP 429 (R12)."""
    rows: list[dict] = []
    skip_token = None
    while True:
        for attempt in range(MAX_RETRIES + 1):
            try:
                resp = client.resources(QueryRequest(
                    subscriptions=[subscription], query=query,
                    options=QueryRequestOptions(skip_token=skip_token, top=1000,
                                                result_format="objectArray")))
                break
            except HttpResponseError as err:
                if err.status_code == 429 and attempt < MAX_RETRIES:
                    stats["throttled"] += 1
                    time.sleep(_retry_after(err, attempt))
                    continue
                raise
        rows.extend(resp.data or [])
        skip_token = resp.skip_token
        if not skip_token:
            return rows


def evaluate(row: dict) -> bool:
    """R7: the query computes 'compliant'. Azure Resource Graph returns KQL booleans as 1/0 through the
    Python SDK, so true, 1 and "true" mean compliant; everything else (0, false, null, missing) does not."""
    v = row.get("compliant")
    return v is True or (type(v) is int and v == 1) or (isinstance(v, str) and v.lower() == "true")


def run_cycle() -> dict:
    subscription = os.environ["TARGET_SUBSCRIPTION_ID"]
    target_rg = os.environ["TARGET_RESOURCE_GROUP"]
    credential = DefaultAzureCredential()
    arg = ResourceGraphClient(credential)
    container = ContainerClient(account_url=os.environ["EVIDENCE_ACCOUNT_URL"],
                                container_name=os.environ.get("EVIDENCE_CONTAINER", "evidence"),
                                credential=credential)
    logs = LogWriter(credential)

    cycle_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:6]
    start = datetime.now(timezone.utc)
    stats = {"throttled": 0}
    errors: list[str] = []
    record_count = 0

    for control in load_catalog():
        query = render(control["query"], subscription, target_rg)
        try:
            rows = run_query(arg, subscription, query, stats)
            collected_at = datetime.now(timezone.utc)
            records, paths = [], []
            for row in rows:
                row["compliant"] = evaluate(row)
                rec = build_record(cycle_id=cycle_id, control=control, query=query,
                                   row=row, collected_at=collected_at)
                paths.append(write_record(container, rec))
                records.append(rec)
            logs.results(records, paths)
            record_count += len(records)
        except Exception as exc:  # one failing control must not stop the cycle (R13)
            logging.exception("Control %s failed", control["controlId"])
            errors.append(f"{control['controlId']}: {type(exc).__name__}: {exc}"[:500])

    end = datetime.now(timezone.utc)
    status = "Succeeded" if not errors else ("Partial" if record_count else "Failed")
    cycle = {
        "TimeGenerated": end.isoformat(timespec="seconds"),
        "CycleId": cycle_id,
        "StartTime": start.isoformat(timespec="seconds"),
        "EndTime": end.isoformat(timespec="seconds"),
        "DurationSec": round((end - start).total_seconds(), 2),
        "RecordCount": record_count,
        "Status": status,
        "Throttled": stats["throttled"],
        "Error": " | ".join(errors)[:4000],
    }
    logs.cycle(cycle)
    logging.info("Cycle %s finished: %s, %d records, %.1f s", cycle_id, status,
                 record_count, cycle["DurationSec"])
    return cycle
