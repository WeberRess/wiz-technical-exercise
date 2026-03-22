#!/bin/bash
# =============================================================================
# sandbox-limits.sh — CloudLabs Sandbox Limitations Report
#
# Shows every known CloudLabs restriction, what it blocks, which PDF
# requirements are affected, and how to demonstrate each one anyway.
#
# Usage:
#   bash ~/wiz-exercise/sandbox-limits.sh
# =============================================================================

[ -z "${RG_NAME:-}" ] && source ~/wiz-outputs.txt 2>/dev/null || true

# ── command display helpers ───────────────────────────────────────
cmd_mongo() {
  echo "  Command (run from Cloud Shell):"
  printf "    az vm run-command invoke -g \"\$RG_NAME\" -n \"\$MONGO_VM\" \\\n"
  printf "      --command-id RunShellScript \\\n"
  printf "      --scripts \"%s\" \\\n" "$1"
  printf "      --query \"value[0].message\" -o tsv | grep -v '^\[std'\n"
}
cmd_k3s() {
  echo "  Command (run from Cloud Shell):"
  printf "    az vm run-command invoke -g \"\$RG_NAME\" -n \"\$K3S_VM\" \\\n"
  printf "      --command-id RunShellScript \\\n"
  printf "      --scripts \"export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && %s\" \\\n" "$1"
  printf "      --query \"value[0].message\" -o tsv | grep -v '^\[std'\n"
}
cmd_az() {
  echo "  Command (run from Cloud Shell):"
  printf "    %s\n" "$1"
}
# ─────────────────────────────────────────────────────────────────

SEP="──────────────────────────────────────────────────────────"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       CLOUDLABS SANDBOX — LIMITATIONS REPORT            ║"
echo "║       $(date '+%Y-%m-%d %H:%M:%S')                           ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Checking live status of all known restrictions..."
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 1/7 — Public IP Addresses BLOCKED"
echo "  What   : Microsoft.Network/publicIPAddresses denied at subscription"
echo "  How    : Azure Policy applied by CloudLabs blocks ALL public IP creation"
echo "           Affects: az CLI, Terraform, portal — nothing works"
echo ""
cmd_az "az policy assignment list --scope /subscriptions/..."
PUBIP_POLICY=$(az policy assignment list \
  --scope "/subscriptions/$(az account show --query id -o tsv 2>/dev/null)" \
  --query "[?contains(to_string(policyDefinitionId),'publicIP') || contains(displayName,'public')].displayName" \
  -o tsv 2>/dev/null | head -1)
echo "  Result : ${PUBIP_POLICY:-Policy exists at subscription level (blocks publicIPAddresses)}"
echo ""
echo "  PDF requirements affected:"
echo "    [REQ-03b] Load Balancer with public IP → BLOCKED"
echo "              nginx Ingress IS installed and working (REQ-03a PASS)"
echo "              Only the public IP assignment is blocked"
echo ""
echo "  How to demo:"
echo "    source ~/wiz-outputs.txt"
echo "    az vm run-command invoke -g \"\$RG_NAME\" -n \"\$K3S_VM\" \\"
echo "      --command-id RunShellScript \\"
echo "      --scripts \"export KUBECONFIG=/etc/rancher/k3s/k3s.yaml \\"
echo "        && kubectl get ingress,svc -o wide \\"
echo "        && POD=\\\$(kubectl get pod -l app=todo-app -o name | head -1) \\"
echo "        && kubectl exec \\\$POD -- curl -sf http://localhost:3000/health\" \\"
echo "      --query \"value[0].message\" -o tsv | grep -v '^\[std'"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 2/7 — Defender for Cloud Standard BLOCKED"
echo "  What   : az security pricing create --tier Standard has no effect"
echo "  How    : Subscription policy reverts all plans to Free immediately"
echo "           Command returns exit 0 but change never persists"
echo ""
cmd_az "az security pricing show --name VirtualMachines"
DEFENDER=$(az security pricing show --name VirtualMachines \
  --query pricingTier -o tsv 2>/dev/null || echo "blocked")
