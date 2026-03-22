# Wiz Technical Exercise v5 — Azure

Wiz Security Technical Exercise deployed on Azure using only Azure Cloud Shell.  
Demonstrates intentional cloud misconfigurations, DevSecOps pipelines, and cloud-native security controls.

> **All VM commands run via `az vm run-command invoke` — no SSH, no public IPs required.**  
> Direct `kubectl` in Cloud Shell will fail — the k3s cluster is on a private VM with no public IP.

---

## Architecture

```
Internet
    │
    ▼
VNet 10.0.0.0/16
├── public-subnet  10.0.1.0/24
│   └── mongodb-vm  (Debian 10 Buster + MongoDB 4.4)
│       NSG: SSH open to 0.0.0.0/0       ← intentional weak config
│             MongoDB 27017 restricted to 10.0.2.0/24 only
│
└── private-subnet 10.0.2.0/24
    └── k3s-vm  (Debian 12 + k3s + todo-app container)
        NSG: SSH restricted to VNet only
              HTTP/80 open (nginx Ingress)

Azure Container Registry  → todo-app:latest
Azure Blob Storage        → mongodb-backups (PUBLIC) ← intentional weak config
Log Analytics Workspace   → wiz-logs-XX (random suffix)
```

---

## Quick Start

```bash
# Always run inside tmux — deploy takes ~35 min
tmux new -s deploy

cd ~
rm -rf ~/wiz-exercise
mkdir ~/wiz-exercise
unzip -o wiz-debian.zip -d ~/wiz-exercise

export GITHUB_TOKEN=ghp_xxxx
bash ~/wiz-exercise/deploy.sh "Your Name" "github-username"
```

If Cloud Shell disconnects:
```bash
tmux attach -t deploy
```

After deploy:
```bash
bash ~/wiz-exercise/validate.sh        # verify all requirements
bash ~/wiz-exercise/attack-sim.sh      # run attack demo
bash ~/wiz-exercise/sandbox-limits.sh  # CloudLabs restrictions report
bash ~/wiz-exercise/cleanup.sh         # delete everything + logout
```

---

## Deploy Steps (fully automated)

| Step | Duration | What happens |
|---|---|---|
| 1 | ~1s | SSH key generation |
| 2 | ~15s | Register Azure resource providers |
| 3 | ~3 min | Terraform: VNet, VMs, ACR, Storage, NSGs, role assignments |
| 4 | ~3 min | MongoDB 4.4 install on Debian 10 via blob download |
| 5 | ~3 min | Daily backup cron + first backup to public blob |
| 6 | ~2 min | Container image build via ACR Tasks |
| 6b | ~4 min | k3s + nginx Ingress + todo-app deploy |
| 7 | ~2 min | Log Analytics + Azure Policy + Defender + GitHub push |
| ∞ | ~8 min | Attack simulation (3 iterations × 6 attacks) |

---

## Intentional Weak Configurations

| # | Configuration | Location | Risk |
|---|---|---|---|
| 1 | Debian 10 Buster (EOL Jun 2024) | mongodb-vm OS | No security patches |
| 2 | MongoDB 4.4 (EOL Feb 2024) | mongodb-vm | Known unpatched CVEs |
| 3 | SSH open to `0.0.0.0/0` | mongodb NSG | Any IP can attempt SSH |
| 4 | Contributor role on managed identity | mongodb-vm | Can create/delete any resource |
| 5 | Storage container `container` access | Blob Storage | Backups downloadable by anyone |
| 6 | `privileged: true` | k8s pod spec | Container reads host filesystem |
| 7 | `cluster-admin` ClusterRoleBinding | k8s RBAC | Pod controls entire cluster |
| 8 | MongoDB `bindIp: 0.0.0.0` | mongod.conf | Listens on all interfaces |

---

## Security Controls

