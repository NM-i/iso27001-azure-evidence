#!/usr/bin/env bash
# Shows the runner state, the current step and the last log lines.
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/runner/common.sh
az container show -g "$RUN_RG" -n "$ACI" \
  --query "{state:instanceView.state, started:containers[0].instanceView.currentState.startTime, exitCode:containers[0].instanceView.currentState.exitCode}" -o table
az storage blob download --account-name "$RACC" -c runner -n results/STATUS.txt -f /tmp/STATUS.txt \
  --auth-mode login -o none 2>/dev/null && { echo; cat /tmp/STATUS.txt; }
echo; echo "--- last log lines ---"
az container logs -g "$RUN_RG" -n "$ACI" 2>/dev/null | tail -15
