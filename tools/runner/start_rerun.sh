#!/usr/bin/env bash
# Starts a second, small container that waits for the main runner to finish and then repeats
# D02, D03 and D05 for the Defender for Cloud comparison. Run once from the repository folder.
#   tools/runner/start_rerun.sh            (safe to run while the main runner is still working)
set -euo pipefail
cd "$(dirname "$0")/../.."
source tools/runner/common.sh
RERUN_ACI="aci-iso-rerun"
echo "[1/2] Uploading the current code as repo_rerun.tar.gz"
tar -czf /tmp/repo_rerun.tgz --exclude="*/build/*" --exclude="*/.git" --exclude="*/results_*" -C .. "$(basename "$PWD")"
az storage blob upload --account-name "$RACC" -c runner -n repo_rerun.tar.gz -f /tmp/repo_rerun.tgz --overwrite --auth-mode login -o none
echo "[2/2] Starting container $RERUN_ACI"
az container delete -g "$RUN_RG" -n "$RERUN_ACI" --yes -o none 2>/dev/null || true
UAMI_ID=$(az identity show -n "$UAMI" -g "$RUN_RG" --query id -o tsv)
CLIENT=$(az identity show -n "$UAMI" -g "$RUN_RG" --query clientId -o tsv)
BOOT=$(base64 -w0 tools/runner/boot.sh)
az container create -g "$RUN_RG" -n "$RERUN_ACI" -l "$LOCATION" --os-type Linux \
  --image mcr.microsoft.com/devcontainers/python:1-3.11-bookworm --cpu 0.5 --memory 1 \
  --restart-policy Never --assign-identity "$UAMI_ID" \
  --environment-variables AZURE_CLIENT_ID="$CLIENT" RUNNER_ACCOUNT="$RACC" SUB="$SUB" BOOT_B64="$BOOT" \
     REPO_BLOB=repo_rerun.tar.gz RUNNER_SCRIPT=run_rerun.sh \
     DCE_ENDPOINT="$(out dceEndpoint)" DCR_IMMUTABLE_ID="$(out dcrImmutableId)" \
  --command-line "/bin/bash -c 'echo \$BOOT_B64 | base64 -d > /tmp/boot.sh && bash /tmp/boot.sh'" -o none
echo "Started at $(date -u +%FT%TZ). It waits for the main runner's DONE, then needs ~3.5 h."
echo "Status: tools/runner/status.sh --rerun"
