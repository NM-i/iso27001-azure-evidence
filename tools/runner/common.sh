# Shared settings for the runner helper scripts (sourced, not executed).
LOCATION="germanywestcentral"
PROTO_RG="rg-iso-proto"; TARGET_RG="rg-iso-target"; RUN_RG="rg-iso-runner"
ACI="aci-iso-runner"; UAMI="id-iso-runner"
SUB=$(az account show --query id -o tsv)
RACC="strun$(echo "$SUB" | sha1sum | cut -c1-12)"
out() { az deployment group show -g "$PROTO_RG" -n main --query "properties.outputs.$1.value" -o tsv; }
