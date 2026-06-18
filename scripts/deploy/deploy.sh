#!/usr/bin/env bash
# Deploy the AVD Landing Zone baseline with az.
# Usage: ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -g rg-avd-lz-dev -l eastus2
set -euo pipefail

PARAM_FILE=""
RESOURCE_GROUP=""
LOCATION=""
WHATIF=false

usage() {
  echo "Usage: $0 -p <bicepparam> -g <resource-group> -l <location> [--what-if]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PARAM_FILE="$2"; shift 2 ;;
    -g) RESOURCE_GROUP="$2"; shift 2 ;;
    -l) LOCATION="$2"; shift 2 ;;
    --what-if) WHATIF=true; shift ;;
    *) usage ;;
  esac
done

[[ -z "$PARAM_FILE" || -z "$RESOURCE_GROUP" || -z "$LOCATION" ]] && usage
[[ ! -f "$PARAM_FILE" ]] && { echo "Parameter file not found: $PARAM_FILE"; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATE="$ROOT/bicep/main.bicep"

echo "==> Verifying az + bicep"
az bicep version >/dev/null || { echo "Install bicep: az bicep install"; exit 1; }

echo "==> Confirming you're logged in"
az account show --query "{subscription:name, id:id}" -o jsonc >/dev/null 2>&1 || { echo "Run 'az login' and 'az account set --subscription <id>' first."; exit 1; }

# Register the resource providers an AVD landing zone needs. On a brand-new
# (e.g. personal) subscription these are not registered, and the deployment
# fails with a cryptic error if you skip this. Registration is idempotent.
echo "==> Registering resource providers (idempotent; first run can take a few minutes)"
for ns in Microsoft.DesktopVirtualization Microsoft.Compute Microsoft.Storage Microsoft.Network Microsoft.Insights; do
  state=$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo "NotRegistered")
  if [[ "$state" != "Registered" ]]; then
    echo "    registering $ns ..."
    az provider register -n "$ns" >/dev/null
  fi
done

echo "==> Ensuring resource group $RESOURCE_GROUP exists in $LOCATION"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --only-show-errors >/dev/null

# If the param file has an empty desktopUserObjectIds, grant the desktop to the
# signed-in user so a personal-sub demo "just works" without creating a group.
EXTRA_PARAMS=()
if grep -qE "param desktopUserObjectIds = \[\s*\]" "$PARAM_FILE" || grep -qzE "desktopUserObjectIds = \[\s*(//[^]]*)?\]" "$PARAM_FILE"; then
  MY_OID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
  if [[ -n "$MY_OID" ]]; then
    echo "==> No desktop users set; granting the desktop to you ($MY_OID)"
    EXTRA_PARAMS+=(--parameters "desktopUserObjectIds=[\"$MY_OID\"]")
  fi
fi

# Prompt for admin password if the param file left it empty (never commit secrets).
if grep -qE "param adminPassword = ''" "$PARAM_FILE"; then
  read -r -s -p "Session host admin password: " ADMIN_PW; echo
  EXTRA_PARAMS+=(--parameters "adminPassword=$ADMIN_PW")
fi

DEPLOY_NAME="avd-lz-$(date +%Y%m%d-%H%M%S)"

if $WHATIF; then
  echo "==> Running what-if (no changes applied)"
  az deployment group what-if \
    -g "$RESOURCE_GROUP" -n "$DEPLOY_NAME" \
    -f "$TEMPLATE" -p "$PARAM_FILE" "${EXTRA_PARAMS[@]}"
  exit 0
fi

echo "==> Deploying ($DEPLOY_NAME)"
az deployment group create \
  -g "$RESOURCE_GROUP" -n "$DEPLOY_NAME" \
  -f "$TEMPLATE" -p "$PARAM_FILE" "${EXTRA_PARAMS[@]}" \
  --query "properties.outputs" -o jsonc

echo ""
echo "==> Infrastructure deployed."
echo "    Next: post-deploy config"
echo "      pwsh ./scripts/config/Configure-FSLogix.ps1 -ResourceGroup $RESOURCE_GROUP"
echo "      pwsh ./scripts/config/Register-SessionHosts.ps1 -ResourceGroup $RESOURCE_GROUP"
