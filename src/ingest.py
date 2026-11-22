"""Writes cycle log and per-record results to Log Analytics via Logs Ingestion API (R5, R8)."""
from __future__ import annotations

import logging
import os

from azure.monitor.ingestion import LogsIngestionClient

CYCLE_STREAM = "Custom-EvidenceCycle_CL"
RESULT_STREAM = "Custom-EvidenceResult_CL"


class LogWriter:
    def __init__(self, credential):
        self._client = LogsIngestionClient(endpoint=os.environ["DCE_ENDPOINT"],
                                           credential=credential, logging_enable=False)
        self._rule = os.environ["DCR_IMMUTABLE_ID"]

    def _upload(self, stream: str, rows: list[dict]) -> None:
        if not rows:
            return
        errors: list = []
        self._client.upload(rule_id=self._rule, stream_name=stream, logs=rows,
                            on_error=lambda e: errors.append(e))
        if errors:
            logging.error("Logs ingestion failed for %s: %s", stream, errors[0].error)
            raise RuntimeError(f"Logs ingestion failed for {stream}")

    def results(self, records: list[dict], paths: list[str]) -> None:
        rows = [{
            "TimeGenerated": r["collectedAt"],
            "CycleId": r["cycleId"],
            "ControlId": r["controlId"],
            "ControlName": r["controlName"],
            "ResourceId": r["resourceId"],
            "Result": r["result"],
            "CollectedAt": r["collectedAt"],
            "BlobPath": p,
            "Sha256": r["sha256"],
        } for r, p in zip(records, paths)]
        self._upload(RESULT_STREAM, rows)

    def cycle(self, row: dict) -> None:
        self._upload(CYCLE_STREAM, [row])