| Type | Control | Implementation |
|---|---|---|
| **Audit** | Activity Log → Log Analytics | `az monitor diagnostic-settings subscription create` |
| **Preventative** | Deny new public blob storage | Azure Policy `4fa4b6c0-31ca-4c0d-b10d-24b96f62a751` |
| **Detective** | Defender for Cloud | Servers + Storage + Containers (Standard tier) |

> **Note:** Defender Standard cannot be activated via CLI in CloudLabs.  
> Activate manually: `portal.azure.com → Defender for Cloud → Environment settings → Enable all plans`

---

## CI/CD Pipelines

### Pipeline 1 — IaC Security (`01-iac.yml`)
```
Trigger: push/PR on terraform/**
1. Checkov — scans terraform/ → finds all 8 weak configs (expected findings)
2. terraform plan  (on PR)
3. terraform apply (on push) ← blocked in CloudLabs: no Service Principal
```

### Pipeline 2 — Container Security (`02-container.yml`)
```
Trigger: push/PR on app/**
1. Build Docker image locally
2. Trivy — CVE scan before pushing to registry (SARIF → GitHub Security tab)
3. Push to ACR
4. Rolling deploy to k3s via az vm run-command
```

**Branch protection:** Checkov + Trivy must pass before merge to `main`. 1 PR review required.

---

## How to run kubectl from Cloud Shell

`kubectl` cannot run directly in Cloud Shell — k3s-vm has no public IP.  
All kubectl commands go through `az vm run-command`:

```bash
source ~/wiz-outputs.txt

# Example: get pods
az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml && kubectl get pods -o wide" \
  --query "value[0].message" -o tsv | grep -v "^\[std"
```

---

## Demo Commands

```bash
source ~/wiz-outputs.txt

# ── Cluster state ──────────────────────────────────────────────
az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    && kubectl get nodes,pods,svc,ingress -o wide" \
  --query "value[0].message" -o tsv | grep -v "^\[std"

# ── wizexercise.txt in running container (REQ-15/16) ───────────
az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    && POD=\$(kubectl get pod -l app=todo-app -o name | head -1) \
    && kubectl exec \$POD -- cat /app/wizexercise.txt" \
  --query "value[0].message" -o tsv | grep -v "^\[std"

# ── Add a todo via the app ──────────────────────────────────────
az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    && POD=\$(kubectl get pod -l app=todo-app -o name | head -1) \
    && kubectl exec \$POD -- curl -sf -X POST http://localhost:3000/todos \
       -H 'Content-Type: application/json' -d '{\"text\":\"Wiz demo\"}'" \
  --query "value[0].message" -o tsv | grep -v "^\[std"

# ── Confirm data in MongoDB ─────────────────────────────────────
az vm run-command invoke -g "$RG_NAME" -n "$MONGO_VM" \
  --command-id RunShellScript \
  --scripts "/usr/local/bin/mongo \
    'mongodb://wizadmin:WizPassword123!@localhost:27017/todos?authSource=admin' \
    --eval 'db.todos.find().pretty()' --quiet" \
  --query "value[0].message" -o tsv | grep -v "^\[std"

# ── Public backup storage (open in browser) ─────────────────────
echo "https://${STORAGE}.blob.core.windows.net/mongodb-backups?restype=container&comp=list"

# ── Log Analytics query ─────────────────────────────────────────
# Run in portal: portal.azure.com → Log Analytics → wiz-logs-XX → Logs
# AzureActivity | where TimeGenerated > ago(1h) | order by TimeGenerated desc | take 20

# ── cluster-admin RBAC proof ────────────────────────────────────
az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    && kubectl get clusterrolebinding todo-app-cluster-admin \
       -o jsonpath='{.subjects[0].name} → {.roleRef.name}'" \
  --query "value[0].message" -o tsv | grep -v "^\[std"

# ── Privileged container host escape proof ──────────────────────
az vm run-command invoke -g "$RG_NAME" -n "$K3S_VM" \
  --command-id RunShellScript \
  --scripts "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
    && POD=\$(kubectl get pod -l app=todo-app -o name | head -1) \
    && kubectl exec \$POD -- ls /proc/1/root/etc/ | head -5" \
  --query "value[0].message" -o tsv | grep -v "^\[std"

# ── Managed identity IMDS token (Contributor role abuse) ────────
az vm run-command invoke -g "$RG_NAME" -n "$MONGO_VM" \
  --command-id RunShellScript \
  --scripts "curl -sf -H 'Metadata:true' \
    'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://management.azure.com/' \
    | python3 -c \"import sys,json;print('Token:',json.load(sys.stdin)['access_token'][:30]+'...')\"" \
  --query "value[0].message" -o tsv | grep -v "^\[std"
```

