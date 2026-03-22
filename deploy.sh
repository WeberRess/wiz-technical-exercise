#!/bin/bash
# =============================================================================
# deploy.sh — Wiz Technical Exercise v5 — SINGLE DEPLOY SCRIPT
#
# Usage:
#   export GITHUB_TOKEN=ghp_xxxx
#   bash deploy.sh "Your Name" "github-username"
#
# This is the ONLY script needed to deploy the entire exercise.
# All VM setup scripts are embedded here and written to temp files
# before being uploaded to blob storage and executed on the VMs.
#
# Architecture deployed:
#   PUBLIC  subnet 10.0.1.0/24 → mongodb-vm  (Debian 10 + MongoDB 4.4)
#   PRIVATE subnet 10.0.2.0/24 → k3s-vm      (Debian 12 + k3s + todo-app)
#
# Intentional weak configs (all required by the exercise PDF):
#   1. Debian 10 Buster     — EOL June 2024, no more security patches
#   2. MongoDB 4.4          — EOL February 2024, known CVEs
#   3. SSH open to 0.0.0.0/0 — MongoDB VM SSH exposed to the internet
#   4. Contributor role     — VM managed identity can create/delete resources
#   5. Public blob storage  — backup files readable by anyone, no auth
#   6. privileged: true     — container can access host filesystem
#   7. cluster-admin RBAC   — pod controls the entire Kubernetes cluster
#   8. bind 0.0.0.0         — MongoDB listens on all network interfaces
# =============================================================================

YOUR_NAME="${1:-}"
GITHUB_USER="${2:-}"

if [ -z "$YOUR_NAME" ] || [ -z "$GITHUB_USER" ]; then
  echo "Usage: bash deploy.sh \"Your Name\" \"github-username\""
  exit 1
fi

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec > >(tee -a ~/wiz-setup.log) 2>&1

START=$(date +%s)
ts()      { date '+%H:%M:%S'; }
elapsed() { echo $(( $(date +%s) - $1 ))s; }

echo "========================================"
echo " Wiz Technical Exercise v5"
echo " Candidate : $YOUR_NAME"
echo " GitHub    : $GITHUB_USER"
echo " Started   : $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

# =============================================================================
# STEP 1 — SSH key
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 1/7: SSH key"
[ ! -f ~/.ssh/id_rsa.pub ] && ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N "" -q
SSH_PUB=$(cat ~/.ssh/id_rsa.pub)
echo "[$(ts)] STEP 1/7: done ($(elapsed $T))"

# =============================================================================
# STEP 2 — Register Azure providers
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 2/7: Register Azure providers"
for p in Microsoft.Compute Microsoft.Network Microsoft.Storage \
          Microsoft.ContainerRegistry Microsoft.Security \
          Microsoft.OperationalInsights Microsoft.PolicyInsights; do
  az provider register --namespace "$p" --wait 2>/dev/null || true
done
echo "[$(ts)] STEP 2/7: done ($(elapsed $T))"

# =============================================================================
# STEP 3 — Terraform: provision all Azure infrastructure
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 3/7: Terraform — provision infrastructure (~5 min)"
cd "${SCRIPT_DIR}/terraform"

cat > terraform.tfvars << TFVARS
resource_group_name = "wiz-exercise-rg"
location            = "uksouth"
vm_admin_username   = "azureuser"
vm_ssh_public_key   = "$SSH_PUB"
your_name           = "$YOUR_NAME"
TFVARS

CACHE="${HOME}/clouddrive/.terraform-plugin-cache"
mkdir -p "$CACHE" 2>/dev/null || CACHE="${HOME}/.terraform-plugin-cache"
mkdir -p "$CACHE"
export TF_PLUGIN_CACHE_DIR="$CACHE"

echo "[$(ts)]   terraform init..."
terraform init -upgrade -input=false -no-color

