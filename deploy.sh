#!/usr/bin/env bash
# R15: creates the whole environment in empty resource groups with one command and prints the duration.
# Usage: ./deploy.sh <alert-email>      (requires: az login, Owner on the subscription)
set -euo pipefail

ALERT_EMAIL="${1:?Usage: ./deploy.sh <alert-email>}"
LOCATION="germanywestcentral"            # T2
PROTO_RG="rg-iso-proto"
TARGET_RG="rg-iso-target"
START_EPOCH=$(date -u +%s)
echo "Start: $(date -u +%Y-%m-%dT%H:%M:%SZ)"

ADMIN_OID=$(az ad signed-in-user show --query id -o tsv)
OWNER_TAG=$(az ad signed-in-user show --query userPrincipalName -o tsv)
BUDGET_START=$(date -u +%Y-%m-01)

az group create -n "$TARGET_RG" -l "$LOCATION" -o none
az group create -n "$PROTO_RG"  -l "$LOCATION" -o none

echo "[1/3] Monitored test resources"
az deployment group create -g "$TARGET_RG" -n target -f infra/target.bicep \
  -p location="$LOCATION" ownerTag="$OWNER_TAG" -o none

echo "[2/3] Prototype resources"
az deployment group create -g "$PROTO_RG" -n main -f infra/main.bicep \
  -p location="$LOCATION" targetResourceGroup="$TARGET_RG" alertEmail="$ALERT_EMAIL" \
     adminPrincipalId="$ADMIN_OID" budgetStartDate="$BUDGET_START" -o none

APP=$(az deployment group show -g "$PROTO_RG" -n main --query properties.outputs.functionAppName.value -o tsv)

echo "[3/3] Function code -> $APP"
mkdir -p build && rm -f build/app.zip
(cd src && zip -qr ../build/app.zip . -x "__pycache__/*" ".venv/*" "local.settings.json")
az functionapp deployment source config-zip -g "$PROTO_RG" -n "$APP" --src build/app.zip --build-remote true -o none

END_EPOCH=$(date -u +%s)
echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "R15 duration: $(( (END_EPOCH - START_EPOCH) / 60 )) min $(( (END_EPOCH - START_EPOCH) % 60 )) s"
echo "Next: lock immutability before the experiment -> tools/lock_immutability.sh (irreversible, see docs/ADMIN.md)"
