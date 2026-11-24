#!/usr/bin/env bash
# Runs inside the Azure Container Instances container: installs tools, signs in with the
# user-assigned managed identity, downloads the repository and starts run_experiment.sh.
set -euo pipefail
echo "$(date -u +%FT%TZ) boot"
python3 -m pip install -q --upgrade pip
python3 -m pip install -q azure-cli || python3 -m pip install -q --break-system-packages azure-cli
az config set extension.use_dynamic_install=yes_without_prompt core.only_show_errors=true -o none
for i in $(seq 1 20); do az login --identity --client-id "$AZURE_CLIENT_ID" -o none && break; sleep 15; done
az account set -s "$SUB"
for i in $(seq 1 20); do
  az storage blob download --account-name "$RUNNER_ACCOUNT" -c runner -n "${REPO_BLOB:-repo.tar.gz}" -f /tmp/repo.tgz \
    --auth-mode login -o none && break
  sleep 30
done
mkdir -p /work && tar -xzf /tmp/repo.tgz -C /work
cd "/work/$(ls /work | head -1)"
python3 -m pip install -q -r src/requirements.txt || python3 -m pip install -q --break-system-packages -r src/requirements.txt
az extension add -n resource-graph -o none || true
exec bash "tools/runner/${RUNNER_SCRIPT:-run_experiment.sh}"
