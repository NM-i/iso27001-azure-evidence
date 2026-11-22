#!/usr/bin/env bash
# R3/T7: locks the time-based retention policy. IRREVERSIBLE: the period can only be extended,
# and the storage account cannot be deleted while protected blobs exist.
set -euo pipefail
PROTO_RG="rg-iso-proto"
ACC=$(az deployment group show -g "$PROTO_RG" -n main --query properties.outputs.evidenceAccountName.value -o tsv)
az storage container immutability-policy show -g "$PROTO_RG" --account-name "$ACC" -c evidence -o table
read -r -p "Lock policy on $ACC/evidence? Type LOCK to continue: " ans
[ "$ans" = "LOCK" ] || { echo "Cancelled"; exit 1; }
ETAG=$(az storage container immutability-policy show -g "$PROTO_RG" --account-name "$ACC" -c evidence --query etag -o tsv)
az storage container immutability-policy lock -g "$PROTO_RG" --account-name "$ACC" -c evidence --if-match "$ETAG" -o table
