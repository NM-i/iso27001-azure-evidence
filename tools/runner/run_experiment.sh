#!/usr/bin/env bash
# Automatic test runner (inside ACI). Executes stages 1–5 of the test plan without user interaction.
# Resumable: finished steps are listed in build/done.txt, which is saved to the runner storage
# account after every step together with all results (results/snapshot.tar.gz).
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${RUNNER_ACCOUNT:?}" "${SUB:?}"
export RUNNER_MODE=1
PROTO_RG=rg-iso-proto; TARGET_RG=rg-iso-target
DRIFTS="D01 D02 D03 D04 D05 D06 D07 D08 D09 D10 D11"
mkdir -p build tests/drift
LOG=build/runner.log

log()    { echo "$(date -u +%FT%TZ) $*" | tee -a "$LOG"; }
now()    { date -u +%s; }
iso()    { date -u -d "@$1" +%FT%TZ; }
blob()   { az storage blob "$@" --account-name "$RUNNER_ACCOUNT" -c runner --auth-mode login -o none; }
save()   { tar -czf /tmp/snap.tgz build tests/drift/t0.csv 2>/dev/null || tar -czf /tmp/snap.tgz build
           blob upload -n results/snapshot.tar.gz -f /tmp/snap.tgz --overwrite || log "WARN snapshot upload failed"; }
status() { echo "$*" > build/STATUS.txt; blob upload -n results/STATUS.txt -f build/STATUS.txt --overwrite || true; }
is_done(){ grep -qx "$1" build/done.txt 2>/dev/null; }
mark()   { echo "$1" >> build/done.txt; log "DONE $1"; save; }
la()     { az monitor log-analytics query -w "$WS" --analytics-query "$1" "${@:2}"; }
var()    { grep -h "^$1=" build/runner_state.env 2>/dev/null | tail -1 | cut -d= -f2-; }
setvar() { echo "$1=$2" >> build/runner_state.env; }
notify() { python3 tools/runner/notify.py "$@" || true; }
LAST_HB=0
heartbeat() { [ $(( $(now) - LAST_HB )) -ge 3600 ] && { notify HEARTBEAT "$(cat build/STATUS.txt 2>/dev/null)"; LAST_HB=$(now); }; return 0; }
sleep_until() { local t=$1; while [ "$(now)" -lt "$t" ]; do heartbeat; sleep $(( t - $(now) > 600 ? 600 : t - $(now) )); done; }

# ---------- restore previous progress ----------
if [ "$(az storage blob exists --account-name "$RUNNER_ACCOUNT" -c runner -n results/snapshot.tar.gz \
       --auth-mode login --query exists -o tsv)" = "true" ]; then
  blob download -n results/snapshot.tar.gz -f /tmp/snap.tgz && tar -xzf /tmp/snap.tgz
  log "Resumed; finished steps: $(tr '\n' ' ' < build/done.txt 2>/dev/null)"
fi

out() { az deployment group show -g "$PROTO_RG" -n main --query "properties.outputs.$1.value" -o tsv; }
ACC=$(out evidenceAccountName); WS=$(out workspaceCustomerId)
export ACC WS SUB
status "RUNNING since $(date -u +%FT%TZ)"
notify STARTED "Vykdytojas pradėjo darbą; atlikti žingsniai: $(tr '\n' ' ' < build/done.txt 2>/dev/null)"

