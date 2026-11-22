#!/usr/bin/env python3
"""Sends one runner event to Log Analytics (RunnerStatus_CL); alert rules turn it into an e-mail.

  python3 tools/runner/notify.py <EVENT> "<detail>"
Events: LAUNCHED, STARTED, STAGE, FAILED, DONE, CANCELLED, HEARTBEAT (HEARTBEAT is not e-mailed).
Needs DCE_ENDPOINT and DCR_IMMUTABLE_ID. Never fails the caller: errors are printed and exit code is 0.
"""
import os
import sys
from datetime import datetime, timezone

try:
    from azure.identity import DefaultAzureCredential
    from azure.monitor.ingestion import LogsIngestionClient

    event = sys.argv[1]
    detail = sys.argv[2] if len(sys.argv) > 2 else ""
    client = LogsIngestionClient(os.environ["DCE_ENDPOINT"], DefaultAzureCredential(), logging_enable=False)
    client.upload(rule_id=os.environ["DCR_IMMUTABLE_ID"], stream_name="Custom-RunnerStatus_CL", logs=[{
        "TimeGenerated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "Event": event, "Detail": detail[:500], "Step": os.environ.get("RUNNER_STEP", "")}])
except Exception as exc:  # notifications are best effort
    print(f"notify failed: {type(exc).__name__}: {exc}", file=sys.stderr)