echo "[$(ts)]   terraform apply..."
# If resource group already exists from a previous deploy, import it into state
# This prevents "resource already exists" error without needing a cleanup first
if az group show --name "wiz-exercise-rg" --output none 2>/dev/null; then
  echo "  Resource group wiz-exercise-rg already exists — importing into Terraform state..."
  terraform import -input=false azurerm_resource_group.main     "/subscriptions/$SUB/resourceGroups/wiz-exercise-rg" 2>/dev/null || true
fi
terraform apply -auto-approve -input=false -no-color

MONGO_IP=$(terraform output -raw mongodb_private_ip)
MONGO_VM=$(terraform output -raw mongodb_vm_name)
K3S_IP=$(terraform output -raw k3s_private_ip)
K3S_VM=$(terraform output -raw k3s_vm_name)
ACR_SERVER=$(terraform output -raw acr_login_server)
ACR_NAME=$(terraform output -raw acr_name)
STORAGE=$(terraform output -raw storage_account_name)
RG=$(terraform output -raw resource_group_name)
SUB=$(az account show --query id -o tsv)
LAW_NAME="wiz-logs-$((RANDOM % 90 + 10))"
BLOB_BASE="https://${STORAGE}.blob.core.windows.net/mongodb-backups"


cat > ~/wiz-outputs.txt << OUTPUTS
MONGO_VM=$MONGO_VM
MONGO_IP=$MONGO_IP
K3S_VM=$K3S_VM
K3S_IP=$K3S_IP
ACR_SERVER=$ACR_SERVER
ACR_NAME=$ACR_NAME
STORAGE=$STORAGE
RG_NAME=$RG
SUB_ID=$SUB
YOUR_NAME=$YOUR_NAME
LAW_NAME=$LAW_NAME
OUTPUTS
# WORKSPACE written after LAW create in Step 7

echo "  mongodb-vm : $MONGO_IP  |  k3s-vm : $K3S_IP"
echo "  ACR: $ACR_SERVER  |  Storage: $STORAGE"

# Verify Contributor role propagation (AAD can take 30-90s)
PRINCIPAL=$(az vm identity show -g "$RG" -n "$MONGO_VM" \
  --query principalId -o tsv 2>/dev/null || true)
if [ -n "$PRINCIPAL" ]; then
  EXISTING=$(az role assignment list --assignee "$PRINCIPAL" \
    --scope "/subscriptions/$SUB/resourceGroups/$RG" \
    --query "[?roleDefinitionName=='Contributor'].roleDefinitionName" \
    -o tsv 2>/dev/null || true)
  [ -z "$EXISTING" ] && \
    az role assignment create \
      --assignee-object-id "$PRINCIPAL" \
      --assignee-principal-type ServicePrincipal \
      --role Contributor \
      --scope "/subscriptions/$SUB/resourceGroups/$RG" \
      --output none 2>/dev/null && echo "  Contributor role assigned" || true \
    || echo "  Contributor role confirmed"
fi
echo "[$(ts)] STEP 3/7: done ($(elapsed $T))"

# =============================================================================
# STEP 4 — Install MongoDB on mongodb-vm
#
# The setup script is written here as a heredoc, uploaded to blob, then
# fetched and executed on the VM. VM scripts are in scripts/ folder.
# Binaries are downloaded IN CLOUD SHELL and pushed to blob — the VM
# downloads from blob (Azure internal network, reliable).
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 4/7: Install MongoDB on mongodb-vm"
echo "[$(ts)]   Waiting 90s for VMs to boot..."
sleep 90

# Download MongoDB tarballs in Cloud Shell (reliable internet here)
echo "[$(ts)]   Downloading MongoDB 4.4.29 (~130MB)..."
curl -fL --progress-bar \
  "https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-debian10-4.4.29.tgz" \
  -o /tmp/mongodb.tgz

echo "[$(ts)]   Downloading MongoDB Tools 100.9.5 (~60MB)..."
curl -fL --progress-bar \
  "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian10-x86_64-100.9.5.tgz" \
  -o /tmp/mongotools.tgz

