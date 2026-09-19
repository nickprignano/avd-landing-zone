#!/usr/bin/env bash
# Stop the lab. Now, not in 8-24 hours when the budget data catches up.
#
# This is the kill switch you should actually reach for. The budget-triggered
# one in bicep/modules/costGuard.bicep is a backstop for when you forget; this
# is the one that works the moment you run it.
#
#   ./scripts/ops/stop-lab.sh -g rg-avd-lz-dev              # stop (reversible)
#   ./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --status     # what's running?
#   ./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --start      # undo a stop
#   ./scripts/ops/stop-lab.sh -g rg-avd-lz-dev --delete     # nuke it entirely
#
# Add -s <subscription-id> to target a specific subscription. Without it the
# script uses whatever your az context is currently set to, which is the easy
# way to stop (or delete) the wrong thing. Either way it prints the target
# before it touches anything.
#
# "Stop" disables the scaling plan and then DEALLOCATES the session hosts.
# Deallocated VMs bill nothing for compute. Disks, the storage account and the
# private endpoint still cost a little; --delete is the only thing that takes
# the bill to zero.
set -euo pipefail

RESOURCE_GROUP=""
SUBSCRIPTION=""
MODE="stop"

usage() {
  echo "Usage: $0 -g <resource-group> [-s <subscription>] [--status|--start|--delete]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -g) RESOURCE_GROUP="${2:-}"; shift 2 ;;
    -s) SUBSCRIPTION="${2:-}"; shift 2 ;;
    --status) MODE="status"; shift ;;
    --start)  MODE="start";  shift ;;
    --delete) MODE="delete"; shift ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done

[[ -z "$RESOURCE_GROUP" ]] && usage

# Every az call goes through this so -s never has to mutate your global az
# context. No -s means "use whatever is already selected".
az_() {
  if [[ -n "$SUBSCRIPTION" ]]; then
    az "$@" --subscription "$SUBSCRIPTION"
  else
    az "$@"
  fi
}

az account show >/dev/null 2>&1 || { echo "Run 'az login' first."; exit 1; }

# Say out loud what is about to be acted on. Wrong-subscription is the mistake
# that actually happens, and it is unrecoverable in --delete.
SUB_NAME=$(az_ account show --query name -o tsv 2>/dev/null || echo "?")
SUB_ID=$(az_ account show --query id -o tsv 2>/dev/null || echo "?")
echo "Subscription : $SUB_NAME ($SUB_ID)"
echo "Resource grp : $RESOURCE_GROUP"
echo ""

az_ group show -n "$RESOURCE_GROUP" >/dev/null 2>&1 || { echo "No such resource group: $RESOURCE_GROUP"; exit 1; }

# Resource IDs, looked up rather than assumed, so this works on a renamed deployment.
scaling_plan_id() {
  az_ resource list -g "$RESOURCE_GROUP" \
    --resource-type Microsoft.DesktopVirtualization/scalingPlans \
    --query "[0].id" -o tsv 2>/dev/null || true
}
host_pool_id() {
  az_ resource list -g "$RESOURCE_GROUP" \
    --resource-type Microsoft.DesktopVirtualization/hostPools \
    --query "[0].id" -o tsv 2>/dev/null || true
}

# Toggle the scaling plan. Without this a stop is undone at the next ramp-up.
set_scaling_plan() {
  local enabled="$1" sp hp
  sp="$(scaling_plan_id)"
  hp="$(host_pool_id)"
  if [[ -z "$sp" || -z "$hp" ]]; then
    echo "    (no scaling plan found - skipping)"
    return 0
  fi
  az_ rest --method patch \
    --url "https://management.azure.com${sp}?api-version=2024-04-03" \
    --headers "Content-Type=application/json" \
    --body "{\"properties\":{\"hostPoolReferences\":[{\"hostPoolArmPath\":\"${hp}\",\"scalingPlanEnabled\":${enabled}}]}}" \
    --only-show-errors >/dev/null
  echo "    scaling plan enabled=${enabled}"
}

case "$MODE" in
  status)
    echo "==> Session hosts in $RESOURCE_GROUP"
    az_ vm list -d -g "$RESOURCE_GROUP" \
      --query "[].{name:name, size:hardwareProfile.vmSize, power:powerState}" -o table 2>/dev/null \
      || echo "    (none)"
    echo ""
    echo "==> Scaling plan"
    sp="$(scaling_plan_id)"
    if [[ -n "$sp" ]]; then
      az_ rest --method get --url "https://management.azure.com${sp}?api-version=2024-04-03" \
        --query "properties.hostPoolReferences[].scalingPlanEnabled" -o tsv 2>/dev/null \
        | sed 's/^/    scalingPlanEnabled: /' || echo "    (unreadable)"
    else
      echo "    (none)"
    fi
    echo ""
    echo "==> Month-to-date cost is in the portal:"
    echo "    Cost Management + Billing > Cost analysis, scoped to $RESOURCE_GROUP"
    echo "    (The CLI reports the same lagging data the budget uses - 8-24h behind.)"
    ;;

  stop)
    echo "==> Disabling the scaling plan so it cannot restart the hosts"
    set_scaling_plan false
    echo "==> Deallocating session hosts"
    mapfile -t vm_ids < <(az_ vm list -g "$RESOURCE_GROUP" --query "[].id" -o tsv)
    if [[ ${#vm_ids[@]} -eq 0 ]]; then
      echo "    (no VMs found)"
    else
      az_ vm deallocate --ids "${vm_ids[@]}" --only-show-errors >/dev/null
      echo "    deallocated ${#vm_ids[@]} host(s)"
    fi
    echo ""
    echo "==> Stopped. Compute is no longer billing."
    echo "    Disks, storage and the private endpoint still cost a little."
    echo "    To take it to zero: $0 -g $RESOURCE_GROUP --delete"
    ;;

  start)
    echo "==> Starting session hosts"
    mapfile -t vm_ids < <(az_ vm list -g "$RESOURCE_GROUP" --query "[].id" -o tsv)
    if [[ ${#vm_ids[@]} -eq 0 ]]; then
      echo "    (no VMs found)"
    else
      az_ vm start --ids "${vm_ids[@]}" --only-show-errors >/dev/null
      echo "    started ${#vm_ids[@]} host(s)"
    fi
    echo "==> Re-enabling the scaling plan"
    set_scaling_plan true
    echo ""
    echo "==> Running again. It is billing again."
    ;;

  delete)
    echo "!!  This DELETES $RESOURCE_GROUP in subscription $SUB_NAME ($SUB_ID)"
    echo "!!  and everything in it: session hosts, profile share, the lot."
    echo "!!  There is no undo."
    read -r -p "Type the resource group name to confirm: " confirm
    if [[ "$confirm" != "$RESOURCE_GROUP" ]]; then
      echo "Name did not match. Nothing deleted."
      exit 1
    fi
    az_ group delete -n "$RESOURCE_GROUP" --yes --no-wait
    echo "==> Delete started (running in the background)."
    echo "    Watch it: az group show -n $RESOURCE_GROUP --subscription $SUB_ID"
    ;;
esac
