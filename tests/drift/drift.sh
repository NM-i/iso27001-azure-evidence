#!/usr/bin/env bash
# Drift scenarios D01–D11 (R7, K3). Changes ONLY resources in rg-iso-target of YOUR OWN subscription.
# Usage: tests/drift/drift.sh apply D02 | tests/drift/drift.sh restore D02
# t0 = UTC time when the Azure CLI command returned successfully; appended to tests/drift/t0.csv.
# D08 opens an NSG rule on a network with no virtual machines attached, so nothing becomes reachable.
set -euo pipefail
ACTION="${1:?apply|restore}"; ID="${2:?D01..D11}"
RG="rg-iso-target"
CSV="$(dirname "$0")/t0.csv"
[ -f "$CSV" ] || echo "id,action,utc" > "$CSV"
o() { az deployment group show -g "$RG" -n target --query "properties.outputs.$1.value" -o tsv; }
ST=$(o storageName); KV=$(o keyVaultName); LAW=$(o workspaceName); NSG_ID=$(o nsgId)
UAMI_PID=$(o driftIdentityPrincipalId)
OWNER=$(az storage account show -n "$ST" -g "$RG" --query "tags.owner" -o tsv)   # storage tags are not changed by D04
RG_ID=$(az group show -n "$RG" --query id -o tsv)
KV2="kv-d05-$(echo "$RG_ID" | sha1sum | cut -c1-8)"
LOC=$(az group show -n "$RG" --query location -o tsv)

case "$ID:$ACTION" in
  D01:apply)   az role assignment create --assignee-object-id "$UAMI_PID" --assignee-principal-type ServicePrincipal --role Owner --scope "$RG_ID" -o none ;;
  D01:restore) for id in $(az role assignment list --scope "$RG_ID" --role Owner --fill-principal-name false \
                   --query "[?principalId=='$UAMI_PID'].id" -o tsv); do az role assignment delete --ids "$id" -o none; done ;;
  D02:apply)   az storage account update -n "$ST" -g "$RG" --allow-blob-public-access true -o none ;;
  D02:restore) az storage account update -n "$ST" -g "$RG" --allow-blob-public-access false -o none ;;
  D03:apply)   az storage account update -n "$ST" -g "$RG" --allow-shared-key-access true -o none ;;
  D03:restore) az storage account update -n "$ST" -g "$RG" --allow-shared-key-access false -o none ;;
  D04:apply)   az tag update --resource-id "$NSG_ID" --operation Delete --tags owner="$OWNER" -o none ;;
  D04:restore) az tag update --resource-id "$NSG_ID" --operation Merge --tags owner="$OWNER" -o none ;;
  D05:apply)   az keyvault create -n "$KV2" -g "$RG" -l "$LOC" --retention-days 7 --enable-rbac-authorization true \
                 --default-action Deny --public-network-access Disabled \
                 --tags owner="$OWNER" environment=test -o none ;;   # no purge protection = drift
  D05:restore) az keyvault delete -n "$KV2" -g "$RG" -o none ;;
  D06:apply)   az monitor log-analytics workspace update -g "$RG" -n "$LAW" --retention-time 30 -o none ;;
  D06:restore) az monitor log-analytics workspace update -g "$RG" -n "$LAW" --retention-time 90 -o none ;;
  D07:apply)   az monitor activity-log alert update -g "$RG" -n ala-nsg-write --enabled false -o none ;;
  D07:restore) az monitor activity-log alert update -g "$RG" -n ala-nsg-write --enabled true -o none ;;
  D08:apply)   az network nsg rule create -g "$RG" --nsg-name nsg-app -n d08-rdp-from-internet --priority 100 \
                 --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet \
                 --destination-port-ranges 3389 -o none ;;
  D08:restore) az network nsg rule delete -g "$RG" --nsg-name nsg-app -n d08-rdp-from-internet -o none ;;
  D09:apply)   az keyvault update -n "$KV" -g "$RG" --public-network-access Enabled --default-action Allow -o none ;;
  D09:restore) az keyvault update -n "$KV" -g "$RG" --public-network-access Disabled --default-action Deny -o none ;;
  D10:apply)   az network vnet subnet update -g "$RG" --vnet-name vnet-tgt -n snet-app --remove networkSecurityGroup -o none ;;
  D10:restore) az network vnet subnet update -g "$RG" --vnet-name vnet-tgt -n snet-app --network-security-group nsg-app -o none ;;
  D11:apply)   az storage account update -n "$ST" -g "$RG" --https-only false -o none ;;
  D11:restore) az storage account update -n "$ST" -g "$RG" --https-only true -o none ;;
  *) echo "Unknown: $ID $ACTION"; exit 2 ;;
esac
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "$ID,$ACTION,$NOW" >> "$CSV"
echo "$ID $ACTION done at $NOW"