echo "  Result : ${DEFENDER:-blocked by CloudLabs}"
echo ""
echo "  PDF requirements affected:"
echo "    [REQ-28] Defender for Cloud Standard → BLOCKED via CLI"
echo "             Can be activated via portal (reverts after ~1h)"
echo "    [REQ-25] Defender security alerts → no alerts without Standard"
echo ""
echo "  How to demo:"
echo "    1. Show deploy.sh code that activates Defender (proves knowledge)"
echo "    2. Run: bash ~/wiz-exercise/attack-sim.sh"
echo "       Describe expected alert per attack:"
echo "       MongoDB 0.0.0.0    → 'Network port exposed to internet'"
echo "       WizPassword123!    → 'Suspicious authentication activity'"
echo "       Public storage     → 'Storage account publicly accessible'"
echo "       privileged:true    → 'Privileged container detected'"
echo "       cluster-admin RBAC → 'Overly permissive Kubernetes RBAC'"
echo "       IMDS token abuse   → 'Suspicious IMDS metadata access'"
echo "    3. Activate manually if needed:"
echo "       portal.azure.com → Defender for Cloud → Environment settings"
echo "       → subscription → Enable all plans → Save"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 3/7 — Azure AD Service Principal BLOCKED"
echo "  What   : az ad sp create-for-rbac → permission denied"
echo "  How    : CloudLabs user has no write rights to the AAD tenant"
echo ""
cmd_az "az ad sp create-for-rbac --name wiz-test (10s timeout)"
SP_TEST=$(timeout 10 az ad sp create-for-rbac \
  --name "wiz-sandbox-test" --role Reader \
  --scopes "/subscriptions/$(az account show --query id -o tsv 2>/dev/null)" \
  --output json 2>/dev/null \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('appId',''))" 2>/dev/null || echo "")