# ---------- 1. baseline: TF-03 (R4), TF-01 part 1 (R1) ----------
step_baseline() {
  local ts=""
  for i in $(seq 1 24); do
    ts=$(la "EvidenceCycle_CL | where Status == 'Succeeded' | summarize t = min(StartTime)" --query "[0].t" -o tsv)
    [ -n "$ts" ] && break; log "waiting for the first successful cycle"; sleep 300
  done
  [ -n "$ts" ] || { log "no successful cycle after 2 h"; return 1; }
  setvar T_START "$ts"; log "T_START=$ts"
  sleep_until $(( $(date -u -d "$ts" +%s) + 3900 ))
  la "let t = datetime($ts);
EvidenceCycle_CL | where StartTime >= t and StartTime < t + 1h | order by StartTime asc
| extend IntervalSec = datetime_diff('second', StartTime, prev(StartTime))
| summarize Cycles = count(), MinIntervalSec = min(IntervalSec), MaxIntervalSec = max(IntervalSec),
            OutOfTolerance = countif(isnotnull(IntervalSec) and abs(IntervalSec - 300) > 30)" -o table > build/tf03_r4.txt
  python3 - > build/tf01_baseline.txt <<'PY'
import json, os, subprocess
sub = os.environ["SUB"]
for c in json.load(open("src/catalog.json"))["controls"]:
    q = c["query"].replace("{subscription}", sub).replace("{target_rg}", "rg-iso-target")
    print(f"===== {c['controlId']} {c['nameLt']}", flush=True)
    subprocess.run(["az", "graph", "query", "-q", q, "--subscriptions", sub,
                    "--query", "data[].{resource:resourceId, compliant:compliant}", "-o", "table"])
PY
}

# ---------- 2. TS-01..TS-03 (R3) ----------
step_immutability() { bash tools/immutability_test.sh > build/ts01_03_immutability.txt 2>&1; return 0; }

# ---------- 2. Defender CSPM on + wait for assessments ----------
DEF_Q="securityresources | where type == 'microsoft.security/assessments' and id contains '/resourceGroups/rg-iso-target/'"
step_defender_on() {
  az security pricing create -n CloudPosture --tier Standard -o none || return 1
  setvar DEFENDER_ON "$(date -u +%FT%TZ)"
  local prev=-1 n=0
  for i in $(seq 1 48); do                          # up to 12 h
    n=$(az graph query --subscriptions "$SUB" -q "$DEF_Q | count" --query "data[0].Count" -o tsv 2>/dev/null || echo 0)
    log "Defender assessments for target RG: $n"; heartbeat
    [ "${n:-0}" -ge 3 ] && [ "$n" = "$prev" ] && break
    prev=$n; sleep 900
  done
  az graph query --subscriptions "$SUB" --first 1000 --query data -o table -q "$DEF_Q
| project rekomendacija = tostring(properties.displayName), istekliai = tostring(properties.resourceDetails.Id), bukle = tostring(properties.status.code)
| order by rekomendacija asc" > build/defender_baseline.txt
}

