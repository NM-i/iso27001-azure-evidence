#!/usr/bin/env bash
# Repeats drift scenarios D02, D03 and D05 for the Defender for Cloud comparison, AFTER the main runner
# has finished (results/STATUS.txt = DONE). Started now, it waits by itself. Results: results_rerun/.
# Separate logs: build/rerun/ (t0.csv, defender_DXX.csv, k3_*); the main results are not touched.
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${RUNNER_ACCOUNT:?}" "${SUB:?}"
SCEN="${RERUN_SCENARIOS:-D02 D03 D05}"
export T0_FILE=build/rerun/t0.csv DRIFT_SUFFIX=b RUNNER_MODE=1
mkdir -p build/rerun
LOG=build/rerun/runner.log
log()    { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
now()    { date -u +%s; }
blob()   { az storage blob "$@" --account-name "$RUNNER_ACCOUNT" -c runner --auth-mode login -o none; }
notify() { python3 tools/runner/notify.py "$@" || true; }
LAST_HB=0
heartbeat() { [ $(( $(now) - LAST_HB )) -ge 3600 ] && { notify HEARTBEAT "rerun"; LAST_HB=$(now); }; return 0; }
save()   { tar -czf /tmp/rr.tgz build/rerun; blob upload -n results_rerun/snapshot.tar.gz -f /tmp/rr.tgz --overwrite || true; }
status() { echo "$*" > build/rerun/STATUS.txt; blob upload -n results_rerun/STATUS.txt -f build/rerun/STATUS.txt --overwrite || true; }
is_done(){ grep -qx "$1" build/rerun/done.txt 2>/dev/null; }
mark()   { echo "$1" >> build/rerun/done.txt; log "DONE $1"; save; }

if [ "$(az storage blob exists --account-name "$RUNNER_ACCOUNT" -c runner -n results_rerun/snapshot.tar.gz \
       --auth-mode login --query exists -o tsv)" = "true" ]; then
  blob download -n results_rerun/snapshot.tar.gz -f /tmp/rr.tgz && tar -xzf /tmp/rr.tgz; log "Resumed"
fi
out() { az deployment group show -g rg-iso-proto -n main --query "properties.outputs.$1.value" -o tsv; }
WS=$(out workspaceCustomerId)

# 1. wait for the main runner (no changes during its 24 h run)
if ! is_done wait_main; then
  status "WAITING for the main runner (DONE) since $(date -u +%FT%TZ)"
  notify STARTED "Pakartotinis Defender palyginimas paleistas; laukiama pagrindinio vykdytojo pabaigos (DONE). Tada D02, D03, D05 (~3,5 val.)."
  while true; do
    if blob download -n results/STATUS.txt -f /tmp/main_status.txt 2>/dev/null && grep -q '^DONE' /tmp/main_status.txt; then break; fi
    heartbeat; sleep 600
  done
  mark wait_main
fi

# 2. scenarios, one at a time (apply, 1 h Defender polling, restore, 10 min pause)
for d in $SCEN; do
  is_done "rerun_$d" && continue
  status "RUNNING rerun_$d since $(date -u +%FT%TZ)"; log "START rerun_$d"
  if grep -q "^$d,apply," "$T0_FILE" 2>/dev/null && ! grep -q "^$d,restore," "$T0_FILE"; then
    bash tests/drift/drift.sh restore "$d" >>"$LOG" 2>&1 || true; echo "$d interrupted" >> build/rerun/interrupted.txt
    [ "$d" = "D05" ] && { mark "rerun_$d"; continue; }
    sleep 600
  fi
  if bash tests/drift/drift.sh apply "$d" >>"$LOG" 2>&1; then
    bash tools/defender_poll.sh "$d" > "build/rerun/defender_$d.csv" 2>>"$LOG" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do heartbeat; sleep 60; done
    bash tests/drift/drift.sh restore "$d" >>"$LOG" 2>&1 || echo "$d restore failed" >> build/rerun/failed.txt
    sleep 600
  else
    echo "$d apply failed" >> build/rerun/failed.txt
    bash tests/drift/drift.sh restore "$d" >>"$LOG" 2>&1 || true
  fi
  mark "rerun_$d"
done

# 3. K3 for both methods on the repeated scenarios
if ! is_done rerun_k3; then
  first=$(grep ',apply,' "$T0_FILE" | head -1 | cut -d, -f3)
  last=$(grep ',restore,' "$T0_FILE" | tail -1 | cut -d, -f3)
  while [ "$(now)" -lt $(( $(date -u -d "$last" +%s) + 1800 )) ]; do heartbeat; sleep 300; done
  az monitor log-analytics query -w "$WS" -o json --analytics-query "EvidenceResult_CL
| where CollectedAt between (datetime($first) - 10m .. datetime($last) + 30m)
| project CycleId, ControlId, ResourceId, Result, CollectedAt | order by CollectedAt asc" > build/rerun/results.json
  python3 tools/compute_k3.py "$T0_FILE" build/rerun/results.json > build/rerun/k3_prototype_rerun.txt
  python3 tools/runner/defender_k3.py "$T0_FILE" build/rerun > build/rerun/k3_defender_rerun.csv
  mark rerun_k3
fi

tar -czf /tmp/rres.tgz build/rerun
blob upload -n results_rerun/results.tar.gz -f /tmp/rres.tgz --overwrite
status "DONE at $(date -u +%FT%TZ)"
notify DONE "Pakartotinis Defender palyginimas (D02, D03, D05) baigtas. Rezultatai: tools/runner/fetch_results.sh"
log "RERUN DONE"
