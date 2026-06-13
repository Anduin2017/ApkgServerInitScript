#!/bin/bash

#=============================================================================
# AnduinOS Edge Mirror — One-Shot Idempotent Deployer
#
# This script is safe to run repeatedly on the same server.  Every run will:
#   • install any missing system packages
#   • overwrite every config file with the canonical version (self-healing)
#   • pull the latest Docker images
#   • bring containers up if they are down, or recreate them if config changed
#   • leave the existing /opt/anduinos-edge/data untouched
#
# The only destructive action is killing an unknown process on port 80 —
# once the deployment is up, docker-proxy owns that port and re-runs skip it.
#=============================================================================

#==========================
# Basic Information
#==========================
export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export DEBIAN_FRONTEND=noninteractive

#==========================
# Color & UI
#==========================
Green="\033[32m"
Red="\033[31m"
Yellow="\033[33m"
Blue="\033[36m"
Font="\033[0m"
GreenBG="\033[42;37m"
RedBG="\033[41;37m"
OK="${Green}[  OK  ]${Font}"
ERROR="${Red}[FAILED]${Font}"
WARNING="${Yellow}[ WARN ]${Font}"

function print_ok() {
  echo -e "${OK} ${Blue} $1 ${Font}"
}

function print_error() {
  echo -e "${ERROR} ${Red} $1 ${Font}"
}

function judge() {
  if [[ 0 -eq $? ]]; then
    print_ok "$1 succeeded"
    sleep 1
  else
    print_error "$1 failed"
    exit 1
  fi
}

function areYouSure() {
  print_error "This script found some issue and failed to run."
  print_error "Are you sure to continue the installation? Enter [y/N] to continue"
  read -r install
  case $install in
  [yY][eE][sS] | [yY])
    print_ok "Continuing the installation..."
    ;;
  *)
    print_error "Installation terminated."
    exit 1
    ;;
  esac
}

function port_exist_check() {
  if [[ 0 -eq $(sudo ss -tlnp "sport = :$1" | grep -c ":$1") ]]; then
    print_ok "Port $1 is not in use"
    return 0
  fi

  # On re-run, port 80 may be held by our own Docker Caddy container.
  # Recognise it by the docker-proxy process name and skip killing.
  if sudo ss -tlnp "sport = :$1" | grep -q "docker-proxy"; then
    print_ok "Port $1 is managed by Docker (existing deployment, will refresh)"
    return 0
  fi

  print_error "Warning: Port $1 is occupied by an unknown process"
  sudo ss -tlnp "sport = :$1"
  print_error "Will kill the occupied process in 5s..."
  sleep 5
  sudo ss -tlnp "sport = :$1" | grep -oP 'pid=\K[0-9]+' | sudo xargs kill -9
  print_ok "Killed the occupied process on port $1"
}

#==========================
# Begin of the installation
#==========================
clear
cd ~
echo -e "${Green}========================================================================${Font}"
echo -e "${Blue}  Welcome to AnduinOS Edge Node Automated Installer${Font}"
echo -e "${Blue}  Architecture: Pure HTTP Caddy + Rclone Atomic Sync + Cloudflare${Font}"
echo -e "${Green}========================================================================${Font}"
print_ok "Please press [ENTER] to continue, or press CTRL+C to cancel."
read

#==========================
# Check OS Version
#==========================
print_ok "Checking OS version..."
if ! lsb_release -a | grep -E "Ubuntu (24|25|26)" > /dev/null; then
  print_error "You do not seem to be running Ubuntu 24.04/25.04/26.04."
  areYouSure
fi
judge "OS Check Passed"

#==========================
# Test network
#==========================
print_ok "Testing network connection..."
if ! curl -s --head --request GET https://cloudflare.com/cdn-cgi/trace | grep "200" > /dev/null; then
  print_error "You are not able to access Internet. Please check your network!"
  areYouSure
fi
judge "Network connection works"

