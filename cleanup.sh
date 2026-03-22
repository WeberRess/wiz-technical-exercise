#!/bin/bash
# =============================================================================
# cleanup.sh — Full Azure Wipe + Cloud Shell Logout
#
# Deletes EVERYTHING in the Azure subscription including the Cloud Shell
# storage account. After cleanup, logs out of Azure CLI and exits the shell.
#
# On next Cloud Shell login, Azure automatically creates a new storage account.
#
# What gets deleted:
#   - ALL resource groups (including Cloud Shell RG)
#   - ALL Azure Policy assignments
#   - ALL Defender for Cloud plans (downgraded to Free)
#   - ALL Activity Log diagnostic settings
#   - ALL Azure AD Service Principals from this exercise
#   - Local session files: wiz-outputs.txt, wiz-setup.log, wiz-exercise/
#
# GitHub repo: delete manually at github.com
# =============================================================================

ts() { date '+%H:%M:%S'; }

echo "================================================================"
echo " FULL AZURE WIPE + CLOUD SHELL LOGOUT"
echo " Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo ""
echo " This deletes EVERYTHING including the Cloud Shell storage."
echo " Cloud Shell will create a new storage on next login."
echo " GitHub repo must be deleted manually."
echo ""
printf " Type 'yes' to confirm full wipe: "
read -r CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 0; }
echo ""

# -----------------------------------------------------------------------
# Verify login
# -----------------------------------------------------------------------
SUB=$(az account show --query id -o tsv 2>/dev/null || true)
[ -z "$SUB" ] && { echo "ERROR: not logged in."; exit 1; }
echo "[$(ts)] Subscription: $SUB"

# -----------------------------------------------------------------------
# Step 1 — Remove all Azure Policy assignments
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Step 1/6 — Removing Azure Policy assignments..."
az policy assignment list --scope "/subscriptions/$SUB" \
  --query "[].name" -o tsv 2>/dev/null | while read -r NAME; do
  [ -z "$NAME" ] && continue
  az policy assignment delete --name "$NAME" \
    --scope "/subscriptions/$SUB" 2>/dev/null \
    && echo "  [deleted] $NAME" || true
done

az group list --query "[].name" -o tsv 2>/dev/null | while read -r RG; do
  az policy assignment list \
    --scope "/subscriptions/$SUB/resourceGroups/$RG" \
    --query "[].name" -o tsv 2>/dev/null | while read -r NAME; do
    [ -z "$NAME" ] && continue
    az policy assignment delete --name "$NAME" \
      --scope "/subscriptions/$SUB/resourceGroups/$RG" 2>/dev/null || true
  done
done
echo "[$(ts)] Done."

# -----------------------------------------------------------------------
# Step 2 — Downgrade Defender for Cloud to Free
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Step 2/6 — Disabling Defender for Cloud..."
for PLAN in VirtualMachines StorageAccounts Containers AppServices \
            SqlServers SqlServerVirtualMachines KeyVaults Arm Dns; do
  az security pricing create --name "$PLAN" --tier Free \
    --output none 2>/dev/null && echo "  [free] $PLAN" || true
done
echo "[$(ts)] Done."

# -----------------------------------------------------------------------
# Step 3 — Remove Activity Log diagnostic settings
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Step 3/6 — Removing diagnostic settings..."
az monitor diagnostic-settings subscription list \
  --query "[].name" -o tsv 2>/dev/null | while read -r NAME; do
  [ -z "$NAME" ] && continue
  az monitor diagnostic-settings subscription delete \
    --name "$NAME" --yes 2>/dev/null \
    && echo "  [deleted] $NAME" || true
done
echo "[$(ts)] Done."

# -----------------------------------------------------------------------
# Step 4 — Remove exercise Service Principals
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Step 4/6 — Removing Service Principals..."
for SP in "wiz-exercise-sp" "wiz-exercise-github-actions"; do
  ID=$(az ad sp list --display-name "$SP" \
    --query "[0].appId" -o tsv 2>/dev/null | head -1)
  [ -n "$ID" ] && [ "$ID" != "None" ] && \
    az ad sp delete --id "$ID" 2>/dev/null && \
    echo "  [deleted] $SP" || echo "  [skip] $SP not found"
done
echo "[$(ts)] Done."

# -----------------------------------------------------------------------
# Step 5 — Delete ALL resource groups in parallel
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Step 5/6 — Deleting ALL resource groups..."

ALL_RGS=$(az group list --query "[].name" -o tsv 2>/dev/null)

if [ -z "$ALL_RGS" ]; then
  echo "  No resource groups found."
else
  echo "  Resource groups:"
  echo "$ALL_RGS" | while read -r RG; do echo "    - $RG"; done
  echo ""
  echo "  Starting parallel deletions..."
  echo "$ALL_RGS" | while read -r RG; do
    [ -z "$RG" ] && continue
    az group delete --name "$RG" --yes --no-wait 2>/dev/null \
      && echo "  [$(ts)] started: $RG" \
      || echo "  [$(ts)] WARN: $RG"
  done
fi

# -----------------------------------------------------------------------
# Step 6 — Wait until all resource groups are confirmed gone
# Polls every 15s, max 20 min, exits only when Azure returns empty list.
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Step 6/6 — Waiting for all deletions to complete..."
echo "  Polling every 15s (typically 5-10 min)..."
echo ""

MAX=80   # 80 × 15s = 20 min
COUNT=0
CLEAN=false

while [ $COUNT -lt $MAX ]; do
  REMAINING=$(az group list --query "[].name" -o tsv 2>/dev/null)
  if [ -z "$REMAINING" ]; then
    CLEAN=true
    break
  fi
  N=$(echo "$REMAINING" | wc -l | tr -d ' ')
  printf "  [$(ts)] %d RG(s) still deleting: " "$N"
  echo "$REMAINING" | tr '\n' ' '
  echo ""
  COUNT=$((COUNT + 1))
  sleep 15
done

echo ""
if [ "$CLEAN" = "true" ]; then
  echo "[$(ts)] Azure subscription is completely empty."
else
  echo "[$(ts)] Timeout (20 min). Still deleting:"
  az group list --query "[].{Name:name,State:properties.provisioningState}" \
    -o table 2>/dev/null
  echo ""
  echo "  Check later: az group list -o table"
fi

# -----------------------------------------------------------------------
# Clean local session files
# -----------------------------------------------------------------------
echo ""
echo "[$(ts)] Cleaning local session..."
rm -f ~/wiz-outputs.txt ~/wiz-setup.log ~/wiz-validate-*.log
rm -rf ~/wiz-exercise/
rm -f ~/.ssh/id_rsa ~/.ssh/id_rsa.pub 2>/dev/null || true
echo "  Local files removed."

# -----------------------------------------------------------------------
# Logout and exit Cloud Shell
# -----------------------------------------------------------------------
echo ""
echo "================================================================"
echo " Wipe complete!"
echo " Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "================================================================"
echo " Azure subscription: empty"
echo " GitHub repo: delete manually at"
echo "   https://github.com/WeberRess/wiz-technical-exercise/settings"
echo ""
echo " Logging out and closing Cloud Shell..."
echo " On next login Azure will create a new storage account."
echo "================================================================"
echo ""

sleep 3

# Log out of Azure CLI
az logout 2>/dev/null || true

# Exit Cloud Shell session
exit 0
