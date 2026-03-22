#!/bin/bash
# =============================================================================
# 01-mongodb.sh — Install MongoDB 4.4 on Debian 10 Buster
#
# PDF Requirements satisfied:
#   REQ-06: Debian 10 Buster reached EOL June 2024 (1+ year outdated OS)
#   REQ-09: MongoDB 4.4 reached EOL February 2024 (1+ year outdated database)
#   REQ-10: authentication enabled; network access restricted by NSG rule
#
# WHY TARBALL INSTEAD OF APT:
#   MongoDB's apt repository only supports Ubuntu codenames (focal, bionic).
#   On Debian 10 Buster, the apt repository fails. We download the official
#   pre-built binary tarball from fastdl.mongodb.org instead — same binaries,
#   no apt dependency.
#
# WHY NO set -e:
#   We want to see every step's output and exit code. set -e would kill the
#   script silently on any non-zero exit, making debugging impossible.
#
# BLOB URL ENV VARS (set by deploy.sh for faster download):
#   MONGO_TGZ_URL  — blob URL of mongodb tarball (Azure internal network)
#   TOOLS_TGZ_URL  — blob URL of mongotools tarball
#   If not set, falls back to direct download from fastdl.mongodb.org.
# =============================================================================

LOG=/var/log/wiz-mongodb-install.log

# Log to both stdout (visible in Cloud Shell via run-command) and file
exec > >(tee "$LOG") 2>&1

echo "=== MongoDB 4.4 install on Debian 10 Buster ==="
echo "Start: $(date)"
echo "OS: $(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2)"

# -----------------------------------------------------------------------
# Step 1: Fix Debian 10 Buster EOL repositories
#
# Debian 10 Buster reached EOL June 2024. The standard Debian mirrors
# (security.debian.org, deb.debian.org) no longer host Buster packages.
# Azure's Debian 10 image points to trafficmanager.net mirrors which also
# no longer have Buster. We redirect to archive.debian.org which keeps
# all EOL releases indefinitely.
# -----------------------------------------------------------------------
echo ""
echo "--- Step 1/6: Fix Debian 10 Buster EOL apt repos ---"

cat > /etc/apt/sources.list << 'SOURCES'
deb http://archive.debian.org/debian           buster           main contrib non-free
deb http://archive.debian.org/debian-security  buster/updates   main
SOURCES

# archive.debian.org packages have expired Release files by design.
# This flag tells apt to accept them anyway.
echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99archive

apt-get update -qq
echo "apt-get update exit code: $?"

DEBIAN_FRONTEND=noninteractive apt-get install -y wget curl ca-certificates
echo "deps install exit code: $?"

# -----------------------------------------------------------------------
# Step 2: Download MongoDB 4.4.29 binaries
#
# deploy.sh downloads the tarball first in Cloud Shell then uploads to blob
# in Cloud Shell and uploads to Azure Blob, then passes the blob URL here
# via MONGO_TGZ_URL. The VM then downloads from blob (Azure internal
# network — much faster and more reliable than the public internet).
# -----------------------------------------------------------------------
echo ""
echo "--- Step 2/6: Download MongoDB 4.4.29 ---"
cd /tmp

MONGO_URL="${MONGO_TGZ_URL:-https://fastdl.mongodb.org/linux/mongodb-linux-x86_64-debian10-4.4.29.tgz}"
echo "Source: $MONGO_URL"
wget -q --timeout=300 --tries=3 "$MONGO_URL" -O mongodb.tgz
echo "wget exit code: $?"
ls -lh mongodb.tgz 2>/dev/null || echo "ERROR: mongodb.tgz not found"

TOOLS_URL="${TOOLS_TGZ_URL:-https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian10-x86_64-100.9.5.tgz}"
echo "Source: $TOOLS_URL"
wget -q --timeout=180 --tries=3 "$TOOLS_URL" -O mongotools.tgz
echo "wget exit code: $?"
ls -lh mongotools.tgz 2>/dev/null || echo "ERROR: mongotools.tgz not found"

# -----------------------------------------------------------------------
# Step 3: Extract and install binaries
# -----------------------------------------------------------------------
echo ""
echo "--- Step 3/6: Install binaries to /usr/local/bin ---"

# Test tarball integrity before extracting
tar -tzf mongodb.tgz > /dev/null 2>&1
echo "mongodb.tgz integrity check exit code: $?"

MONGO_DIR=$(tar -tzf mongodb.tgz 2>/dev/null | head -1 | cut -d/ -f1)
echo "MongoDB archive dir: $MONGO_DIR"

tar -xzf mongodb.tgz
echo "tar extract exit code: $?"

# Use /usr/local/bin — avoids conflicts with any system packages
cp "$MONGO_DIR/bin/mongod"  /usr/local/bin/mongod  && chmod +x /usr/local/bin/mongod
cp "$MONGO_DIR/bin/mongo"   /usr/local/bin/mongo   2>/dev/null && chmod +x /usr/local/bin/mongo || echo "mongo shell not in this build"
echo "mongod copy exit code: $?"

