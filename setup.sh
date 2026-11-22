#!/usr/bin/env bash
# ONE COMMAND for steps 3–9: providers, unit tests, optional GitHub upload, deployment (R15),
# waiting for the first successful cycle and starting the test runner.
#   bash setup.sh vardas.pavarde@stud.kauko.lt
# Safe to run again after a Cloud Shell disconnect: finished parts are skipped (build/setup_done.txt).
set -euo pipefail
EMAIL="${1:?Usage: bash setup.sh <alert-email>}"
cd "$(dirname "$0")"
chmod +x deploy.sh tools/*.sh tools/runner/*.sh tests/drift/*.sh
mkdir -p build
DONE=build/setup_done.txt; touch "$DONE"
done_() { grep -qx "$1" "$DONE"; }
mark()  { echo "$1" >> "$DONE"; }
echo "Tip: Cloud Shell disconnects after ~20 min without typing. If that happens, open it again and run the same command."

if ! done_ providers; then
  echo "[1/5] Registering resource providers"
  PROVIDERS="Microsoft.Web Microsoft.Storage Microsoft.Insights Microsoft.OperationalInsights Microsoft.KeyVault Microsoft.Network Microsoft.ManagedIdentity Microsoft.Consumption Microsoft.Security Microsoft.ContainerInstance"
  for p in $PROVIDERS; do az provider register -n "$p" -o none; done
  for i in $(seq 1 30); do
    pending=$(for p in $PROVIDERS; do s=$(az provider show -n "$p" --query registrationState -o tsv); [ "$s" = "Registered" ] || echo "$p"; done)
    [ -z "$pending" ] && break; echo "  waiting for: $(echo $pending)"; sleep 20
  done
  az extension add -n resource-graph -o none 2>/dev/null || true
  mark providers
fi

if ! done_ tests; then
  echo "[2/5] Local unit tests"
  pip install --user -q -r src/requirements.txt pytest
  python3 -m pytest -q tests/unit | tee build/unit_tests.txt
  mark tests
fi

if ! done_ github; then
  echo "[3/5] GitHub"
  read -r -p "Upload the code to a new public GitHub repository now? (t/n): " a
  if [ "$a" = "t" ]; then tools/github_push.sh || echo "GitHub upload failed – you can run tools/github_push.sh later."; fi
  mark github
fi

if ! done_ deploy; then
  echo "[4/5] Deployment (TF-11)"
  ./deploy.sh "$EMAIL" | tee build/tf11_deploy.txt
  mark deploy
fi

if ! done_ runner; then
  echo "[5/5] Waiting for the first successful collection cycle (up to 45 min)"
  WS=$(az deployment group show -g rg-iso-proto -n main --query properties.outputs.workspaceCustomerId.value -o tsv)
  ok=0
  for i in $(seq 1 45); do
    n=$(az monitor log-analytics query -w "$WS" --analytics-query "EvidenceCycle_CL | where Status == 'Succeeded' | count" \
        --query "[0].Count" -o tsv 2>/dev/null || echo 0)
    if [ "${n:-0}" -ge 1 ]; then ok=1; break; fi
    echo "  $(date -u +%H:%M:%S) no successful cycle yet"; sleep 60
  done
  if [ "$ok" != "1" ]; then
    echo "No successful cycle within 45 min. Last cycles:"
    az monitor log-analytics query -w "$WS" -o table --analytics-query \
      "EvidenceCycle_CL | order by StartTime desc | take 5 | project StartTime, Status, Error" || true
    echo "Send this output for analysis. Nothing irreversible has been done yet."
    exit 1
  fi
  echo "Prototype works. Starting the test runner (you will be asked to type LOCK)."
  tools/runner/start.sh
  mark runner
fi
echo "Setup finished. The runner will e-mail $EMAIL. Status at any time: tools/runner/status.sh"