#==========================
# Check Port 80
#==========================
print_ok "Checking Port 80 for Caddy..."
port_exist_check 80
judge "Port 80 is clear"

#==========================
# Update and Install Dependencies
#==========================
print_ok "Installing basic packages and Docker..."
DEBIAN_FRONTEND=noninteractive sudo apt update
DEBIAN_FRONTEND=noninteractive sudo apt install -y curl wget git vim net-tools ufw apt-transport-https ca-certificates software-properties-common

# Install Docker
if ! command -v docker >/dev/null 2>&1; then
    print_ok "Docker not found, installing via official script..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    rm get-docker.sh
else
    print_ok "Docker is already installed."
fi
# Ensure docker compose plugin is installed
DEBIAN_FRONTEND=noninteractive sudo apt install -y docker-compose-plugin

# Ensure Docker daemon is running (may be stopped on re-run)
# Also ensure it starts on boot (defence in depth for VPS templates)
sudo systemctl enable docker 2>/dev/null || true
if ! sudo systemctl is-active --quiet docker; then
    print_ok "Docker daemon not running, starting..."
    sudo systemctl start docker
fi
judge "Basic packages and Docker installed"

#==========================
# System Optimizations (BBR)
#==========================
enable_bbr_force()
{
    print_ok "Enabling BBR..."
    echo 'net.core.default_qdisc=fq' | sudo tee -a /etc/sysctl.conf
    echo 'net.ipv4.tcp_congestion_control=bbr' | sudo tee -a /etc/sysctl.conf
    sudo sysctl -p
    judge "BBR Enabled"
}
sysctl net.ipv4.tcp_available_congestion_control | grep -q bbr || enable_bbr_force
print_ok "BBR is active"

echo "Setting timezone to UTC..."
sudo timedatectl set-timezone UTC

#==========================
# Firewall (UFW)
#==========================
print_ok "Configuring UFW firewall..."
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
echo "y" | sudo ufw enable
judge "UFW configured"

#==========================
# Build AnduinOS Edge Environment
#==========================
WORKDIR="/opt/anduinos-edge"
print_ok "Creating work directory at $WORKDIR..."
sudo mkdir -p $WORKDIR/data
cd $WORKDIR

# 1. Generate docker-compose.yml
print_ok "Generating Docker Compose config..."
sudo bash -c "cat > docker-compose.yml" << 'EOF'
services:
  caddy-server:
    image: caddy:alpine
    container_name: anduinos_caddy
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./data:/data:ro
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    depends_on:
      rclone-worker:
        condition: service_healthy

  rclone-worker:
    image: rclone/rclone:latest
    container_name: anduinos_sync
    restart: unless-stopped
    entrypoint: ["/bin/sh"]
    command: ["/sync-logic.sh"]
    volumes:
      - ./data:/data
      - ./sync-logic.sh:/sync-logic.sh:ro
    healthcheck:
      test: ["CMD", "test", "-f", "/data/current/sync_status.json"]
      interval: 30s
      timeout: 5s
      retries: 60
      start_period: 7200s
EOF