TOOLS_DIR=$(tar -tzf mongotools.tgz 2>/dev/null | head -1 | cut -d/ -f1)
tar -xzf mongotools.tgz
cp "$TOOLS_DIR/bin/mongodump"    /usr/local/bin/mongodump    && chmod +x /usr/local/bin/mongodump
cp "$TOOLS_DIR/bin/mongorestore" /usr/local/bin/mongorestore 2>/dev/null && chmod +x /usr/local/bin/mongorestore || true
echo "mongodump copy exit code: $?"

# Verify binaries work
echo "mongod version: $(/usr/local/bin/mongod --version 2>&1 | head -1)"
echo "mongodump version: $(/usr/local/bin/mongodump --version 2>&1 | head -1)"

rm -rf /tmp/mongodb.tgz /tmp/mongotools.tgz /tmp/"$MONGO_DIR" /tmp/"$TOOLS_DIR"

# -----------------------------------------------------------------------
# Step 4: Create user, directories, config
# -----------------------------------------------------------------------
echo ""
echo "--- Step 4/6: Create user, dirs, config ---"

useradd -r -s /bin/false -d /var/lib/mongodb mongodb 2>/dev/null || echo "user already exists"
mkdir -p /var/lib/mongodb /var/log/mongodb
chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb

# MongoDB needs /usr/share/zoneinfo for timezone support
DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive tzdata 2>/dev/null || true

cat > /etc/mongod.conf << 'CONF'
storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  logAppend: true

net:
  port: 27017
  # INTENTIONAL WEAK CONFIG (REQ-09): bind to all interfaces.
  # Network-level restriction is handled by the NSG rule:
  # Allow-MongoDB-PrivateSubnet allows port 27017 only from 10.0.2.0/24.
  bindIp: 0.0.0.0

security:
  # Start with auth disabled so we can create the admin user.
  # Step 5 enables it after user creation.
  authorization: disabled
CONF

echo "mongod.conf written"

# -----------------------------------------------------------------------
# Step 5: Create systemd service and start MongoDB
# -----------------------------------------------------------------------
echo ""
echo "--- Step 5/6: Create systemd service and start ---"

cat > /etc/systemd/system/mongod.service << 'SERVICE'
[Unit]
Description=MongoDB 4.4 Database Server
After=network.target

[Service]
User=mongodb
Group=mongodb
ExecStart=/usr/local/bin/mongod --config /etc/mongod.conf
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable mongod
systemctl start mongod
echo "systemctl start exit code: $?"

# Wait up to 60 seconds for MongoDB to be ready
echo "Waiting for MongoDB..."
for i in $(seq 1 20); do
  if /usr/local/bin/mongo --eval "db.runCommand({ping:1})" --quiet 2>/dev/null; then
    echo "MongoDB ready after ${i} attempts"
    break
  fi
  echo "  attempt $i/20..."
  sleep 3
done

# -----------------------------------------------------------------------
# Step 6: Create admin user and enable authentication
#
# REQ-10: MongoDB must require database authentication.
# We create the admin user first (with auth disabled), then enable auth.
# After restart, unauthenticated access returns "Unauthorized".
# -----------------------------------------------------------------------
echo ""
echo "--- Step 6/6: Create admin user, enable authentication ---"

/usr/local/bin/mongo admin << 'MONGO'
db.createUser({
  user: "wizadmin",
  pwd:  "WizPassword123!",
  roles: [{ role: "root", db: "admin" }]
});
print("user created");
MONGO
echo "createUser exit code: $?"

# Enable authentication in mongod.conf
sed -i 's/authorization: disabled/authorization: enabled/' /etc/mongod.conf
systemctl restart mongod
echo "restart exit code: $?"
sleep 8

# Verify: authenticated access should work
/usr/local/bin/mongo "mongodb://wizadmin:WizPassword123!@localhost:27017/admin?authSource=admin" \
  --eval "print('Auth OK: ' + db.version())" --quiet 2>&1
echo "auth verify exit code: $?"

# Verify: unauthenticated access should be denied (REQ-10)
UNAUTH=$(/usr/local/bin/mongo --eval "db.adminCommand({listDatabases:1})" --quiet 2>&1)
echo "Unauthenticated test: $UNAUTH" | grep -qi "unauthorized" \
  && echo "[OK] Unauthenticated access correctly denied" \
  || echo "[WARN] Unauthenticated access result: $UNAUTH"

echo ""
echo "=== MongoDB install complete ==="
echo "Version : $(/usr/local/bin/mongod --version 2>&1 | head -1)"
echo "Status  : $(systemctl is-active mongod)"
echo "Auth    : enabled (REQ-10)"
echo "Bind    : 0.0.0.0 (weak config — NSG restricts to 10.0.2.0/24)"
echo "End: $(date)"