# Upload tarballs + script to blob
echo "[$(ts)]   Uploading to blob..."
for f in /tmp/mongodb.tgz /tmp/mongotools.tgz "${SCRIPT_DIR}/scripts/01-mongodb.sh"; do
  az storage blob upload \
    --account-name "$STORAGE" --container-name mongodb-backups \
    --name "$(basename $f)" --file "$f" \
    --overwrite --auth-mode key --output none
done
rm -f /tmp/mongodb.tgz /tmp/mongotools.tgz

echo "[$(ts)]   Running on VM..."
az vm run-command invoke \
  --resource-group "$RG" --name "$MONGO_VM" \
  --command-id RunShellScript \
  --scripts "export MONGO_TGZ_URL='${BLOB_BASE}/mongodb.tgz' TOOLS_TGZ_URL='${BLOB_BASE}/mongotools.tgz' && wget -q '${BLOB_BASE}/01-mongodb.sh' -O /tmp/01-mongodb.sh && bash /tmp/01-mongodb.sh" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -v "^Enable succeeded" || true

# Verify MongoDB is running
MONGO_VER=$(az vm run-command invoke \
  --resource-group "$RG" --name "$MONGO_VM" \
  --command-id RunShellScript \
  --scripts "/usr/local/bin/mongod --version 2>/dev/null | head -1" \
  --query "value[0].message" -o tsv 2>/dev/null | grep "db version" || true)

if [ -z "$MONGO_VER" ]; then
  echo "[ERROR] MongoDB not found. Install log:"
  az vm run-command invoke --resource-group "$RG" --name "$MONGO_VM" \
    --command-id RunShellScript \
    --scripts "tail -30 /var/log/wiz-mongodb-install.log 2>/dev/null || echo 'no log'" \
    --query "value[0].message" -o tsv 2>/dev/null | grep -v "^Enable succeeded" || true
  exit 1
fi
echo "  MongoDB: $MONGO_VER"
echo "[$(ts)] STEP 4/7: done ($(elapsed $T))"

# =============================================================================
# STEP 5 — Configure daily backups + first backup
# Uses curl + managed identity token — no az CLI needed on the VM
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 5/7: Configure daily backups"

# Patch storage account name and upload
sed "s/STORAGE_ACCOUNT_PLACEHOLDER/$STORAGE/g" \
  "${SCRIPT_DIR}/scripts/02-backup.sh" > /tmp/02-backup-patched.sh

az storage blob upload \
  --account-name "$STORAGE" --container-name mongodb-backups \
  --name "02-backup.sh" --file /tmp/02-backup-patched.sh \
  --overwrite --auth-mode key --output none

az vm run-command invoke \
  --resource-group "$RG" --name "$MONGO_VM" \
  --command-id RunShellScript \
  --scripts "wget -q '${BLOB_BASE}/02-backup.sh' -O /tmp/02-backup.sh && bash /tmp/02-backup.sh" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -v "^Enable succeeded" || true

echo "  Cron configured. Waiting 90s for RBAC propagation then running first backup..."
sleep 90

az vm run-command invoke \
  --resource-group "$RG" --name "$MONGO_VM" \
  --command-id RunShellScript \
  --scripts "bash /usr/local/bin/mongodb-backup.sh 2>&1 | tail -10" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -v "^Enable succeeded" || true
echo "[$(ts)] STEP 5/7: done ($(elapsed $T))"

# =============================================================================
# STEP 6 — Build container image + deploy k3s
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 6/7: Build container image via ACR Tasks"
cd "${SCRIPT_DIR}/app"
az acr build \
  --registry "$ACR_NAME" \
  --image "todo-app:latest" \
  --build-arg "CANDIDATE_NAME=${YOUR_NAME}" \
  . --no-logs
