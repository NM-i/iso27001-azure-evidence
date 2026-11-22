#!/usr/bin/env bash
# TS-01..TS-03 (R3): tries to overwrite and delete 3 random evidence blobs in YOUR OWN storage account.
# A temporary 'Storage Blob Data Contributor' role is granted so that a failure proves immutability,
# not missing permissions. The role is removed at the end.
set -euo pipefail
PROTO_RG="rg-iso-proto"
ACC=$(az deployment group show -g "$PROTO_RG" -n main --query properties.outputs.evidenceAccountName.value -o tsv)
if [ "${RUNNER_MODE:-0}" != "1" ]; then
  # Interactive use: grant the signed-in user write access for the duration of the test.
  ME=$(az ad signed-in-user show --query id -o tsv)
  SCOPE=$(az storage account show -n "$ACC" --query id -o tsv)/blobServices/default/containers/evidence
  az role assignment create --assignee-object-id "$ME" --assignee-principal-type User \
    --role "Storage Blob Data Contributor" --scope "$SCOPE" -o none
  trap 'az role assignment delete --assignee "$ME" --role "Storage Blob Data Contributor" --scope "$SCOPE" -o none' EXIT
  echo "Waiting 60 s for role propagation..."; sleep 60
fi
# In RUNNER_MODE the runner identity already has 'Storage Blob Data Contributor' on the container (tools/runner/start.sh).

mapfile -t BLOBS < <(az storage blob list --account-name "$ACC" -c evidence --auth-mode login \
  --num-results 2000 --query "[].name" -o tsv | shuf -n 3)
mkdir -p build/immut
for b in "${BLOBS[@]}"; do
  f="build/immut/$(echo "$b" | tr '/' '_')"
  az storage blob download --account-name "$ACC" -c evidence -n "$b" -f "$f" --auth-mode login -o none
  echo '{"tampered":true}' > build/immut/tamper.json
  echo "== TS-01 overwrite $b"
  az storage blob upload --account-name "$ACC" -c evidence -n "$b" -f build/immut/tamper.json \
    --overwrite --auth-mode login -o none 2>&1 | tail -1 || true
  echo "== TS-02 delete $b"
  az storage blob delete --account-name "$ACC" -c evidence -n "$b" --auth-mode login -o none 2>&1 | tail -1 || true
done
echo "Expected for every attempt: an error mentioning immutability (HTTP 409). Any success = NEATITINKA."
echo "== TS-03 hashes after the attempts"
python3 tools/verify_evidence.py --account "$ACC" --names "${BLOBS[@]}"
