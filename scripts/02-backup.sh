#!/bin/bash
# =============================================================================
# 02-backup.sh — Configure daily MongoDB backups to Azure Blob Storage
#
# PDF Requirements satisfied:
#   REQ-05: backups stored in public-readable cloud object storage
#   REQ-11: automated daily backup (cron at 02:00 AM)
#   REQ-12: storage container allows public read and listing
#
# HOW UPLOAD WORKS (no Azure CLI on the VM):
#   The VM has a managed identity with Storage Blob Data Contributor role
#   (assigned by Terraform). We get a token from the IMDS endpoint
#   (169.254.169.254) and upload via the Azure Blob Storage REST API using
#   curl. No az CLI or azcopy installation required.
#
# STORAGE_ACCOUNT is injected by deploy.sh via sed before upload.
# =============================================================================

MONGO_USER="wizadmin"
MONGO_PASS="WizPassword123!"
STORAGE_ACCOUNT="STORAGE_ACCOUNT_PLACEHOLDER"
CONTAINER="mongodb-backups"

echo "=== Configuring daily MongoDB backup ==="

# -----------------------------------------------------------------------
# Write the backup script that cron will execute daily
# Uses curl + managed identity token to upload — no az CLI needed
# -----------------------------------------------------------------------
cat > /usr/local/bin/mongodb-backup.sh << 'SCRIPT'
#!/bin/bash
# Daily MongoDB backup — runs via cron at 02:00 AM
STORAGE_ACCOUNT="STORAGE_ACCOUNT_PLACEHOLDER"
CONTAINER="mongodb-backups"
MONGO_USER="wizadmin"
MONGO_PASS="WizPassword123!"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DUMP_DIR=/tmp/mongo-dump-$TIMESTAMP
ARCHIVE=/tmp/backup-$TIMESTAMP.tar.gz

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

log "Starting MongoDB backup..."

# Dump all databases
/usr/local/bin/mongodump \
  --uri="mongodb://${MONGO_USER}:${MONGO_PASS}@localhost:27017/?authSource=admin" \
  --out="$DUMP_DIR" 2>&1

tar -czf "$ARCHIVE" -C /tmp "mongo-dump-$TIMESTAMP"
log "Archive: $(ls -lh $ARCHIVE | awk '{print $5}')"

# Get managed identity token from Azure IMDS
# The VM has Storage Blob Data Contributor role (assigned by Terraform)
log "Getting managed identity token..."
TOKEN=$(curl -sf \
  -H "Metadata:true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null)

if [ -z "$TOKEN" ]; then
  log "ERROR: Could not get managed identity token"
  exit 1
fi

# Upload to Azure Blob Storage via REST API (no az CLI needed)
BLOB_NAME="backup-$TIMESTAMP.tar.gz"
BLOB_URL="https://${STORAGE_ACCOUNT}.blob.core.windows.net/${CONTAINER}/${BLOB_NAME}"
DATE=$(date -u '+%a, %d %b %Y %H:%M:%S GMT')

HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
  -X PUT \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-ms-blob-type: BlockBlob" \
  -H "x-ms-date: $DATE" \
  -H "x-ms-version: 2020-04-08" \
  -H "Content-Type: application/gzip" \
  --data-binary "@$ARCHIVE" \
  "$BLOB_URL")

if [ "$HTTP_CODE" = "201" ]; then
  log "Uploaded: $BLOB_NAME (HTTP $HTTP_CODE)"
  log "Public URL: $BLOB_URL"
else
  log "ERROR: Upload failed (HTTP $HTTP_CODE)"
  exit 1
fi

rm -rf "$DUMP_DIR" "$ARCHIVE"
log "Done."
SCRIPT

# Inject storage account name into backup script
sed -i "s/STORAGE_ACCOUNT_PLACEHOLDER/$STORAGE_ACCOUNT/g" \
  /usr/local/bin/mongodb-backup.sh
chmod +x /usr/local/bin/mongodb-backup.sh

# Schedule via cron (REQ-11: daily at 02:00 AM)
echo "0 2 * * * root /usr/local/bin/mongodb-backup.sh >> /var/log/mongodb-backup.log 2>&1" \
  > /etc/cron.d/mongodb-backup
chmod 644 /etc/cron.d/mongodb-backup

echo "Cron scheduled: daily at 02:00 AM"
echo "Storage: $STORAGE_ACCOUNT/$CONTAINER (PUBLIC — REQ-12)"
echo "Script: /usr/local/bin/mongodb-backup.sh"
