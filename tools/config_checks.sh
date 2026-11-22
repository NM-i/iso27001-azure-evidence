#!/usr/bin/env bash
# Security checklist TS-04..TS-08 (R3, R9, R11) and resource list for R6. Read-only.
set -euo pipefail
PROTO_RG="rg-iso-proto"; TARGET_RG="rg-iso-target"
out() { az deployment group show -g "$PROTO_RG" -n main --query "properties.outputs.$1.value" -o tsv; }
ACC=$(out evidenceAccountName); APP=$(out functionAppName)
PID=$(az functionapp identity show -g "$PROTO_RG" -n "$APP" --query principalId -o tsv)
HOSTACC=$(az storage account list -g "$PROTO_RG" --query "[?starts_with(name,'stfunc')].name | [0]" -o tsv)

echo "== TS-04 immutability policy (expect: Locked, 7)"
az storage container immutability-policy show -g "$PROTO_RG" --account-name "$ACC" -c evidence \
  --query "{state:state, days:immutabilityPeriodSinceCreationInDays}" -o table

echo "== TS-05 role assignments of the function identity (expect: no Owner/Contributor)"
az role assignment list --assignee "$PID" --all --query "[].{role:roleDefinitionName, scope:scope}" -o table

echo "== TS-06 app settings that look like secrets (expect: none)"
az functionapp config appsettings list -g "$PROTO_RG" -n "$APP" \
  --query "[?contains(value,'AccountKey') || contains(value,'SharedAccessSignature') || contains(name,'PASSWORD') || contains(name,'KEY')].name" -o tsv
grep -rnE "AccountKey|SharedAccessSignature|password" src/ || echo "source: none found"

echo "== TS-07 shared key access (expect: false for both)"
for a in "$ACC" "$HOSTACC"; do
  az storage account show -n "$a" --query "{account:name, allowSharedKeyAccess:allowSharedKeyAccess}" -o table
done

echo "== TS-08 transport (expect: TLS1_2, true)"
az storage account show -n "$ACC" --query "{minimumTlsVersion:minimumTlsVersion, httpsOnly:enableHttpsTrafficOnly}" -o table

echo "== R6 resource types (expect: only Microsoft.* Azure services)"
az resource list --query "[?resourceGroup=='$PROTO_RG' || resourceGroup=='$TARGET_RG'].type" -o tsv | sort | uniq -c
