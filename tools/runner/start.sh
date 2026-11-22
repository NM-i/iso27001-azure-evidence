#!/usr/bin/env bash
# Starts the automatic test runner (stages 1–5 of the test plan) in Azure Container Instances.
# Run from the repository folder in Cloud Shell, at least 15 min after ./deploy.sh.
#   tools/runner/start.sh            first start (locks immutability – IRREVERSIBLE)
#   tools/runner/start.sh --resume   restart after a failure; continues from the last finished step
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/runner/common.sh
RESUME=0; [ "${1:-}" = "--resume" ] && RESUME=1
ACC=$(out evidenceAccountName); WS=$(out workspaceCustomerId)
ME=$(az ad signed-in-user show --query id -o tsv)
mkdir -p build

if [ "$RESUME" = "0" ]; then
  echo "[1/6] Checking that the prototype works"
  n=$(az monitor log-analytics query -w "$WS" --analytics-query "EvidenceCycle_CL | where Status == 'Succeeded' | count" \
      --query "[0].Count" -o tsv 2>/dev/null || echo 0)
  [ "${n:-0}" -ge 1 ] || { echo "No successful cycle yet. Wait 15 min after deploy.sh and try again."; exit 1; }

  echo "[2/6] Locking immutability (R3, TS-04) – irreversible"
  tools/lock_immutability.sh
  echo "[3/6] Configuration checks TS-04..TS-08 with your identity"
  tools/config_checks.sh | tee build/config_checks.txt

  echo "[4/6] Runner resources in $RUN_RG"
  az group create -n "$RUN_RG" -l "$LOCATION" -o none
  az storage account create -n "$RACC" -g "$RUN_RG" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
    --min-tls-version TLS1_2 --https-only true --allow-blob-public-access false --allow-shared-key-access false -o none
  az storage container-rm create --storage-account "$RACC" -g "$RUN_RG" -n runner -o none
  az identity create -n "$UAMI" -g "$RUN_RG" -l "$LOCATION" -o none
  PID=$(az identity show -n "$UAMI" -g "$RUN_RG" --query principalId -o tsv)
  RACC_ID=$(az storage account show -n "$RACC" -g "$RUN_RG" --query id -o tsv)
  EVID_SCOPE="$(az storage account show -n "$ACC" -g "$PROTO_RG" --query id -o tsv)/blobServices/default/containers/evidence"
  grant() { az role assignment create --assignee-object-id "$1" --assignee-principal-type "$2" --role "$3" --scope "$4" -o none; }
  sleep 30   # identity replication
  grant "$PID" ServicePrincipal "Owner"                          "$(az group show -n "$TARGET_RG" --query id -o tsv)"  # drift scenarios, incl. D01
  grant "$PID" ServicePrincipal "Reader"                         "/subscriptions/$SUB"   # ARG, logs, alerts, deployment outputs
  grant "$PID" ServicePrincipal "Security Admin"                 "/subscriptions/$SUB"   # Defender CSPM on/off
  grant "$PID" ServicePrincipal "Storage Blob Data Contributor"  "$EVID_SCOPE"           # TS-01..TS-03, R10, R2, K2
  grant "$PID" ServicePrincipal "Storage Blob Data Contributor"  "$RACC_ID"              # code and results
  grant "$PID" ServicePrincipal "Monitoring Metrics Publisher"   "$(out dcrId)"          # e-mail notifications
  grant "$ME"  User             "Storage Blob Data Contributor"  "$RACC_ID"              # you: upload code, download results
  grant "$ME"  User             "Monitoring Metrics Publisher"   "$(out dcrId)"          # LAUNCHED / CANCELLED events
  echo "Waiting 90 s for role propagation..."; sleep 90
fi

echo "[5/6] Uploading the repository"
tar -czf /tmp/repo.tgz --exclude="*/build/A.8.*" --exclude="*/build/k2_run*" --exclude="*/.git" --exclude="*/results_*" -C .. "$(basename "$PWD")"
for i in $(seq 1 10); do
  az storage blob upload --account-name "$RACC" -c runner -n repo.tar.gz -f /tmp/repo.tgz --overwrite \
    --auth-mode login -o none && break
  echo "retrying upload in 30 s"; sleep 30
done

echo "[6/6] Starting container $ACI"
az container delete -g "$RUN_RG" -n "$ACI" --yes -o none 2>/dev/null || true
UAMI_ID=$(az identity show -n "$UAMI" -g "$RUN_RG" --query id -o tsv)
CLIENT=$(az identity show -n "$UAMI" -g "$RUN_RG" --query clientId -o tsv)
BOOT=$(base64 -w0 tools/runner/boot.sh)
az container create -g "$RUN_RG" -n "$ACI" -l "$LOCATION" --os-type Linux \
  --image mcr.microsoft.com/devcontainers/python:1-3.11-bookworm --cpu 1 --memory 1.5 \
  --restart-policy Never --assign-identity "$UAMI_ID" \
  --environment-variables AZURE_CLIENT_ID="$CLIENT" RUNNER_ACCOUNT="$RACC" SUB="$SUB" BOOT_B64="$BOOT" \
     DCE_ENDPOINT="$(out dceEndpoint)" DCR_IMMUTABLE_ID="$(out dcrImmutableId)" \
  --command-line "/bin/bash -c 'echo \$BOOT_B64 | base64 -d > /tmp/boot.sh && bash /tmp/boot.sh'" -o none
DCE_ENDPOINT="$(out dceEndpoint)" DCR_IMMUTABLE_ID="$(out dcrImmutableId)" \
  python3 tools/runner/notify.py LAUNCHED "Vykdytojas paleistas $(date -u +%FT%TZ); pirmas laiškas STARTED turėtų ateiti per ~20 min."
echo
echo "Runner started at $(date -u +%FT%TZ). Expected duration: about 2 days."
echo "E-mails will arrive at the alert address: STARTED, stage changes, FAILED or DONE."
echo "If nothing is heard for 3 h, an hourly reminder is sent."
echo "Check progress any time:  tools/runner/status.sh"
echo "When STATUS is DONE:      tools/runner/fetch_results.sh"