echo "  Pushed: ${ACR_SERVER}/todo-app:latest"
ACR_USER=$(az acr credential show --name "$ACR_NAME" --query username -o tsv)
ACR_PASS=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)
echo "[$(ts)] STEP 6/7: done ($(elapsed $T))"

echo ""; T=$(date +%s)
echo "[$(ts)] STEP 6b/7: Deploy k3s and todo-app (~8 min)"

az storage blob upload \
  --account-name "$STORAGE" --container-name mongodb-backups \
  --name "03-k3s.sh" --file "${SCRIPT_DIR}/scripts/03-k3s.sh" \
  --overwrite --auth-mode key --output none

echo "[$(ts)]   Running 03-k3s.sh on VM..."
az vm run-command invoke \
  --resource-group "$RG" --name "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "wget -q '${BLOB_BASE}/03-k3s.sh' -O /tmp/03-k3s.sh && bash /tmp/03-k3s.sh '$ACR_SERVER' '$ACR_USER' '$ACR_PASS' '$MONGO_IP' '$YOUR_NAME'" \
  --query "value[0].message" -o tsv 2>/dev/null | grep -v "^Enable succeeded" || true
echo "[$(ts)] STEP 6b/7: done ($(elapsed $T))"

# =============================================================================
# STEP 7 — Security controls + GitHub
# =============================================================================
echo ""; T=$(date +%s)
echo "[$(ts)] STEP 7/7: Security controls + GitHub"
# Disable set -e for all of Step 7 — many az commands fail gracefully
# in CloudLabs (Defender, diagnostic settings) and we handle each explicitly
set +e

LOCATION=$(az group show -n "$RG" --query location -o tsv)

# [1] Audit: Activity Log → Log Analytics
az monitor log-analytics workspace create \
  --resource-group "$RG" --workspace-name "$LAW_NAME" \
  --location "$LOCATION" --sku PerGB2018 --retention-time 30 \
  --output none 2>/dev/null || true

WORKSPACE=$(az monitor log-analytics workspace show \
  --resource-group "$RG" --workspace-name "$LAW_NAME" \
  --query id -o tsv 2>/dev/null || echo "")

[ -n "$WORKSPACE" ] \
  && echo "  [1/3] Audit logging: Activity Log → Log Analytics [OK]" \
  || echo "  [WARN] LAW not available — diagnostic settings skipped"

# Delete any existing diagnostic setting first (avoid conflict on redeploy)
[ -z "$WORKSPACE" ] && { echo "  [SKIP] Diagnostic settings — LAW not available"; } || {
az monitor diagnostic-settings subscription delete \
  --name wiz-audit --yes 2>/dev/null || true
sleep 3

DIAG_LOGS='[{"category":"Administrative","enabled":true},{"category":"Security","enabled":true},{"category":"Policy","enabled":true}]'

az monitor diagnostic-settings subscription create \
  --name wiz-audit \
  --location global \
  --workspace "$WORKSPACE" \
  --logs "$DIAG_LOGS" \
  --output none 2>/dev/null \
|| az monitor diagnostic-settings subscription create \
  --name wiz-audit \
  --workspace "$WORKSPACE" \
  --logs "$DIAG_LOGS" \
  --output none 2>/dev/null \
|| true

sleep 3
DIAG_CHECK=$(az monitor diagnostic-settings subscription list 2>/dev/null \
  | python3 -c "import sys,json;d=json.load(sys.stdin);names=[x['name'] for x in d.get('value',[])];print('wiz-audit' if 'wiz-audit' in names else '')" 2>/dev/null)
if [ -n "$DIAG_CHECK" ]; then
  echo "  [1/3] Audit logging: Activity Log → Log Analytics [OK]"
  echo "         LAW: $LAW_NAME | setting: wiz-audit"
else
  echo "  [WARN] Diagnostic setting not confirmed — check portal"
fi
} # end WORKSPACE guard

