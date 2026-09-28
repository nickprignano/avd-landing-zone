#!/usr/bin/env bash
# Deploy the cloud-native AVD landing zone at subscription scope.
#
# Usage:
#   ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus \
#       --users-group "AVD Users" --admins-group "AVD Admins" [--what-if]
#
# -l is the region the landing zone is deployed to (it sets AVD_LOCATION, which
# the parameter files read).
#
# Environment variables (any flag above overrides):
#   AVD_USERS_GROUP_ID, AVD_ADMINS_GROUP_ID   Entra group object IDs
#   AVD_LOCAL_ADMIN_PASSWORD                  break-glass password (random if unset)
#   AVD_SERVICE_PRINCIPAL_ID                  looked up if unset (CI sets it to avoid Graph reads)
#   AVD_ALERT_EMAIL, AVD_MONTHLY_BUDGET       optional
set -euo pipefail

PARAM_FILE=""
LOCATION=""
USERS_GROUP=""
ADMINS_GROUP=""
WHATIF=false
AVD_APP_ID="9cdead84-a844-4324-93f2-b2e6bb768d07"   # Azure Virtual Desktop first-party app

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p) PARAM_FILE="$2"; shift 2 ;;
    -l) LOCATION="$2"; shift 2 ;;
    --users-group) USERS_GROUP="$2"; shift 2 ;;
    --admins-group) ADMINS_GROUP="$2"; shift 2 ;;
    --what-if) WHATIF=true; shift ;;
    *) usage ;;
  esac
done

[[ -z "$PARAM_FILE" || -z "$LOCATION" ]] && usage
[[ ! -f "$PARAM_FILE" ]] && { echo "Parameter file not found: $PARAM_FILE"; exit 1; }

echo "==> Checking az and Bicep"
az bicep version >/dev/null 2>&1 || az bicep install
az account show >/dev/null 2>&1 || { echo "Run 'az login' and 'az account set --subscription <id>' first."; exit 1; }
SUB_NAME=$(az account show --query name -o tsv)
echo "    Subscription: $SUB_NAME"

# --- Resource providers + features (idempotent; a fresh subscription has none) ---
echo "==> Registering resource providers"
for ns in Microsoft.DesktopVirtualization Microsoft.Compute Microsoft.Storage Microsoft.Network \
          Microsoft.Insights Microsoft.OperationalInsights Microsoft.KeyVault Microsoft.RecoveryServices \
          Microsoft.Security Microsoft.PolicyInsights Microsoft.GuestConfiguration Microsoft.Consumption; do
  state=$(az provider show -n "$ns" --query registrationState -o tsv 2>/dev/null || echo NotRegistered)
  if [[ "$state" != "Registered" ]]; then
    echo "    $ns"
    az provider register -n "$ns" --wait >/dev/null
  fi
done

echo "==> Ensuring the EncryptionAtHost feature is registered"
feature_state=$(az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv 2>/dev/null || echo NotRegistered)
if [[ "$feature_state" != "Registered" ]]; then
  az feature register --namespace Microsoft.Compute --name EncryptionAtHost >/dev/null
  until [[ "$(az feature show --namespace Microsoft.Compute --name EncryptionAtHost --query properties.state -o tsv)" == "Registered" ]]; do
    echo "    waiting for EncryptionAtHost ..."; sleep 20
  done
fi
# Re-register Compute every time: the feature only takes effect after a
# provider re-registration, even when it was registered in an earlier run.
az provider register -n Microsoft.Compute >/dev/null

# --- Entra ID lookups ---
resolve_group() {
  az ad group show --group "$1" --query id -o tsv 2>/dev/null || { echo "Entra group not found: $1" >&2; exit 1; }
}
[[ -n "$USERS_GROUP" ]] && AVD_USERS_GROUP_ID=$(resolve_group "$USERS_GROUP")
[[ -n "$ADMINS_GROUP" ]] && AVD_ADMINS_GROUP_ID=$(resolve_group "$ADMINS_GROUP")
: "${AVD_USERS_GROUP_ID:?Set AVD_USERS_GROUP_ID or pass --users-group}"
: "${AVD_ADMINS_GROUP_ID:?Set AVD_ADMINS_GROUP_ID or pass --admins-group}"

if [[ -z "${AVD_SERVICE_PRINCIPAL_ID:-}" ]]; then
  echo "==> Looking up the Azure Virtual Desktop service principal"
  AVD_SERVICE_PRINCIPAL_ID=$(az ad sp show --id "$AVD_APP_ID" --query id -o tsv 2>/dev/null || true)
fi
if [[ -z "$AVD_SERVICE_PRINCIPAL_ID" ]]; then
  echo "    Not found in this tenant; creating it from the first-party app"
  AVD_SERVICE_PRINCIPAL_ID=$(az ad sp create --id "$AVD_APP_ID" --query id -o tsv)
fi

if [[ -z "${AVD_LOCAL_ADMIN_PASSWORD:-}" ]]; then
  # Random break-glass password. Azure applies it only when a host is created
  # (existing hosts keep theirs), and it is stored in Key Vault. Recovery for any
  # host: VM > Reset password, which needs no old password.
  rand=$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)
  AVD_LOCAL_ADMIN_PASSWORD="${rand}#Aa1"
  echo "    Generated a random break-glass password for new session hosts (stored in Key Vault as sessionhost-localadmin-password)."
fi

AVD_LOCATION="$LOCATION"
export AVD_USERS_GROUP_ID AVD_ADMINS_GROUP_ID AVD_SERVICE_PRINCIPAL_ID AVD_LOCAL_ADMIN_PASSWORD AVD_LOCATION

DEPLOY_NAME="avdlz-$(basename "$PARAM_FILE" .bicepparam)-$(date +%Y%m%d-%H%M%S)"

if $WHATIF; then
  echo "==> What-if ($DEPLOY_NAME) — no changes applied"
  az deployment sub what-if -n "$DEPLOY_NAME" -l "$LOCATION" -p "$PARAM_FILE"
  exit 0
fi

echo "==> Deploying ($DEPLOY_NAME). A first deployment takes 30-45 minutes."
az deployment sub create -n "$DEPLOY_NAME" -l "$LOCATION" -p "$PARAM_FILE" \
  --query properties.outputs -o jsonc

STORAGE_NAME=$(az deployment sub show -n "$DEPLOY_NAME" --query properties.outputs.storageAccountName.value -o tsv)
# rg-<prefix>-<env>-avd -> <prefix> and <env>, for the post-deployment command.
BASE_NAME=$(az deployment sub show -n "$DEPLOY_NAME" --query properties.outputs.resourceGroups.value.controlPlane -o tsv)
BASE_NAME=${BASE_NAME#rg-}; BASE_NAME=${BASE_NAME%-avd}

cat <<EOF

==> Landing zone deployed.

Next, three one-time tenant steps that Bicep can't do: admin consent for the
storage account's Entra app, excluding it from MFA Conditional Access policies,
and the profile share permissions. The post-deployment preflight checks and
applies all three. From Azure Cloud Shell (PowerShell):

  ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ${BASE_NAME%-*} -Environment ${BASE_NAME##*-} -Fix -AllowHostStart

To do them by hand instead (storage account $STORAGE_NAME), see docs/deploy.md#5-post-deployment.
EOF
