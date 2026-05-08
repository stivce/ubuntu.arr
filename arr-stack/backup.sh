#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# arr-stack Backup Script
# =============================================================================
# Creates a full backup of all service configurations.
#
# Usage: ./backup.sh [--output /path/to/backup/dir]
#
# What gets backed up:
#   - Sonarr, Radarr, Lidarr, Prowlarr: built-in backup API (DB + config)
#   - Bazarr, Jellyfin, Jellyseerr, Homarr, Deluge: config directory tars
#   - Infrastructure (Caddy PKI, Authelia, WireGuard): config directory tars
#
# Restore with: ./restore.sh <backup-file.tar.gz>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# .env lives in the repo root (parent of arr-stack/)
ENV_FILE="${SCRIPT_DIR}/../.env"

# Defaults (read from .env if present, else use defaults)
ARR_CONFIG_DIR="${ARR_CONFIG_DIR:-/data/docker/arr-stack/config}"
INFRASTRUCTURE_CONFIG_DIR="${INFRASTRUCTURE_CONFIG_DIR:-/data/docker/infrastructure/config}"
BACKUP_BASE="${BACKUP_BASE:-/data/backups/arr-stack}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_STAGING="${BACKUP_BASE}/staging-${TIMESTAMP}"
FINAL_ARCHIVE="${BACKUP_BASE}/arr-stack-backup-${TIMESTAMP}.tar.gz"

LOCK_FILE="/tmp/arr-stack-backup.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo -e "${RED}Error: Another backup is already running${NC}"
    exit 1
fi

# Load .env if present
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${ENV_FILE}"; set +a
fi

# =============================================================================
# Helpers
# =============================================================================

read_api_key() {
    local service=$1
    local config_file="${ARR_CONFIG_DIR}/${service}/config.xml"
    if [[ ! -f "$config_file" ]]; then
        echo ""
        return
    fi
    grep -oP '(?<=<ApiKey>)[^<]+' "$config_file" || echo ""
}