# [2] Preventative: Azure Policy — deny new public storage
az policy assignment create \
  --name deny-public-storage \
  --policy "4fa4b6c0-31ca-4c0d-b10d-24b96f62a751" \
  --scope "/subscriptions/${SUB}/resourceGroups/${RG}" \
  --output none 2>/dev/null || true
echo "  [2/3] Preventative: Azure Policy (deny public blob)"

# [3] Detective: Defender for Cloud
for plan in VirtualMachines StorageAccounts Containers; do
  az security pricing create --name "$plan" --tier Standard --output none 2>/dev/null || true
done
az security workspace-setting create --name default \
  --target-workspace "$WORKSPACE" --output none 2>/dev/null || true

# Verify Defender is actually on Standard (fail loudly if not)
DEFENDER_OK=$(az security pricing list \
  --query "[?pricingTier=='Standard'].name" -o tsv 2>/dev/null | tr '\n' ' ')
if [ -n "$DEFENDER_OK" ]; then
  echo "  [3/3] Detective: Defender for Cloud Standard — $DEFENDER_OK"
else
  echo "  [WARN] Defender activation failed — retrying..."
  for plan in VirtualMachines StorageAccounts Containers; do
    az security pricing create --name "$plan" --tier Standard --output none 2>/dev/null || true
  done
  DEFENDER_OK=$(az security pricing list \
    --query "[?pricingTier=='Standard'].name" -o tsv 2>/dev/null | tr '\n' ' ')
  [ -n "$DEFENDER_OK" ] \
    && echo "  [3/3] Defender for Cloud Standard — $DEFENDER_OK" \
    || echo "  [FAIL] Defender not activated — run manually: az security pricing create --name VirtualMachines --tier Standard"
fi

[ -z "$WORKSPACE" ] && echo "  [WARN] LAW workspace not available — skipping LAW-dependent steps"

# [4] Install monitoring agents on both VMs
# - mongodb-vm (Debian 10): OmsAgentForLinux (legacy MMA agent)
# - k3s-vm     (Debian 12): AzureMonitorLinuxAgent (new AMA agent)
# These agents send VM telemetry to Defender for Cloud for threat detection.
# Installed in background (--no-wait) so deploy doesn't block.
echo "  [4/4] Installing monitoring agents on VMs..."
WS_ID=$(az monitor log-analytics workspace show \
  --resource-group "$RG" --workspace-name "$LAW_NAME" \
  --query customerId -o tsv 2>/dev/null || echo "")
WS_KEY=$(az monitor log-analytics workspace get-shared-keys \
  --resource-group "$RG" --workspace-name "$LAW_NAME" \
  --query primarySharedKey -o tsv 2>/dev/null || echo "")

if [ -n "$WS_ID" ] && [ -n "$WS_KEY" ]; then
  OMS_SETTINGS='{"workspaceId":"'"$WS_ID"'","workspaceKey":"'"$WS_KEY"'"}'
  # OmsAgentForLinux for Debian 10 (mongodb-vm)
  az vm extension set \
    --resource-group "$RG" --vm-name "$MONGO_VM" \
    --name OmsAgentForLinux \
    --publisher Microsoft.EnterpriseCloud.Monitoring \
    --settings '{"workspaceId":"'"$WS_ID"'"}' \
    --protected-settings '{"workspaceKey":"'"$WS_KEY"'"}' \
    --no-wait --output none 2>/dev/null \
    && echo "    mongodb-vm: OmsAgentForLinux installing..." \
    || echo "    mongodb-vm: agent install skipped"

  # AzureMonitorLinuxAgent for Debian 12 (k3s-vm)
  az vm extension set \
    --resource-group "$RG" --vm-name "$K3S_VM" \
    --name AzureMonitorLinuxAgent \
    --publisher Microsoft.Azure.Monitor \
    --no-wait --output none 2>/dev/null \
    && echo "    k3s-vm: AzureMonitorLinuxAgent installing..." \
    || echo "    k3s-vm: agent install skipped"

  echo "    Agents installing in background (~5 min)"
  echo "    Verify: portal.azure.com → Defender for Cloud → Inventory"
