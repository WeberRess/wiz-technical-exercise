#!/bin/bash
# =============================================================================
# github.sh — Push code to GitHub + configure CI/CD pipelines
#
# Run this AFTER deploy.sh completes:
#   export GITHUB_TOKEN=ghp_xxxx
#   bash ~/wiz-exercise/github.sh
#
# Runs in Cloud Shell (Ubuntu-based) — NOT on the Debian VMs.
# All gh/git commands have explicit timeouts so nothing blocks forever.
# =============================================================================

source ~/wiz-outputs.txt 2>/dev/null \
  || { echo "ERROR: ~/wiz-outputs.txt not found. Run deploy.sh first."; exit 1; }

[ -z "${GITHUB_TOKEN:-}" ] \
  && { echo "ERROR: GITHUB_TOKEN not set."; echo "  export GITHUB_TOKEN=ghp_xxxx"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="wiz-technical-exercise"
GITHUB_USER="${YOUR_NAME:-WeberRess}"

echo "================================================"
echo " GitHub Setup"
echo " User    : $GITHUB_USER"
echo " Repo    : $REPO"
echo " Started : $(date '+%H:%M:%S')"
echo "================================================"

# -----------------------------------------------------------------------
# Auth
# -----------------------------------------------------------------------
echo "$GITHUB_TOKEN" | timeout 15 gh auth login --with-token 2>/dev/null \
  && echo "[ok] Authenticated as $GITHUB_USER"

# -----------------------------------------------------------------------
# Service Principal (30s timeout — CloudLabs often blocks this)
# -----------------------------------------------------------------------
echo "[..] Creating Service Principal..."
SP_JSON=$(timeout 30 az ad sp create-for-rbac \
  --name "wiz-exercise-sp" --role Contributor \
  --scopes "/subscriptions/$SUB_ID/resourceGroups/$RG_NAME" \
  --sdk-auth --output json 2>/dev/null || echo "")

[ -z "$SP_JSON" ] && {
  echo "[skip] SP unavailable (CloudLabs) — terraform apply in Pipeline 1 will fail"
  SP_JSON="{\"clientId\":\"MANUAL\",\"clientSecret\":\"MANUAL\",\"subscriptionId\":\"$SUB_ID\",\"tenantId\":\"MANUAL\"}"
}
CLIENT_ID=$(echo "$SP_JSON" \
  | python3 -c "import sys,json;print(json.load(sys.stdin).get('clientId',''))" 2>/dev/null)

# -----------------------------------------------------------------------
# Git: init, commit
# -----------------------------------------------------------------------
cd "$SCRIPT_DIR"

# Never commit the Terraform provider cache (can be 300MB)
rm -rf terraform/.terraform 2>/dev/null || true

# Configure git credential so push doesn't ask for password
git config --global \
  url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
printf 'https://%s:%s@github.com\n' "$GITHUB_USER" "$GITHUB_TOKEN" \
  > ~/.git-credentials
git config credential.helper store
git config --global user.email "${GITHUB_USER}@users.noreply.github.com"
git config --global user.name  "$GITHUB_USER"

  # Always reinit cleanly — avoids stale .git from previous deploys
  rm -rf .git
  git init -q
  git checkout -b main 2>/dev/null || true

git add -A
git commit -m "Wiz Technical Exercise v5 — $(date +%Y-%m-%d)" \
  --allow-empty -q 2>/dev/null
echo "[ok] Code committed"

# -----------------------------------------------------------------------
# Create GitHub repo and push
# -----------------------------------------------------------------------
echo "[..] Creating GitHub repo..."
timeout 30 gh repo delete "$GITHUB_USER/$REPO" --yes 2>/dev/null || true
sleep 2

# Create repo without --push, then push manually with timeout
timeout 30 gh repo create "$REPO" \
  --public \
  --description "Wiz Technical Exercise v5" 2>/dev/null \
  && echo "[ok] Repo created" \
  || { echo "[FAIL] Could not create repo"; exit 1; }

# Set remote and push
git remote remove origin 2>/dev/null || true
git remote add origin \
  "https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO}.git"

echo "[..] Pushing to GitHub..."
timeout 60 git push -u origin main --force 2>&1 \
  && echo "[ok] Code pushed" \
  || { echo "[WARN] Push failed — check token and try: cd ~/wiz-exercise && git push -u origin main"; }

echo "  Repo: https://github.com/$GITHUB_USER/$REPO"

# -----------------------------------------------------------------------
# Secrets
# -----------------------------------------------------------------------
echo "[..] Setting secrets..."
_s() {
  local NAME="$1" VAL="$2"
  [ -z "$VAL" ] || [ "$VAL" = "MANUAL" ] && { echo "  [skip] $NAME"; return; }
  timeout 15 gh secret set "$NAME" --body "$VAL" \
    --repo "$GITHUB_USER/$REPO" 2>/dev/null \
    && echo "  [ok] $NAME" || echo "  [fail] $NAME"
}
_s AZURE_CREDENTIALS   "$SP_JSON"
_s ARM_CLIENT_ID       "$CLIENT_ID"
_s ARM_SUBSCRIPTION_ID "$SUB_ID"
_s VM_SSH_PUBLIC_KEY   "$(cat ~/.ssh/id_rsa.pub 2>/dev/null)"
_s CANDIDATE_NAME      "$YOUR_NAME"
_s ACR_NAME            "$ACR_NAME"

# -----------------------------------------------------------------------
# Branch protection
# -----------------------------------------------------------------------
echo "[..] Branch protection..."
printf '{"required_status_checks":{"strict":true,"contexts":["Checkov IaC scan","Trivy container scan"]},"enforce_admins":false,"required_pull_request_reviews":{"required_approving_review_count":1,"dismiss_stale_reviews":true},"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}' \
  | timeout 15 gh api --method PUT \
    -H "Accept: application/vnd.github+json" \
    "/repos/${GITHUB_USER}/${REPO}/branches/main/protection" \
    --input - 2>/dev/null \
  && echo "[ok] Branch protection (Checkov + Trivy required)" \
  || echo "[skip] Branch protection (needs admin scope)"

# -----------------------------------------------------------------------
# Trigger pipelines
# -----------------------------------------------------------------------
echo "[..] Triggering pipelines..."
sleep 3
timeout 15 gh workflow run "01-iac.yml" \
  --repo "$GITHUB_USER/$REPO" --ref main 2>/dev/null \
  && echo "[ok] Pipeline 1 triggered (Checkov + terraform)" \
  || echo "[skip] Pipeline 1"

timeout 15 gh workflow run "02-container.yml" \
  --repo "$GITHUB_USER/$REPO" --ref main 2>/dev/null \
  && echo "[ok] Pipeline 2 triggered (Trivy + ACR + k3s)" \
  || echo "[skip] Pipeline 2"

echo ""
echo "================================================"
echo " Done! $(date '+%H:%M:%S')"
echo " Repo    : https://github.com/$GITHUB_USER/$REPO"
echo " Actions : https://github.com/$GITHUB_USER/$REPO/actions"
echo "================================================"
