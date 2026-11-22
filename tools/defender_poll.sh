#!/usr/bin/env bash
# K3 for Defender for Cloud: polls assessment status of rg-iso-target resources every 5 min for 1 h.
# Usage: tools/defender_poll.sh D02 > build/defender_D02.csv     (needs: az extension add -n resource-graph)
set -euo pipefail
ID="${1:?D01..D11}"
Q="securityresources | where type == 'microsoft.security/assessments' | where id contains '/resourceGroups/rg-iso-target/' | project name = tostring(properties.displayName), resourceId = tostring(properties.resourceDetails.Id), status = tostring(properties.status.code), statusChangeDate = tostring(properties.status.statusChangeDate)"
echo "scenario,polledAt,name,resourceId,status,statusChangeDate"
for i in $(seq 0 12); do
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  az graph query -q "$Q" --first 1000 --query "data[].[name,resourceId,status,statusChangeDate]" -o tsv \
    | while IFS=$'\t' read -r n r s c; do echo "$ID,$NOW,\"$n\",$r,$s,$c"; done
  [ "$i" -lt 12 ] && sleep 300
done
