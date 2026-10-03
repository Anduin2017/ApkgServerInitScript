#!/bin/bash

#=============================================================================
# AnduinOS Edge Mirror — One-Shot Idempotent Deployer
#
# This script is safe to run repeatedly on the same server.  Every run will:
#   • install any missing system packages
#   • restore changed/missing config files from the canonical version
#   • pull the latest Docker images
#   • bring containers up if down; recreate them when config files changed
#   • leave the existing /opt/anduinos-edge/data untouched
#
# An unknown service on port 80 is left untouched; deployment stops instead.
# Existing mirror data is never cleared by the deployer.
#=============================================================================

# Stop on failed installation/configuration commands instead of reporting success.
set -e
set -o pipefail

# Run on an existing edge to wake its own sync loop without redeploying.
# The shared lock prevents interrupting an active sync; only PID 1's idle
# one-hour sleep is eligible. No second synchronization process is started.
if [ "${1:-}" = "--sync-now" ]; then
    sudo docker exec -i anduinos_sync flock -n /data/.sync.lock sh -s <<'SYNC'
for pid in $(ps | awk '$4 == "sleep" && $5 == "3600" {print $1}'); do
    parent=$(awk '/^PPid:/{print $2}' "/proc/$pid/status")
    if [ "$parent" = 1 ]; then
        kill -TERM "$pid"
        echo "Routine sync awakened. Inspect: sudo docker logs -f anduinos_sync"
        exit 0
    fi
done
echo "No idle routine sleep found; no process changed."
exit 2
SYNC
    exit $?
fi
if [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--sync-now]" >&2
    exit 2
fi

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
  print_error "Leaving the existing service untouched. Resolve the port conflict before deploying."
  return 1
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
sudo mkdir -p "$WORKDIR/data"
cd "$WORKDIR"

CONFIG_CHANGED=false
BACKUP_DIR=""
write_config() {
    local name="$1" tmp
    tmp=$(sudo mktemp "$WORKDIR/.${name}.XXXXXX")
    if ! sudo tee "$tmp" >/dev/null; then
        sudo rm -f "$tmp"
        return 1
    fi
    sudo chmod 644 "$tmp"
    if sudo cmp -s "$tmp" "$name"; then
        sudo rm -f "$tmp"
        return 0
    fi
    if [ -e "$name" ]; then
        if [ -z "$BACKUP_DIR" ]; then
            BACKUP_DIR=$(sudo mktemp -d "$WORKDIR/deploy-backup.XXXXXX")
        fi
        sudo cp -a "$name" "$BACKUP_DIR/$name"
    fi
    sudo mv -Tf "$tmp" "$name"
    CONFIG_CHANGED=true
}

# 1. Generate docker-compose.yml
print_ok "Generating Docker Compose config..."
write_config docker-compose.yml << 'EOF'
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
    command: ["-c", "exec /sync-logic.sh"]
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "5"
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
write_config Caddyfile << 'EOF'
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
#   5. Verify staging, then rename a prepared symlink over /data/current
#
# Because staging always contains the previous cycle's data, rclone
# compares source vs. an almost-identical destination and transfers only
# what actually changed.  The first run (empty staging) does a full download;
# every subsequent run is incremental.
#
# Idempotent / self-healing properties:
#   - mkdir -p primary/secondary    → safe to run repeatedly
#   - publish_staging              → verifies before replacing current
#   - repair_layout                → preserves legacy/noncanonical contents
#   - shared flock                 → serializes sync processes
#
print_ok "Generating Atomic Sync logic..."
write_config sync-logic.sh << 'EOF'
#!/bin/sh

SOURCE_URL="${SOURCE_URL:-https://apkg-dav.aiursoft.com/}"
DATA_ROOT="${DATA_ROOT:-/data}"
RETRY_DELAY=60

# Only repository metadata is mutable under a stable name.  Never purge the
# active tree or the versioned .deb pool: the staging tree can be rebuilt on
# every attempt without interrupting users.
purge_apt_metadata() {
    metadata_dir="$1/artifacts/anduinos/dists"
    [ -n "$1" ] && [ ! -L "$1" ] &&
        [ ! -L "$1/artifacts" ] && [ ! -L "$1/artifacts/anduinos" ] || return 1
    # Recreate only the offline staging metadata tree.  BusyBox find does not
    # implement -delete, and removing the whole tree also clears stale links.
    rm -rf "$metadata_dir" || return 1
    mkdir -p "$metadata_dir"
}

