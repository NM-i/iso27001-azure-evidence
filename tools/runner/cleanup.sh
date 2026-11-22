#!/usr/bin/env bash
# Stage 6: makes sure Defender CSPM is off, stops the prototype and deletes the runner and target groups.
# rg-iso-proto can be deleted only after the 7-day immutability period (see docs/ADMIN.md).
set -uo pipefail
cd "$(dirname "$0")/../.."
source tools/runner/common.sh
tier=$(az security pricing show -n CloudPosture --query pricingTier -o tsv)
[ "$tier" = "Free" ] || az security pricing create -n CloudPosture --tier Free -o none
az security pricing show -n CloudPosture --query "{plan:name, tier:pricingTier}" -o table
az functionapp stop -g "$PROTO_RG" -n "$(out functionAppName)"
# stop runner e-mails (the stale-runner reminder would otherwise repeat after a failed run)
DCE_ENDPOINT="$(out dceEndpoint)" DCR_IMMUTABLE_ID="$(out dcrImmutableId)" python3 tools/runner/notify.py CANCELLED "cleanup.sh"
for r in sqr-runner-event sqr-runner-stale; do
  az resource update -g "$PROTO_RG" -n "$r" --resource-type Microsoft.Insights/scheduledQueryRules \
    --set properties.enabled=false -o none || true
done
read -r -p "Results downloaded (tools/runner/fetch_results.sh)? Type DELETE to remove $RUN_RG and $TARGET_RG: " a
[ "$a" = "DELETE" ] || { echo "Cancelled"; exit 1; }
az group delete -n "$RUN_RG" --yes --no-wait
az group delete -n "$TARGET_RG" --yes --no-wait
echo "After 7 days: az group delete -n $PROTO_RG --yes && az consumption budget delete --budget-name budget-iso-evidence"