trigger_arr_backup() {
    local name=$1
    local port=$2
    local key=$3
    local api_ver=$4  # v1 or v3

    echo -e "${BLUE}  Triggering ${name} backup...${NC}"
    local response
    response=$(curl -s -X POST "http://localhost:${port}/api/${api_ver}/command" \
        -H "X-Api-Key: ${key}" \
        -H "Content-Type: application/json" \
        -d '{"name":"Backup"}')

    local cmd_id
    cmd_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")

    if [[ -z "$cmd_id" ]]; then
        echo -e "${RED}  ✗ Failed to trigger ${name} backup${NC}"
        return 1
    fi

    # Poll until complete (max 60s)
    local elapsed=0
    while [[ $elapsed -lt 60 ]]; do
        local status
        status=$(curl -s "http://localhost:${port}/api/${api_ver}/command/${cmd_id}" \
            -H "X-Api-Key: ${key}" | python3 -c "import sys,json; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "unknown")
        if [[ "$status" == "completed" ]]; then
            echo -e "${GREEN}  ✓ ${name} backup complete${NC}"
            return 0
        elif [[ "$status" == "failed" ]]; then
            echo -e "${RED}  ✗ ${name} backup failed${NC}"
            return 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    echo -e "${YELLOW}  ⚠ ${name} backup timed out${NC}"
    return 1
}

copy_arr_backup() {
    local name=$1
    local dest="${BACKUP_STAGING}/${name}"
    mkdir -p "$dest"

    # Find the most recent backup zip in the service's config dir
    local backup_zip
    backup_zip=$(find "${ARR_CONFIG_DIR}/${name}/Backups" -name "*.zip" 2>/dev/null \
        | sort -t_ -k1 | tail -1)

    if [[ -z "$backup_zip" ]]; then
        echo -e "${RED}  ✗ No backup zip found for ${name}${NC}"
        return 1
    fi

    cp "$backup_zip" "${dest}/${name}-backup.zip"
    echo -e "${GREEN}  ✓ Copied ${name} backup: $(basename "$backup_zip")${NC}"
}

tar_config() {
    local name=$1
    local dest="${BACKUP_STAGING}/${name}"
    shift
    # Remaining args are glob patterns to exclude (relative to the config dir entry)
    local excludes=("$@")

    mkdir -p "$dest"

    local exclude_args=()
    for ex in "${excludes[@]:-}"; do
        exclude_args+=("--exclude=${ex}")
    done

    if tar -czf "${dest}/${name}-config.tar.gz" "${exclude_args[@]}" -C "${ARR_CONFIG_DIR}" "${name}" 2>/dev/null; then
        local size
        size=$(du -sh "${dest}/${name}-config.tar.gz" | cut -f1)
        echo -e "${GREEN}  ✓ ${name} config backed up (${size})${NC}"
    else
        echo -e "${RED}  ✗ Failed to back up ${name} config${NC}"
        return 1
    fi
}

tar_infra_config() {
    local name=$1
    local dest="${BACKUP_STAGING}/infra-${name}"
    shift
    local excludes=("$@")

    mkdir -p "$dest"

    local exclude_args=()
    for ex in "${excludes[@]:-}"; do
        exclude_args+=("--exclude=${ex}")
    done

    if sudo tar -czf "${dest}/${name}-config.tar.gz" "${exclude_args[@]}" \
            -C "${INFRASTRUCTURE_CONFIG_DIR}" "${name}" 2>/dev/null; then
        local size
        size=$(du -sh "${dest}/${name}-config.tar.gz" | cut -f1)
        echo -e "${GREEN}  ✓ infra/${name} backed up (${size})${NC}"
    else
        echo -e "${RED}  ✗ Failed to back up infra/${name}${NC}"
        return 1
    fi
}

# =============================================================================
# Main
# =============================================================================

clear

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}arr-stack Backup${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo "Backup destination: ${FINAL_ARCHIVE}"
echo ""

mkdir -p "${BACKUP_STAGING}"

SERVICES_BACKED_UP=0
SERVICES_FAILED=0

# =============================================================================
# Step 1: *arr apps (built-in backup API)
# =============================================================================

echo -e "${BLUE}--- *arr Apps (built-in backup) ---${NC}"

declare -A ARR_PORTS=(
    ["sonarr"]="8989"
    ["radarr"]="7878"
    ["lidarr"]="8686"
    ["prowlarr"]="9696"
)

declare -A ARR_API=(
    ["sonarr"]="v3"
    ["radarr"]="v3"
    ["lidarr"]="v1"
    ["prowlarr"]="v1"
)

for service in sonarr radarr lidarr prowlarr; do
    port="${ARR_PORTS[$service]}"
    api_ver="${ARR_API[$service]}"
    key=$(read_api_key "$service")

    if [[ -z "$key" ]]; then
        echo -e "${YELLOW}  ⚠ ${service}: config not found, skipping${NC}"
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
        continue
    fi

    if ! docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
        echo -e "${YELLOW}  ⚠ ${service}: container not running, skipping${NC}"
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
        continue
    fi

    if trigger_arr_backup "$service" "$port" "$key" "$api_ver" && copy_arr_backup "$service"; then
        SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
    else
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
    fi
done

echo ""

# =============================================================================
# Step 2: Other services (config directory tars)
# =============================================================================

echo -e "${BLUE}--- Other Services (config tars) ---${NC}"

# Bazarr - exclude cache/log/backup dirs (has its own backup dir)
if tar_config "bazarr" \
    "bazarr/cache" \
    "bazarr/log" \
    "bazarr/backup" \
    "bazarr/restore"; then
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
else
    SERVICES_FAILED=$((SERVICES_FAILED + 1))
fi

# Jellyfin - exclude cache, log, metadata (large, auto-regenerated)
if tar_config "jellyfin" \
    "jellyfin/cache" \
    "jellyfin/log" \
    "jellyfin/data/metadata"; then
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
else
    SERVICES_FAILED=$((SERVICES_FAILED + 1))
fi

# Jellyseerr - full config (small, contains DB + settings)
if tar_config "jellyseerr"; then
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
else
    SERVICES_FAILED=$((SERVICES_FAILED + 1))
fi

# Homarr - full config (contains DB + layout)
if tar_config "homarr"; then
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
else
    SERVICES_FAILED=$((SERVICES_FAILED + 1))
fi

# Deluge - full config including torrent state and .torrent files
# Excludes: logs only (deluged.log is ephemeral)
if tar_config "deluge" "deluge/deluged.log"; then
    SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
else
    SERVICES_FAILED=$((SERVICES_FAILED + 1))
fi

echo ""

# =============================================================================
# Step 3: Infrastructure services (config directory tars)
# =============================================================================

echo -e "${BLUE}--- Infrastructure Services (Caddy, Authelia, WireGuard) ---${NC}"

# Caddy data (PKI keys/certs — root-owned, requires sudo)
if [[ -d "${INFRASTRUCTURE_CONFIG_DIR}/caddy" ]]; then
    if tar_infra_config "caddy"; then
        SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
    else
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
    fi
else
    echo -e "${YELLOW}  ⚠ infra/caddy: config not found, skipping${NC}"
fi

# Authelia config (users DB, sqlite3 session state)
if [[ -d "${INFRASTRUCTURE_CONFIG_DIR}/authelia" ]]; then
    if tar_infra_config "authelia"; then
        SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
    else
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
    fi
else
    echo -e "${YELLOW}  ⚠ infra/authelia: config not found, skipping${NC}"
fi

# WireGuard (wg-easy) — peer keys and config
if [[ -d "${INFRASTRUCTURE_CONFIG_DIR}/wg-easy" ]]; then
    if tar_infra_config "wg-easy"; then
        SERVICES_BACKED_UP=$((SERVICES_BACKED_UP + 1))
    else
        SERVICES_FAILED=$((SERVICES_FAILED + 1))
    fi
else
    echo -e "${YELLOW}  ⚠ infra/wg-easy: config not found, skipping${NC}"
fi

echo ""

# =============================================================================
# Step 4: Bundle into final archive
# =============================================================================

echo -e "${BLUE}--- Creating Archive ---${NC}"

if [[ $SERVICES_BACKED_UP -eq 0 ]]; then
    echo -e "${RED}✗ No services backed up successfully. Aborting.${NC}"
    rm -rf "${BACKUP_STAGING}"
    exit 1
fi

ARCHIVE_OK=false
if tar -czf "${FINAL_ARCHIVE}" -C "${BACKUP_BASE}" "staging-${TIMESTAMP}"; then
    ARCHIVE_OK=true
fi
rm -rf "${BACKUP_STAGING}"

if [[ "$ARCHIVE_OK" != "true" ]]; then
    echo -e "${RED}✗ Failed to create archive. Old backups NOT pruned.${NC}"
    exit 1
fi

FINAL_SIZE=$(du -sh "${FINAL_ARCHIVE}" | cut -f1)
echo -e "${GREEN}✓ Backup complete: ${FINAL_ARCHIVE} (${FINAL_SIZE})${NC}"
[[ $SERVICES_FAILED -gt 0 ]] && echo -e "${YELLOW}  ⚠ ${SERVICES_FAILED} service(s) skipped${NC}"
echo ""

# Prune only after confirmed successful archive
BACKUP_COUNT=$(find "${BACKUP_BASE}" -maxdepth 1 -name "arr-stack-backup-*.tar.gz" | wc -l)
if [[ $BACKUP_COUNT -gt 5 ]]; then
    echo -e "${YELLOW}Pruning old backups (keeping last 5)...${NC}"
    find "${BACKUP_BASE}" -maxdepth 1 -name "arr-stack-backup-*.tar.gz" \
        | sort | head -n $((BACKUP_COUNT - 5)) | xargs rm -f
    echo -e "${GREEN}✓ Old backups pruned${NC}"
fi

echo ""
echo "Restore with:"
echo "  ./restore.sh ${FINAL_ARCHIVE}"
echo ""