# 2. Generate Caddyfile (Pure HTTP)
# Cache strategy:
#   - dists/ : APT metadata (InRelease, Packages, etc.) — never cache (forces revalidation)
#   - pool/  : .deb packages — content-addressed, immutable, cache forever
print_ok "Generating pure HTTP Caddyfile..."
sudo bash -c "cat > Caddyfile" << 'EOF'
:80 {
    root * /data/current
    file_server browse {
        hide _tmp .prev .partial .tmp
    }
    encode zstd gzip

    # Default — force revalidation for everything except .deb
    header * Cache-Control "no-cache"

    # .deb packages — content-addressed, immutable
    header /artifacts/anduinos/*/pool/*.deb Cache-Control "public, max-age=31536000, immutable"
}
EOF

# 3. Generate Rclone Atomic Sync Script
#
# Symlink-based atomic swap:
#
#   /data/current  – symlink → primary  or  secondary (Caddy serves this)
#   /data/primary  – offline directory A
#   /data/secondary – offline directory B
#
# Flow:
#   1. readlink to find the active directory; sync to the OTHER one
#   2. Clean .partial leftovers from the staging directory (anti-poison)
#   3. rclone sync into staging → only changed files transferred (incremental)
#   4. Strip BOM from InRelease / Release
#   5. ln -sfn staging /data/current   ← one renameat2, genuinely atomic
#
# Because staging always contains the previous cycle's data, rclone
# compares source vs. an almost-identical destination and transfers only
# what actually changed.  The first run (empty staging) does a full download;
# every subsequent run is incremental.
#
# Idempotent / self-healing properties:
#   - mkdir -p primary/secondary    → safe to run repeatedly
#   - ln -sfn                       → overwrites any existing symlink
#   - Migration from old /data/www  → moves it into secondary, once
#   - readlink fallback             → handles missing symlink gracefully
#
print_ok "Generating Atomic Sync logic..."
sudo bash -c "cat > sync-logic.sh" << 'EOF'
#!/bin/sh

SOURCE_URL="https://apkg-dav.aiursoft.com/"

echo "[$(date)] [INIT] Rclone worker started."

# ── One-time migration from old layout ──────────────────────────
if [ -d /data/www ] && [ ! -L /data/current ]; then
    echo "[$(date)] [MIGRATE] Moving old /data/www → /data/secondary..."
    mv /data/www /data/secondary 2>/dev/null || true
    mkdir -p /data/primary
    ln -sfn /data/secondary /data/current
    echo "[$(date)] [MIGRATE] Done."
fi

while true; do
    echo "[$(date)] [CYCLE] Starting sync cycle..."

    # ── Mutual exclusion ─────────────────────────────────────────
    # Prevent two sync processes from writing to the same staging
    # directory simultaneously (e.g. docker exec + main loop).
    # The lock fd is released automatically by the kernel on exit.
    #
    # BusyBox flock does not support -w; we implement our own
    # wait loop with -n (non-blocking).
    exec 200>/tmp/sync.lock
    LOCK_WAITED=0
    while ! flock -n 200 2>/dev/null; do
        sleep 10
        LOCK_WAITED=$((LOCK_WAITED + 10))
        if [ $LOCK_WAITED -ge 7200 ]; then
            echo "[$(date)] [LOCK] Timed out (2h). Skipping this cycle."
            exec 200>&-
            continue 2
        fi
    done
    echo "[$(date)] [LOCK] Acquired (waited ${LOCK_WAITED}s)."

    # Ensure base directories exist (idempotent)
    mkdir -p /data/primary /data/secondary

    # Determine active directory and staging target
    CURRENT=$(readlink /data/current 2>/dev/null || echo "/data/primary")
    if [ "$CURRENT" = "/data/primary" ]; then
        STAGING="/data/secondary"
    else
        STAGING="/data/primary"
    fi

    # Create symlink if missing (self-healing)
    if [ ! -L /data/current ]; then
        echo "[$(date)] [HEAL] Symlink missing — recreating."
        ln -sfn "$STAGING" /data/current
    fi

    echo "[$(date)] [LAYOUT] Current → $CURRENT  |  Staging → $STAGING"

    # Seed staging from current data via hardlinks.
    echo "[$(date)] [SEED] Hardlinking missing files from current to staging..."
    cp -aln "$CURRENT"/* "$STAGING"/ 2>/dev/null || true

    # Remove .partial/.prev files left by a previously killed rclone or
    # synced from the source's own staging directory.
    echo "[$(date)] [CLEAN] Removing leftover .partial and .prev files..."
    find "$STAGING" \( -name "*.partial" -o -name ".prev" \) -exec rm -rf {} + 2>/dev/null || true

    # Force re-download of ALL APT metadata files in the hash chain.
    #
    #   InRelease → Release → Packages / Packages.* →
    #   Contents-* / Contents-*.gz → Sources / Sources.* → .deb
    #
    # Hardlink-seeded copies can match the new file's size exactly
    # (only internal checksums differ), which fools rclone's default
    # mtime+size comparison.  Every file in this chain is vulnerable —
    # a stale Packages or Contents file that happens to have the same
    # byte count as the new one will pass rclone's check but fail apt's
    # hash-chain verification (InRelease attests to a different SHA256).
    #
    # These files are tiny (KB range) — purging is cheap; stale
    # metadata is catastrophic (apt update rejects the whole repo).
    #
    # Only .deb (pool/) and .iso (ISO/) are cached via hardlink seed;
    # they are content-addressed and truly immutable.
    echo "[$(date)] [CLEAN] Purging ALL cached APT metadata files..."
    find "$STAGING" -type f \
        \( -name "InRelease" -o -name "Release" \
        -o -name "Packages" -o -name "Packages.gz" -o -name "Packages.xz" -o -name "Packages.bz2" \
        -o -name "Contents-*" -o -name "Contents-*.gz" -o -name "Contents-*.xz" -o -name "Contents-*.bz2" \
        -o -name "Sources" -o -name "Sources.gz" -o -name "Sources.xz" -o -name "Sources.bz2" \) \
        -delete 2>/dev/null || true

    # ── Two-pass rclone sync with retry ───────────────────────────
    #
    # The source may be updating its repository while we sync
    # (Packages.gz written, InRelease not yet re-signed).  This
    # causes "corrupted on transfer: sizes differ" errors — the
    # file size changed between rclone's LIST and DOWNLOAD phases.
    #
    # Strategy: up to 3 attempts per pass, 30s backoff between
    # retries, 10s gap between passes.  This gives the source time
    # to finish any in-progress atomic update cycle.
    SYNC_OK=true
    MAX_ATTEMPTS=3
    RETRY_GAP=30

    for PASS in 1 2; do
        ATTEMPT=0
        while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
            ATTEMPT=$((ATTEMPT + 1))
            echo "[$(date)] [RCLONE] Pass $PASS, attempt $ATTEMPT/$MAX_ATTEMPTS..."

            if rclone sync :webdav: "$STAGING/" \
                --webdav-url "$SOURCE_URL" \
                -v \
                --delete-after \
                --inplace=false \
                --retries 3 \
                --low-level-retries 3 \
                --exclude ".prev/**" \
                --exclude ".partial/**"; then
                echo "[$(date)] [RCLONE] Pass $PASS done (attempt $ATTEMPT)."
                break
            else
                if [ $ATTEMPT -lt $MAX_ATTEMPTS ]; then
                    echo "[$(date)] [RCLONE] Pass $PASS failed, retrying in ${RETRY_GAP}s..."
                    sleep $RETRY_GAP
                else
                    echo "[$(date)] [FAIL] rclone pass $PASS failed after $MAX_ATTEMPTS attempts."
                    SYNC_OK=false
                fi
            fi
        done

        if [ "$SYNC_OK" = "false" ]; then
            break
        fi

        # Pause between passes to let source finish atomic updates.
        if [ $PASS -eq 1 ]; then
            echo "[$(date)] [RCLONE] Pausing 10s between Pass 1 and Pass 2..."
            sleep 10
        fi
    done

    if [ "$SYNC_OK" = "true" ]; then
        echo "[$(date)] [BOM] Stripping UTF-8 BOM from InRelease / Release..."
        find "$STAGING" -type f \( -name "InRelease" -o -name "Release" \) | while read -r f; do
            sed -i "1s/^$(printf '\357\273\277')//" "$f"
        done

        # ── Hash-chain integrity verification ──────────────────────
        # Before swapping, verify that every file listed in each
        # InRelease SHA256 section actually matches its attested hash.
        # This is the ULTIMATE safety net — if anything (mtime+size
        # deception, partial transfer, source inconsistency, rclone
        # bug) produced stale or corrupted metadata, we catch it here
        # and REFUSE to swap.  The currently-serving data stays live.
        echo "[$(date)] [VERIFY] Checking APT hash chain integrity..."
        VERIFY_FAILED=0
        for inrelease in "$STAGING"/artifacts/anduinos/dists/*/InRelease; do
            [ -f "$inrelease" ] || continue
            dist_dir=$(dirname "$inrelease")
            awk '/^SHA256:/{found=1; next} /^-----BEGIN/{found=0} found && NF>=3{print $1,$3}' "$inrelease" | while read -r expected file; do
                target="$dist_dir/$file"
                if [ -f "$target" ]; then
                    actual=$(sha256sum "$target" | awk '{print $1}')
                    if [ "$expected" != "$actual" ]; then
                        echo "[$(date)] [VERIFY] MISMATCH: $file (exp=${expected}, got=${actual})"
                        echo "FAIL" >/tmp/verify_result
                    fi
                fi
            done
            if [ -f /tmp/verify_result ]; then
                VERIFY_FAILED=1
                rm -f /tmp/verify_result
                break
            fi
        done

        if [ $VERIFY_FAILED -eq 1 ]; then
            echo "[$(date)] [FAIL] Hash chain verification failed — refusing to swap."
        else
            echo "[$(date)] [VERIFY] Hash chain OK."
            date -u +"%Y-%m-%dT%H:%M:%SZ" > "$STAGING/sync_status.json"
            echo "[$(date)] [SWAP] ln -sfn $STAGING → /data/current..."
            ln -sfn "$STAGING" /data/current
            echo "[$(date)] [SWAP] Done. Sync cycle complete."
        fi
    else
        echo "[$(date)] [FAIL] Sync cycle failed. Production data NOT touched."
    fi

    # Release lock
    exec 200>&-

    echo "[$(date)] [SLEEP] 1 hour..."
    sleep 3600
done
EOF
sudo chmod +x sync-logic.sh

#==========================
# Launch Services
#==========================
print_ok "Pulling latest images and launching services..."
sudo docker compose pull
sudo docker compose up -d

# Force-restart containers so they pick up volume-mount scripts
# (sync-logic.sh, Caddyfile) even when docker-compose.yml itself
# hasn't changed.  docker compose up -d only recreates containers
# on compose-file changes, not on mounted-file changes.
sudo docker restart anduinos_sync anduinos_caddy 2>/dev/null || true
judge "Docker Compose services started"

#==========================
# Post-Installation Summary
#==========================
SERVER_IP=$(curl -s -4 ip.sb)
echo -e "\n${GreenBG}====================================================${Font}"
echo -e "${GreenBG}       AnduinOS Edge Node Deployed Successfully!    ${Font}"
echo -e "${GreenBG}====================================================${Font}\n"

echo -e "${Blue}The server is now acting as a mirror node.${Font}"
echo -e "Rclone is syncing from apkg-dav in the background."
echo -e "To view sync logs, run: ${Yellow}docker logs -f anduinos_sync${Font}\n"

echo -e "${RedBG} !!! ACTION REQUIRED ON CLOUDFLARE !!! ${Font}"
echo -e "Because this node uses pure HTTP (no certificates):"
echo -e "1. Go to your Cloudflare Dashboard for ${Yellow}anduinos.com${Font}."
echo -e "2. Add a DNS A Record: ${Yellow}packages.anduinos.com${Font} -> ${Yellow}$SERVER_IP${Font} (Orange Cloud ON)."
echo -e "3. Go to ${Yellow}SSL/TLS -> Overview${Font}."
echo -e "4. Set encryption mode to ${Yellow}Flexible${Font}."

echo -e "\n${Green}Enjoy your tea, Architecture Master!${Font}\n"
