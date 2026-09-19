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
    # That OID is a User, not a Group. Role assignments are validated against
    # the principal type, so it has to be declared correctly.
    EXTRA_PARAMS+=(--parameters "desktopUserPrincipalType=User")
  fi
fi

# The scaling plan runs as the "Azure Virtual Desktop" service principal, which
# needs Power On Off Contributor over the session hosts. The app ID is the same
# in every tenant; the OBJECT id is not, so resolve it here. Without this the
# scaling plan deploys and reports healthy but never starts or stops a host.
AVD_SP_APP_ID="9cdead84-a844-4324-93f2-b2e6bb768d07"
AVD_SP_OID=$(az ad sp show --id "$AVD_SP_APP_ID" --query id -o tsv 2>/dev/null || true)
if [[ -n "$AVD_SP_OID" ]]; then
  echo "==> Azure Virtual Desktop service principal: $AVD_SP_OID"
  EXTRA_PARAMS+=(--parameters "avdServicePrincipalObjectId=$AVD_SP_OID")
else
  echo "WARNING: could not resolve the Azure Virtual Desktop service principal."
  echo "         The scaling plan will deploy but will not start/stop hosts."
  echo "         Fix: az ad sp create --id $AVD_SP_APP_ID   (then re-run)"
fi

# Budget alerts need somewhere to land. If the param file leaves costAlertEmails
# empty, fall back to the signed-in user's address.
if grep -qzE "costAlertEmails = \[\s*(//[^]]*)?\]" "$PARAM_FILE"; then
  MY_MAIL=$(az ad signed-in-user show --query mail -o tsv 2>/dev/null || true)
  if [[ -z "$MY_MAIL" || "$MY_MAIL" == "null" ]]; then
    # No mail attribute. The UPN is the fallback, but on a personal subscription
    # backed by a Microsoft account the UPN is often something like
    # you_gmail.com#EXT#@yourtenant.onmicrosoft.com, which DOES NOT receive mail.
    MY_MAIL=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || true)
    if [[ "$MY_MAIL" == *"#EXT#"* ]]; then
      echo "WARNING: your account has no mail attribute and its UPN ($MY_MAIL)"
      echo "         is not a deliverable address. Budget alerts would go nowhere."
      echo "         Set costAlertEmails in $PARAM_FILE to a real inbox."
      MY_MAIL=""
    fi
  fi
  if [[ -n "$MY_MAIL" ]]; then
    echo "==> Budget alerts will go to $MY_MAIL"
    EXTRA_PARAMS+=(--parameters "costAlertEmails=[\"$MY_MAIL\"]")
  else
    echo "WARNING: no cost alert address, so the budget and kill switch are SKIPPED."
    echo "         Auto-shutdown on the session hosts still applies."
    echo "         Set costAlertEmails in $PARAM_FILE and re-run to enable them."
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
echo ""
echo "    THIS IS NOW COSTING YOU MONEY. To stop it:"
echo "      ./scripts/ops/stop-lab.sh -g $RESOURCE_GROUP            # stop, reversible"
echo "      ./scripts/ops/stop-lab.sh -g $RESOURCE_GROUP --delete   # remove everything"
echo "    Azure has no hard spending cap - see docs/cost-controls.md."