# ---------- 3. drift scenarios (R7, K3, TF-04, TF-10) ----------
dashboard_watch() {   # TF-04 part 2: when does the dashboard query show A.8.9 as non-compliant?
  local t0=$1 end=$(( $1 + 1800 ))
  while [ "$(now)" -lt "$end" ]; do
    n=$(la "let lastCycle = toscalar(EvidenceCycle_CL | where Status in ('Succeeded','Partial') | top 1 by StartTime desc | project CycleId);
EvidenceResult_CL | where CycleId == lastCycle and ControlId == 'A.8.9' | summarize n = countif(Result == 'neatitinka')" --query "[0].n" -o tsv)
    if [ "${n:-0}" -gt 0 ]; then
      echo "t0=$(iso "$t0"); dashboard_noncompliant=$(date -u +%FT%TZ); minutes=$(( ($(now) - t0) / 60 ))" > build/tf04_dashboard.txt
      return
    fi
    sleep 60
  done
  echo "t0=$(iso "$t0"); dashboard_noncompliant=NOT_WITHIN_30_MIN" > build/tf04_dashboard.txt
}

run_drift() {
  local d=$1
  if grep -q "^$d,apply," tests/drift/t0.csv 2>/dev/null && ! grep -q "^$d,restore," tests/drift/t0.csv; then
    log "$d was interrupted: restoring"; bash tests/drift/drift.sh restore "$d" || true
    echo "$d interrupted at $(date -u +%FT%TZ)" >> build/interrupted.txt
    [ "$d" = "D05" ] && return 0                     # D05 cannot be repeated (vault name reserved)
    sleep 600
  fi
  if ! bash tests/drift/drift.sh apply "$d" >>"$LOG" 2>&1; then
    echo "$d apply failed at $(date -u +%FT%TZ)" >> build/drift_failed.txt
    bash tests/drift/drift.sh restore "$d" >>"$LOG" 2>&1 || true
    return 0                                         # R7 needs >= 8 of 11; continue with the next scenario
  fi
  local t0; t0=$(now)
  bash tools/defender_poll.sh "$d" > "build/defender_$d.csv" 2>>"$LOG" &
  local pid=$!
  [ "$d" = "D04" ] && dashboard_watch "$t0"
  while kill -0 "$pid" 2>/dev/null; do heartbeat; sleep 60; done
  wait "$pid"
  if ! bash tests/drift/drift.sh restore "$d" >>"$LOG" 2>&1; then
    echo "$d restore failed at $(date -u +%FT%TZ)" >> build/drift_failed.txt; return 1
  fi
  sleep 600
}

# ---------- 3. K3, Defender K3, TF-10 ----------
step_k3() {
  local first last
  first=$(grep ',apply,' tests/drift/t0.csv | head -1 | cut -d, -f3)
  last=$(grep ',restore,' tests/drift/t0.csv | tail -1 | cut -d, -f3)
  sleep_until $(( $(date -u -d "$last" +%s) + 1800 ))
  la "EvidenceResult_CL
| where CollectedAt between (datetime($first) - 10m .. datetime($last) + 30m)
| project CycleId, ControlId, ResourceId, Result, CollectedAt | order by CollectedAt asc" -o json > build/results.json
  python3 tools/compute_k3.py tests/drift/t0.csv build/results.json > build/k3_prototype.txt
  python3 tools/runner/defender_k3.py tests/drift/t0.csv build > build/k3_defender.csv
  az rest --method get --url "https://management.azure.com/subscriptions/$SUB/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview&timeRange=30d" > build/alerts.json
  python3 tools/runner/tf10.py tests/drift/t0.csv build/results.json build/alerts.json > build/tf10_alerts.txt
}

# ---------- 4. 24 h run: TF-08 (R12), TF-09 (R13), TF-06 (R8) ----------
step_run24() {
  local t24; t24=$(var T24)
  if [ -z "$t24" ]; then
    local s=$(( ( $(now) / 300 + 1 ) * 300 )); t24=$(iso "$s"); setvar T24 "$t24"; save
  fi
  log "24 h run from $t24"; status "24 h run from $t24"
  sleep_until $(( $(date -u -d "$t24" +%s) + 86400 + 900 ))
  la "let t = datetime($t24); EvidenceCycle_CL | where StartTime >= t | top 12 by StartTime asc
| summarize Cycles = count(), MedianDurationSec = percentile(DurationSec, 50), MaxDurationSec = max(DurationSec), Throttled429 = sum(Throttled)" -o table > build/tf08_r12.txt
  la "let t = datetime($t24); EvidenceCycle_CL | where StartTime >= t and StartTime < t + 24h
| summarize Planned = 288, Logged = count(), Succeeded = countif(Status == 'Succeeded'), Partial = countif(Status == 'Partial'), Failed = countif(Status == 'Failed')
| extend SuccessPct = round(100.0 * Succeeded / Planned, 1)" -o table > build/tf09_r13.txt
  la "EvidenceCycle_CL | where TimeGenerated > ago(7d)
| summarize Cycles = count(), MissingFields = countif(isnull(StartTime) or isnull(EndTime) or isnull(RecordCount) or isempty(CycleId))" -o table > build/tf06_r8.txt
}

# ---------- 5. TF-02 (R2), TF-07 (R10), K1, K2, R6 resource list ----------
step_collect() {
  local t_start t24 d day args=()
  t_start=$(var T_START); t24=$(var T24)
  d=$(date -u -d "$t_start" +%F)
  while [ "$(date -u -d "$d" +%s)" -le "$(now)" ]; do args+=(--date "$d"); d=$(date -u -d "$d + 1 day" +%F); done
  python3 tools/check_schema.py --account "$ACC" "${args[@]}" > build/tf02_schema.txt 2>&1
  day=$(date -u -d "@$(( $(date -u -d "$t24" +%s) + 43200 ))" +%F)
  la "EvidenceResult_CL | where ControlId == 'A.8.24' and CollectedAt between (datetime($day) .. 1d) | project BlobPath, Sha256" -o json > build/la_hashes.json
  python3 tools/verify_evidence.py --account "$ACC" --control A.8.24 --date "$day" --out build/A.8.24 \
    --la-export build/la_hashes.json > build/tf07_r10.txt 2>&1
  python3 tools/verify_evidence.py --tamper-test build/A.8.24 >> build/tf07_r10.txt 2>&1
  la "EvidenceResult_CL | where TimeGenerated > ago(24h) | summarize Records = count() by ControlId
| summarize ControlsWithEvidence = count(), K1_pct = round(100.0 * count() / 11, 1)" -o table > build/k1_prototype.txt
  for n in 1 2 3; do
    sleep_until $(( ( $(now) / 300 + 1 ) * 300 + 50 ))      # 50 s after the next cycle start
    local cid
    cid=$(az storage blob list --account-name "$ACC" -c evidence --auth-mode login \
          --prefix "A.8.2/$(date -u +%Y/%m/%d)/" --num-results 5000 --query "[-1].name" -o tsv | xargs basename | cut -d_ -f1)
    python3 tools/verify_evidence.py --account "$ACC" --cycle "$cid" --out "build/k2_run$n" > "build/k2_prototype_run$n.txt" 2>&1
  done
  az resource list --query "[?resourceGroup=='$PROTO_RG' || resourceGroup=='$TARGET_RG'].type" -o tsv | sort | uniq -c > build/r6_resources.txt
}

step_defender_off() {
  az security pricing create -n CloudPosture --tier Free -o none &&
  az security pricing show -n CloudPosture --query "{plan:name, tier:pricingTier}" -o table > build/defender_off.txt
}

run_step() {
  local name=$1; shift
  is_done "$name" && return 0
  export RUNNER_STEP="$name"
  log "START $name"; status "RUNNING $name since $(date -u +%FT%TZ)"; heartbeat
  if "$@"; then mark "$name"; else
    log "FAILED $name"; status "FAILED $name at $(date -u +%FT%TZ) – see results/snapshot.tar.gz (build/runner.log)"
    save
    notify FAILED "Klaida žingsnyje $name. Paleiskite tools/runner/fetch_results.sh, atsiųskite build/runner.log pabaigą; po pataisymo – tools/runner/start.sh --resume. DĖMESIO: Defender CSPM gali likti įjungtas."
    exit 1
  fi
}

run_step baseline step_baseline
run_step immutability step_immutability
run_step defender_on step_defender_on
is_done drift_D01 || notify STAGE "Defender vertinimai paruošti; pradedami nukrypimai D01–D11 (~13 val.). Galite atlikti 3 priedo patikrą (fetch_results.sh, build/defender_baseline.txt)."
for d in $DRIFTS; do run_step "drift_$d" run_drift "$d"; done
run_step k3 step_k3
is_done run24 || notify STAGE "Nukrypimų eksperimentas baigtas; pradedamas 24 val. veikimas."
run_step run24 step_run24
run_step collect step_collect
run_step defender_off step_defender_off

tar -czf /tmp/results.tgz build tests/drift/t0.csv
blob upload -n results/results.tar.gz -f /tmp/results.tgz --overwrite
status "DONE at $(date -u +%FT%TZ)"
notify DONE "Visi testai baigti, Defender CSPM išjungtas. Rezultatai: tools/runner/fetch_results.sh"
log "ALL DONE"