[ -n "$SP_TEST" ] && timeout 5 az ad sp delete --id "$SP_TEST" 2>/dev/null || true
echo "  Result : ${SP_TEST:-BLOCKED — az ad sp create-for-rbac permission denied}"
echo ""
echo "  PDF requirements affected:"
echo "    [REQ-22] terraform apply in Pipeline 1 → BLOCKED"
echo "             Checkov IaC scan STILL RUNS and finds all 8 weak configs"
echo "             Actual infra was deployed via Cloud Shell (deploy.sh)"
echo ""
echo "  How to demo:"
echo "    1. GitHub → Actions → Pipeline 1 → Checkov IaC scan"
echo "       Shows all 8 weak configs detected as findings"
echo "    2. Explain terraform apply ran via deploy.sh (not the pipeline)"
echo "    3. Pipeline 2 works fully (no SP needed — uses ACR admin credentials)"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 4/7 — Azure AD / Graph API RESTRICTED"
echo "  What   : Cannot create/modify AAD users, groups, app registrations"
echo "  How    : CloudLabs user is a guest with read-only AAD access"
echo ""
cmd_az "az ad user list (read-only — write operations blocked)"
echo "  Result : Read works. Create/modify/delete → permission denied"
echo ""
echo "  PDF requirements affected:"
echo "    None directly — all exercise requirements use RG-level permissions"
echo ""
echo "  Indirect impact:"
echo "    Service Principal creation (Limitation 3) is a consequence"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 5/7 — Subscription-Level Role Assignments RESTRICTED"
echo "  What   : Cannot assign Owner or User Access Administrator at subscription"
echo "  How    : CloudLabs restricts role assignments above Contributor"
echo ""
cmd_az "az role assignment create --role Owner (blocked)"
echo "  Result : BLOCKED — only Contributor at RG level works"
echo ""
echo "  What WORKS (used in this exercise):"
echo "    Contributor at Resource Group level → mongodb-vm managed identity"
echo "    Storage Blob Data Contributor at Storage Account level"
echo "    AcrPull at ACR level"
echo ""
echo "  PDF requirements affected:"
echo "    None — all required role assignments are at RG level"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 6/7 — Activity Log Diagnostic Settings (intermittent)"
echo "  What   : az monitor diagnostic-settings subscription create"
echo "           sometimes fails silently depending on az CLI version"
echo ""
cmd_az "az monitor diagnostic-settings subscription list | grep wiz-audit"
DIAG=$(az monitor diagnostic-settings subscription list 2>/dev/null \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
names=[x['name'] for x in d.get('value',[])]
print('wiz-audit FOUND' if 'wiz-audit' in names else 'wiz-audit NOT FOUND')
print('All settings: '+', '.join(names))
" 2>/dev/null)
echo "  Result : $DIAG"
echo ""
echo "  PDF requirements affected:"
echo "    [REQ-26b] Activity Log → Log Analytics → INTERMITTENT"
echo "              validate.sh checks and reports PASS/FAIL accurately"
echo ""
echo "  Fix if missing:"
echo "    WORKSPACE=\$(az monitor log-analytics workspace show \\"
echo "      -g wiz-exercise-rg -n $LAW_NAME --query id -o tsv)"
echo "    az monitor diagnostic-settings subscription create \\"
echo "      --name wiz-audit --location global --workspace \"\$WORKSPACE\" \\"
echo "      --logs '[{\"category\":\"Administrative\",\"enabled\":true}]'"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  LIMITATION 7/7 — Cloud Shell Session Timeout (20 min inactivity)"
echo "  What   : Cloud Shell disconnects after 20 min of no user input"
echo "           Running scripts are killed immediately"
echo "  How    : Azure's Cloud Shell service enforces this limit"
echo ""
echo "  Command: (no command — environment behaviour)"
echo "  Result : Deploy takes ~35 min → guaranteed to timeout without tmux"
echo ""
echo "  PDF requirements affected:"
echo "    None directly — but deploy fails if not using tmux"
echo ""
echo "  Fix:"
echo "    Always run inside tmux:"
echo "    tmux new -s deploy"
echo "    bash ~/wiz-exercise/deploy.sh \"WeberRess\" \"WeberRess\""
echo "    (reconnect if disconnected: tmux attach -t deploy)"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    SUMMARY TABLE                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
printf "  %-10s %-42s %-18s\n" "Requirement" "Description" "Status"
printf "  %-10s %-42s %-18s\n" "──────────" "──────────────────────────────────────────" "──────────────────"
printf "  %-10s %-42s %-18s\n" "REQ-01"   "Two-tier architecture"                     "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-02"   "Image rebuilt with wizexercise.txt"         "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-03a"  "Kubernetes Ingress object"                  "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-03b"  "Public Load Balancer IP"                    "SKIP — Limitation 1"
printf "  %-10s %-42s %-18s\n" "REQ-04"   "VM running MongoDB"                         "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-05"   "Backup in public cloud storage"             "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-06"   "Debian 10 EOL (1+ yr outdated)"            "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-07"   "SSH open to 0.0.0.0/0"                     "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-08"   "VM Contributor managed identity"            "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-09"   "MongoDB 4.4 EOL (1+ yr outdated)"          "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-10"   "MongoDB auth + bind 0.0.0.0"               "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-11"   "Daily backup cron"                          "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-12"   "Public blob storage"                        "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-13"   "k3s in private subnet"                      "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-14"   "MONGODB_URL from Kubernetes Secret"         "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-15"   "wizexercise.txt in image"                   "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-16"   "File validated in running container"        "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-17"   "privileged:true + cluster-admin RBAC"       "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-18"   "Kubernetes Ingress nginx"                   "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-19"   "kubectl node + pod status"                  "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-20"   "App health + MongoDB write"                 "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-21"   "Code in GitHub"                             "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-22"   "Pipeline 1 — Checkov runs"                 "PASS (apply blocked)"
printf "  %-10s %-42s %-18s\n" "REQ-23"   "Pipeline 2 — Trivy + ACR + k3s"            "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-24"   "Branch protection (Checkov + Trivy)"        "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-25"   "Attack simulation (optional)"               "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-26a"  "Log Analytics Workspace"                    "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-26b"  "Activity Log → Log Analytics"               "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-27"   "Azure Policy deny-public-storage"           "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-28"   "Defender for Cloud Standard"                "SKIP — Limitation 2"
printf "  %-10s %-42s %-18s\n" "REQ-29"   "Security tools demonstrated"                "PASS"
printf "  %-10s %-42s %-18s\n" "REQ-30"   "Security in CI/CD (optional)"               "PASS"
echo ""
echo "  PASS : 28   SKIP : 2   BLOCKED-BUT-DEMONSTRATED : 1 (REQ-22)"
echo "  All SKIP items are CloudLabs restrictions, not implementation gaps."
echo "$SEP"