verify_apt_metadata() {
    metadata_dir="$1/artifacts/anduinos/dists"
    manifest=$(mktemp /tmp/anduinos-verify.XXXXXX) || return 1
    verify_failed=false
    suites_found=0

    for dist_dir in "$metadata_dir"/*; do
        [ -d "$dist_dir" ] || continue
        suites_found=$((suites_found + 1))
        inrelease="$dist_dir/InRelease"
        if [ ! -f "$inrelease" ]; then
            echo "[$(date)] [VERIFY] MISSING: $inrelease"
            verify_failed=true
            continue
        fi
        if ! awk '/^SHA256:/{found=1; next} found && /^[^[:space:]]/{exit} found && NF>=3{print $1,$2,$3}' \
            "$inrelease" > "$manifest" || [ ! -s "$manifest" ]; then
            echo "[$(date)] [VERIFY] Missing or unreadable SHA256 manifest: $inrelease"
            verify_failed=true
            continue
        fi

        while read -r expected expected_size file; do
            case "$file" in
                ''|/*|.|..|../*|*/..|*/../*)
                    echo "[$(date)] [VERIFY] Invalid manifest path: $file"
                    verify_failed=true
                    continue
                    ;;
            esac
            target="$dist_dir/$file"
            if [ ! -f "$target" ] || [ -L "$target" ]; then
                echo "[$(date)] [VERIFY] MISSING: $file in $(basename "$dist_dir")"
                verify_failed=true
                continue
            fi
            actual_size=$(wc -c < "$target" | tr -d '[:space:]')
            actual=$(sha256sum "$target" | awk '{print $1}')
            if [ "$expected_size" != "$actual_size" ] || [ "$expected" != "$actual" ]; then
                echo "[$(date)] [VERIFY] MISMATCH: $file in $(basename "$dist_dir") (exp=${expected}/${expected_size}, got=${actual}/${actual_size})"
                verify_failed=true
            fi
        done < "$manifest"
    done

    rm -f "$manifest"
    if [ "$suites_found" -eq 0 ]; then
        echo "[$(date)] [VERIFY] No APT distributions found in $metadata_dir"
        return 1
    fi
    [ "$verify_failed" = false ]
}

failure_backoff() {
    echo "[$(date)] [RETRY] Retrying in ${RETRY_DELAY}s without touching the active tree."
    sleep "$RETRY_DELAY"
    if [ "$RETRY_DELAY" -lt 3600 ]; then
        RETRY_DELAY=$((RETRY_DELAY * 2))
        [ "$RETRY_DELAY" -le 3600 ] || RETRY_DELAY=3600
    fi
}

# Recover owned layout entries without deleting unknown or legacy contents.
# A malformed entry is moved aside, so another run can repair it safely.
repair_layout() {
    layout_root="$1"
    mkdir -p "$layout_root" || return 1
    CURRENT=$(readlink "$layout_root/current" 2>/dev/null || true)
    case "$CURRENT" in
        primary|secondary) CURRENT="$layout_root/$CURRENT" ;;
    esac
    case "$CURRENT" in
        "$layout_root/primary"|"$layout_root/secondary")
            if [ -L "$CURRENT" ]; then
                echo "[$(date)] [FAIL] Active side is itself a symlink; leaving the serving tree untouched."
                return 1
            fi
            ;;
        *)
            if [ -d "$layout_root/current" ]; then
                echo "[$(date)] [FAIL] Noncanonical current directory is serving data; refusing to move it before publication."
                return 1
            fi
            CURRENT=""
            ;;
    esac
    for side in primary secondary; do
        entry="$layout_root/$side"
        if [ -L "$entry" ] || { [ -e "$entry" ] && [ ! -d "$entry" ]; }; then
            recovery_dir=$(mktemp -d "$layout_root/recovered.XXXXXX") || return 1
            mv "$entry" "$recovery_dir/$side" || return 1
            echo "[$(date)] [HEAL] Preserved invalid $side at $recovery_dir/$side."
        fi
        mkdir -p "$entry" || return 1
    done

    [ -z "$CURRENT" ] || return 0
    # On a fresh or interrupted deployment, select a seed without publishing
    # anything. Only publish_staging is allowed to create/replace current.
    if [ -d "$layout_root/www" ] && [ ! -L "$layout_root/www" ]; then
        cp -al "$layout_root/www/." "$layout_root/secondary/" 2>/dev/null || true
    fi
    if [ -f "$layout_root/secondary/sync_status.json" ]; then
        CURRENT="$layout_root/secondary"
    else
        CURRENT="$layout_root/primary"
    fi
}

publish_staging() {
    publish_root="$1"
    publish_tree="$2"
    verify_apt_metadata "$publish_tree" || return 1
    # Replace the status inode too; it may be hardlinked to the active tree.
    status_tmp=$(mktemp "$publish_tree/.sync-status.XXXXXX") || return 1
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$status_tmp" || return 1
    mv -f "$status_tmp" "$publish_tree/sync_status.json" || return 1
    link_dir=$(mktemp -d "$publish_root/.link.XXXXXX") || return 1
    if ln -s "$publish_tree" "$link_dir/current" && mv -Tf "$link_dir/current" "$publish_root/current"; then
        rmdir "$link_dir" || true
        echo "[$(date)] [SWAP] Atomically switched current to $publish_tree."
        return 0
    fi
    rm -f "$link_dir/current"
    rmdir "$link_dir" || true
    return 1
}

echo "[$(date)] [INIT] Rclone worker started."

while true; do
    echo "[$(date)] [CYCLE] Starting sync cycle..."
    CYCLE_OK=false

    # ── Mutual exclusion ─────────────────────────────────────────
    # Prevent two sync processes from writing to the same staging
    # directory simultaneously (e.g. docker exec + main loop).
    # The lock fd is released automatically by the kernel on exit.
    #
    # BusyBox flock does not support -w; we implement our own
    # wait loop with -n (non-blocking).
    mkdir -p "$DATA_ROOT" || { failure_backoff; continue; }
    exec 200>"$DATA_ROOT/.sync.lock"
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

    if ! repair_layout "$DATA_ROOT"; then
        echo "[$(date)] [FAIL] Layout repair failed; retrying."
        exec 200>&-
        failure_backoff
        continue
    fi
    if [ "$CURRENT" = "$DATA_ROOT/primary" ]; then
        STAGING="$DATA_ROOT/secondary"
    else
        STAGING="$DATA_ROOT/primary"
    fi

    echo "[$(date)] [LAYOUT] Current → $CURRENT  |  Staging → $STAGING"

    # Seed staging from current data via hardlinks.
    echo "[$(date)] [SEED] Hardlinking files from current to staging..."
    cp -al "$CURRENT"/* "$STAGING"/ 2>/dev/null || true

    # Remove .partial/.prev files left by a previously killed rclone or
    # synced from the source's own staging directory.
    echo "[$(date)] [CLEAN] Removing leftover .partial and .prev files..."
    find "$STAGING" \( -name "*.partial" -o -name ".prev" \) -exec rm -rf {} + 2>/dev/null || true

    # ── Metadata purge (safety net for hash-chain integrity) ──────
    # InRelease signs every file below dists/, including DEP-11 icon
    # archives.  A changed file can keep the same size, so --size-only
    # must never compare hardlink-seeded metadata.  Purge the entire
    # staging dists/ tree each cycle and re-download it from the source.
    # The active tree and versioned .deb pool remain untouched.
    #
    # ── Why --size-only is safe for .deb files ────────────────────
    #
    # .deb files are NOT purged.  They are hardlink-seeded and
    # compared via rclone --size-only.  This is safe because Debian
    # packages embed the version in the filename:
    #
    #   {pkg}_{epoch:version}_{arch}.deb
    #
    # When a package is updated, the version changes → the filename
    # changes → rclone sees a *new* file and downloads it regardless
    # of --size-only.  The old version disappears from the source and
    # is cleaned up by --delete-after.
    #
    # Same filename = same version = same content.  There is no
    # scenario where a .deb file keeps its name but changes content
    # in a correctly-managed APT repository.
    #
    # Combined, the two strategies give us:
    #   • metadata: always fresh (downloaded every cycle)
    #   • .deb:     incremental (only new versions trigger transfer)
    echo "[$(date)] [CLEAN] Purging cached staging APT metadata..."
    SYNC_OK=true
    if ! purge_apt_metadata "$STAGING"; then
        echo "[$(date)] [FAIL] Could not purge staging metadata; refusing to sync or swap."
        SYNC_OK=false
    fi

    # ── Two-pass rclone sync with retry ───────────────────────────
    #
    # The source may be updating its repository while we sync
    # (Packages.gz written, InRelease not yet re-signed).
    #
    # Strategy: up to 3 attempts per pass, 30s backoff between
    # retries, 10s gap between passes.  This gives the source time
    # to finish any in-progress atomic update cycle.
    MAX_ATTEMPTS=3
    RETRY_GAP=30

    for PASS in 1 2; do
        [ "$SYNC_OK" = true ] || break
        ATTEMPT=0
        while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
            ATTEMPT=$((ATTEMPT + 1))
            echo "[$(date)] [RCLONE] Pass $PASS, attempt $ATTEMPT/$MAX_ATTEMPTS..."

            if rclone sync :http: "$STAGING/" \
                --http-url "$SOURCE_URL" \
                -v \
                --size-only \
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

        # Verify every signed metadata file, including DEP-11 and missing
        # files, before publishing this staging tree.
        echo "[$(date)] [VERIFY] Checking APT hash chain integrity..."
        if publish_staging "$DATA_ROOT" "$STAGING"; then
            CYCLE_OK=true
        else
            echo "[$(date)] [FAIL] Verification or publication failed; old data remains live."
        fi
    else
        echo "[$(date)] [FAIL] Sync cycle failed. Production data NOT touched."
    fi

    # Release lock
    exec 200>&-

    if [ "${CYCLE_OK:-false}" = true ]; then
        RETRY_DELAY=60
        echo "[$(date)] [SLEEP] 1 hour until the next routine sync."
        sleep 3600
    else
        failure_backoff
    fi
done
EOF
sudo chmod +x sync-logic.sh

#==========================
# Launch Services
#==========================
print_ok "Pulling latest images and launching services..."
sudo docker compose pull
# Replacing a bind-mounted file changes its inode. Recreate containers when
# configuration changed so they mount the new files; restart alone is insufficient.
if [ "$CONFIG_CHANGED" = true ]; then
    sudo docker compose up -d --force-recreate --wait --wait-timeout 7500
else
    sudo docker compose up -d --wait --wait-timeout 7500
fi
curl --fail --silent --show-error --retry 5 --retry-connrefused \
    http://127.0.0.1/sync_status.json
judge "Docker Compose services and mirror endpoint ready"

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