---

## Attack Simulation (REQ-25)

Runs automatically at end of `deploy.sh`. Shows full commands for each attack:

```bash
source ~/wiz-outputs.txt
bash ~/wiz-exercise/attack-sim.sh
```

| Attack | Weak Config | Expected Defender Alert |
|---|---|---|
| 1 — MongoDB port probe | `bindIp: 0.0.0.0` | Network port exposed |
| 2 — Credential access | `WizPassword123!` | Suspicious authentication |
| 3 — Storage exfiltration | Public blob | Publicly accessible storage |
| 4 — Container host escape | `privileged: true` | Privileged container detected |
| 5 — cluster-admin enum | `cluster-admin` RBAC | Overly permissive RBAC |
| 6 — IMDS token abuse | Contributor role | Suspicious IMDS access |

---

## Validation (39 checks)

```bash
bash ~/wiz-exercise/validate.sh
```

Each check shows: what is being verified, the full `az vm run-command` to run it manually, and the actual result.

```
  REQ-07  SSH exposed to entire internet (NSG source = 0.0.0.0/0)
  Command (run from Cloud Shell):
    az network nsg rule show -g "$RG_NAME" --nsg-name mongodb-nsg \
      -n Allow-SSH-Internet --query sourceAddressPrefix -o tsv
  Result : *
  [PASS] REQ-07  SSH open to internet
```

---

## CloudLabs Sandbox Limitations

```bash
bash ~/wiz-exercise/sandbox-limits.sh
```

| Limitation | Affected | Workaround |
|---|---|---|
| Public IPs blocked | REQ-03b | Show Ingress + `curl localhost:3000` from pod |
| Defender Standard blocked via CLI | REQ-28 | Activate via portal → Environment settings |
| Service Principal blocked | REQ-22 (partial) | Show Checkov scan in GitHub Actions |
| Cloud Shell 20min timeout | All long ops | Use `tmux new -s deploy` |

---

## File Reference

| File | Purpose |
|---|---|
| `deploy.sh` | Single entry point — 7 steps + attack simulation |
| `validate.sh` | 39 PDF requirement checks with full commands shown |
| `attack-sim.sh` | 6 attacks with full commands + real output |
| `sandbox-limits.sh` | CloudLabs restrictions vs PDF requirements |
| `cleanup.sh` | Deletes ALL Azure resources + Cloud Shell storage + logout |
| `github.sh` | GitHub-only setup (fallback if deploy interrupted) |
| `scripts/01-mongodb.sh` | MongoDB 4.4 on Debian 10 Buster via tarball |
| `scripts/02-backup.sh` | Daily backup cron to public Azure Blob |
| `scripts/03-k3s.sh` | k3s + nginx Ingress + todo-app deploy |
| `terraform/main.tf` | All Azure infrastructure |
| `app/Dockerfile` | `CANDIDATE_NAME` build arg → `wizexercise.txt` |
| `app/index.js` | Express app: `GET/POST /todos`, `GET /health` |
| `.github/workflows/01-iac.yml` | Checkov + terraform pipeline |
| `.github/workflows/02-container.yml` | Trivy + ACR + k3s rolling deploy |

---

## Candidate

**WeberRess** — Wiz Technical Exercise v5  
Deployed entirely via Azure Cloud Shell — no local tooling required.