else
  echo "    [SKIP] Workspace keys unavailable — install agents manually"
fi

# GitHub: push code + configure CI/CD
# Identical structure to the Ubuntu version that worked.
# Two fixes vs Ubuntu:
#   1. "gh auth refresh" REMOVED — hangs in new Cloud Shell sessions (opens browser)
#   2. git push has explicit timeout — prevents hanging on large repos
# Disable set -e for GitHub block — many gh/git commands return non-zero
# in CloudLabs and we handle failures manually with || true / error messages
set +e
if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "[$(ts)] WARN: GITHUB_TOKEN not set — skipping GitHub setup"
else
  echo "[$(ts)]   GitHub: setting up repository..."
  echo "$GITHUB_TOKEN" | timeout 15 gh auth login --with-token 2>/dev/null || true
  echo "  Authenticated"

  # Service Principal — 30s timeout (CloudLabs often blocks this)
  SP_JSON=$(timeout 30 az ad sp create-for-rbac \
    --name "wiz-exercise-sp" --role "Contributor" \
    --scopes "/subscriptions/$SUB/resourceGroups/$RG" \
    --sdk-auth --output json 2>/dev/null || echo "")
  [ -z "$SP_JSON" ] && {
    echo "  [INFO] Service Principal unavailable (CloudLabs restriction)"
    echo "  [INFO] Checkov + Trivy scans still run. Terraform apply in Pipeline 1 needs manual credentials."
    SP_JSON='{"clientId":"MANUAL","clientSecret":"MANUAL","subscriptionId":"'"$SUB"'","tenantId":"MANUAL"}'
  }
  CLIENT_ID=$(echo "$SP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('clientId',''))" 2>/dev/null)
  CLIENT_SECRET=$(echo "$SP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('clientSecret',''))" 2>/dev/null)
  TENANT_ID=$(echo "$SP_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('tenantId',''))" 2>/dev/null)

  # Git init
  cd "${SCRIPT_DIR}"
  rm -rf terraform/.terraform 2>/dev/null || true
  git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
  printf 'https://%s:%s@github.com\n' "$GITHUB_USER" "$GITHUB_TOKEN" > ~/.git-credentials
  git config --global credential.helper store
  git config --global user.email "${GITHUB_USER}@users.noreply.github.com"
  git config --global user.name  "$YOUR_NAME"
  # Always reinit cleanly — avoids stale .git from previous deploys
  rm -rf .git 2>/dev/null || true
  git init -q 2>/dev/null
  git checkout -b main 2>/dev/null || true
  grep -q "terraform.tfvars" .gitignore 2>/dev/null || \
    printf 'terraform/.terraform/\nterraform/terraform.tfstate*\nterraform/terraform.tfvars\nwiz-outputs.txt\n*.log\n' >> .gitignore
  git add -A
  git commit -m "Wiz Technical Exercise v5 - $YOUR_NAME - $(date +%Y-%m-%d)" --allow-empty -q 2>/dev/null

  # Create repo (separate create + push so each has its own timeout)
  timeout 30 gh repo delete "$GITHUB_USER/wiz-technical-exercise" --yes 2>/dev/null || true
  sleep 3
  timeout 30 gh repo create "wiz-technical-exercise" \
    --public \
    --description "Wiz Technical Exercise v5 - $YOUR_NAME" 2>/dev/null

  git remote remove origin 2>/dev/null || true
  git remote add origin "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/wiz-technical-exercise.git"

  echo "  Pushing code to GitHub..."
  timeout 120 git push -u origin main --force 2>/dev/null \
    && echo "  [ok] Code pushed to GitHub" \
    || echo "  [WARN] Push failed — retry: cd ~/wiz-exercise && git push -u origin main"

  # Secrets
  _s() {
    [ -n "$2" ] && [ "$2" != "MANUAL" ] && \
      timeout 15 gh secret set "$1" --body "$2" \
        --repo "$GITHUB_USER/wiz-technical-exercise" 2>/dev/null \
      && echo "  [ok] Secret: $1" || echo "  [info] Skipped (SP unavailable — expected): $1"
  }
  _s "AZURE_CREDENTIALS"   "$SP_JSON"
  _s "ARM_CLIENT_ID"       "$CLIENT_ID"
  _s "ARM_CLIENT_SECRET"   "$CLIENT_SECRET"
  _s "ARM_SUBSCRIPTION_ID" "$SUB"
  _s "ARM_TENANT_ID"       "$TENANT_ID"
  _s "VM_SSH_PUBLIC_KEY"   "$(cat ~/.ssh/id_rsa.pub)"
  _s "CANDIDATE_NAME"      "$YOUR_NAME"
  _s "ACR_NAME"            "$ACR_NAME"

  # Branch protection — wait for workflows to register then set required checks
  sleep 10
  BP_OK=false
  for attempt in 1 2 3; do
    BP_RESULT=$(printf '{"required_status_checks":{"strict":true,"contexts":["Checkov IaC scan","Trivy container scan"]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":1,"dismiss_stale_reviews":true},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' \
      | timeout 15 gh api --method PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/${GITHUB_USER}/wiz-technical-exercise/branches/main/protection" \
        --input - 2>/dev/null)
    # Verify the contexts were actually saved
    SAVED=$(echo "$BP_RESULT" | python3 -c "import sys,json;d=json.load(sys.stdin);print(','.join(d.get('required_status_checks',{}).get('contexts',[])))" 2>/dev/null)
    if echo "$SAVED" | grep -q "Checkov"; then
      echo "  [ok] Branch protection (Checkov + Trivy required before merge)"
      BP_OK=true
      break
    fi
    sleep 5
  done
  [ "$BP_OK" = "false" ] && echo "  [warn] Branch protection set but contexts may not be verified — check GitHub Settings"

  # Trigger pipelines
  sleep 3
  timeout 15 gh workflow run "01-iac.yml" \
    --repo "$GITHUB_USER/wiz-technical-exercise" --ref main 2>/dev/null \
    && echo "  Pipeline 1 triggered" || echo "  WARN: trigger Pipeline 1 manually"
  timeout 15 gh workflow run "02-container.yml" \
    --repo "$GITHUB_USER/wiz-technical-exercise" --ref main 2>/dev/null \
    && echo "  Pipeline 2 triggered" || echo "  WARN: trigger Pipeline 2 manually"

  echo "  GitHub  : https://github.com/$GITHUB_USER/wiz-technical-exercise"
  echo "  Actions : https://github.com/$GITHUB_USER/wiz-technical-exercise/actions"
fi
set -e
echo "[$(ts)] STEP 7/7: done ($(elapsed $T))"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================"
echo " Deployment complete!"
echo " Duration : $(elapsed $START)"
echo "========================================"
echo " mongodb-vm : $MONGO_IP (Debian 10, public-subnet)"
echo " k3s-vm     : $K3S_IP  (Debian 12, private-subnet)"
echo " ACR        : $ACR_SERVER"
echo " Storage    : https://${STORAGE}.blob.core.windows.net/mongodb-backups"
echo " GitHub     : https://github.com/${GITHUB_USER}/wiz-technical-exercise"
echo ""
echo "========================================"

# Run attack simulation once to pre-populate Defender for Cloud alerts
echo ""
echo "[$(ts)] Running attack simulation (populates Defender for Cloud)..."
source ~/wiz-outputs.txt 2>/dev/null || true
bash "${SCRIPT_DIR}/attack-sim.sh" 3
echo "[$(ts)] Attack simulation done — alerts appear in Defender in ~5-10 min"
echo ""
echo "========================================"
echo " All done!"
echo " Next: bash ~/wiz-exercise/validate.sh"
echo "========================================"


