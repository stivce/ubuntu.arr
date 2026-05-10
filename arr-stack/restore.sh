#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# arr-stack Restore Script
# =============================================================================
# Restores all service configurations from a backup archive.
#
# Usage: ./restore.sh <backup-file.tar.gz>
#
# WARNING: This will OVERWRITE existing service configurations.
#          Services will be stopped during restore and restarted after.
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

# Defaults
ARR_CONFIG_DIR="${ARR_CONFIG_DIR:-/data/docker/arr-stack/config}"
INFRASTRUCTURE_CONFIG_DIR="${INFRASTRUCTURE_CONFIG_DIR:-/data/docker/infrastructure/config}"

# Load .env if present
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1091
    set -a; source "${ENV_FILE}"; set +a
fi

# =============================================================================
# Validate input
# =============================================================================

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <backup-file.tar.gz>"
    exit 1
fi

BACKUP_FILE="$1"

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo -e "${RED}Error: Backup file not found: ${BACKUP_FILE}${NC}"
    exit 1
fi

# =============================================================================
# Main
# =============================================================================

clear

echo -e "${RED}========================================${NC}"
echo -e "${RED}arr-stack Restore${NC}"
echo -e "${RED}========================================${NC}"
echo ""
echo -e "${YELLOW}Backup file: ${BACKUP_FILE}${NC}"
echo ""
echo -e "${RED}WARNING: This will overwrite existing service configurations!${NC}"
echo -e "${RED}All services will be stopped during restore.${NC}"
echo ""
read -p "Type 'yes' to confirm restore: " -r
echo
if [[ ! $REPLY == "yes" ]]; then
    echo "Restore cancelled."
    exit 0
fi
echo ""

# =============================================================================
# Step 1: Validate and extract backup archive
# =============================================================================

echo -e "${BLUE}--- Validating Archive ---${NC}"
if ! tar -tzf "$BACKUP_FILE" > /dev/null 2>&1; then
    echo -e "${RED}Error: Archive is corrupt or unreadable${NC}"
    exit 1
fi

EXTRACT_DIR=$(mktemp -d)
tar -xzf "$BACKUP_FILE" -C "$EXTRACT_DIR"
STAGING_DIR=$(find "$EXTRACT_DIR" -maxdepth 2 -type d -name "staging-*" | head -1)
if [[ -z "$STAGING_DIR" ]]; then
    rm -rf "$EXTRACT_DIR"
    echo -e "${RED}Error: Invalid backup archive format${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Archive validated and extracted${NC}"
echo ""

# =============================================================================
# Step 2: Create Pre-Restore Snapshot
# =============================================================================

echo -e "${BLUE}--- Creating Pre-Restore Snapshot ---${NC}"
SNAPSHOT_DIR="$(dirname "${ARR_CONFIG_DIR}")/restore-snapshots"
mkdir -p "${SNAPSHOT_DIR}"
SNAPSHOT_FILE="${SNAPSHOT_DIR}/pre-restore-$(date +%Y%m%d-%H%M%S).tar.gz"
if tar -czf "${SNAPSHOT_FILE}" -C "$(dirname "${ARR_CONFIG_DIR}")" "$(basename "${ARR_CONFIG_DIR}")" 2>/dev/null; then
    echo -e "${GREEN}✓ Pre-restore snapshot: ${SNAPSHOT_FILE}${NC}"
else
    echo -e "${YELLOW}⚠ Could not snapshot (config may be empty)${NC}"
    SNAPSHOT_FILE=""
fi
echo ""

# =============================================================================
# Step 3: Stop all services
# =============================================================================

echo -e "${BLUE}--- Stopping Services ---${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" down 2>/dev/null || true
echo -e "${GREEN}✓ Services stopped${NC}"
echo ""

_restore_cleanup() {
    local exit_code=$?
    rm -rf "${EXTRACT_DIR}"
    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}Restore FAILED. Rolling back...${NC}"
        if [[ -n "${SNAPSHOT_FILE:-}" ]] && [[ -f "${SNAPSHOT_FILE}" ]]; then
            tar -xzf "${SNAPSHOT_FILE}" -C "$(dirname "${ARR_CONFIG_DIR}")" 2>/dev/null \
                && echo -e "${GREEN}✓ Rolled back to pre-restore state${NC}" \
                || echo -e "${RED}✗ Rollback failed. Snapshot at: ${SNAPSHOT_FILE}${NC}"
        fi
        docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" up -d 2>/dev/null || true
    fi
}
trap '_restore_cleanup' EXIT

# =============================================================================
# Step 4: Restore *arr apps (built-in backup zips)
# =============================================================================

echo -e "${BLUE}--- Restoring *arr Apps ---${NC}"

restore_arr() {
    local name=$1
    local zip="${STAGING_DIR}/${name}/${name}-backup.zip"

    if [[ ! -f "$zip" ]]; then
        echo -e "${YELLOW}  ⚠ ${name}: no backup found, skipping${NC}"
        return
    fi

    local dest="${ARR_CONFIG_DIR}/${name}"
    rm -rf "$dest"
    mkdir -p "$dest"

    # Extract backup zip - *arr backups contain the DB and config.xml at root
    unzip -o "$zip" -d "$dest" > /dev/null 2>&1
    echo -e "${GREEN}  ✓ ${name} restored${NC}"
}

for service in sonarr radarr lidarr prowlarr; do
    restore_arr "$service"
done

echo ""

# =============================================================================
# Step 5: Restore other services (config tars)
# =============================================================================

echo -e "${BLUE}--- Restoring Other Services ---${NC}"

restore_tar() {
    local name=$1
    local tarfile="${STAGING_DIR}/${name}/${name}-config.tar.gz"

    if [[ ! -f "$tarfile" ]]; then
        echo -e "${YELLOW}  ⚠ ${name}: no backup found, skipping${NC}"
        return
    fi

    rm -rf "${ARR_CONFIG_DIR:?}/${name}"
    mkdir -p "${ARR_CONFIG_DIR}/${name}"
    tar -xzf "$tarfile" -C "${ARR_CONFIG_DIR}"
    echo -e "${GREEN}  ✓ ${name} restored${NC}"
}

for service in bazarr jellyfin jellyseerr homarr deluge; do
    restore_tar "$service"
done

# Ensure Deluge web UI auto-connects to the local daemon after restore
DELUGE_WEB_CONF="${ARR_CONFIG_DIR}/deluge/web.conf"
if [[ -f "$DELUGE_WEB_CONF" ]]; then
    python3 - "$DELUGE_WEB_CONF" <<'PYEOF' \
        && echo -e "${GREEN}  ✓ Deluge web.conf: default_daemon set for auto-connect${NC}" \
        || echo -e "${YELLOW}  ⚠ Could not patch Deluge web.conf${NC}"
import json, sys
path = sys.argv[1]
with open(path) as f:
    raw = f.read()
# web.conf has two concatenated JSON objects; split on the boundary
parts = raw.split("}{")
if len(parts) == 2:
    header = parts[0] + "}"
    body   = "{" + parts[1]
else:
    header, body = "{}", raw
cfg = json.loads(body)
cfg["default_daemon"] = "127.0.0.1:58846"
with open(path, "w") as f:
    f.write(header + json.dumps(cfg, indent=2))
PYEOF
fi

# Sync hostlist.conf daemon password with the auth file so the web UI can
# authenticate to the daemon. These get out of sync when the container is
# recreated (linuxserver regenerates auth) but hostlist.conf keeps the old hash.
DELUGE_AUTH="${ARR_CONFIG_DIR}/deluge/auth"
DELUGE_HOSTLIST="${ARR_CONFIG_DIR}/deluge/hostlist.conf"
if [[ -f "$DELUGE_AUTH" ]] && [[ -f "$DELUGE_HOSTLIST" ]]; then
    AUTH_HASH=$(grep '^localclient:' "$DELUGE_AUTH" | cut -d: -f2)
    if [[ -n "$AUTH_HASH" ]]; then
        python3 - "$DELUGE_HOSTLIST" "$AUTH_HASH" <<'PYEOF' \
            && echo -e "${GREEN}  ✓ Deluge hostlist.conf: daemon password synced with auth file${NC}" \
            || echo -e "${YELLOW}  ⚠ Could not sync Deluge hostlist.conf${NC}"
import json, sys
path, new_hash = sys.argv[1], sys.argv[2]
with open(path) as f:
    raw = f.read()
# hostlist.conf has two concatenated JSON objects; split on the boundary
parts = raw.split("}{")
if len(parts) == 2:
    header = parts[0] + "}"
    body   = "{" + parts[1]
else:
    header, body = "{}", raw
cfg = json.loads(body)
for host in cfg.get("hosts", []):
    if len(host) >= 4 and host[3] == "localclient":
        host[4] = new_hash
with open(path, "w") as f:
    f.write(header + json.dumps(cfg, indent=4))
PYEOF
    fi
fi

echo ""

# =============================================================================
# Step 6: Restart services
# =============================================================================

echo -e "${BLUE}--- Starting Services ---${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" up -d 2>/dev/null
echo -e "${GREEN}✓ Services started${NC}"
echo ""

# =============================================================================
# Step 7: Restore Infrastructure Services (if present in backup)
# =============================================================================

# Disarm arr-stack rollback trap — arr-stack is running.
# Register a simple cleanup trap instead so EXTRACT_DIR is always removed.
trap 'rm -rf "${EXTRACT_DIR}"' EXIT

INFRA_COMPOSE="${SCRIPT_DIR}/../infrastructure/docker-compose.yml"

restore_infra_tar() {
    local name=$1
    local tarfile="${STAGING_DIR}/infra-${name}/${name}-config.tar.gz"
    if [[ ! -f "$tarfile" ]]; then
        echo -e "${YELLOW}  ⚠ infra/${name}: no backup found, skipping${NC}"
        return
    fi
    sudo rm -rf "${INFRASTRUCTURE_CONFIG_DIR:?}/${name}"
    sudo mkdir -p "${INFRASTRUCTURE_CONFIG_DIR}"
    sudo tar -xzf "$tarfile" -C "${INFRASTRUCTURE_CONFIG_DIR}"
    echo -e "${GREEN}  ✓ infra/${name} restored${NC}"
}

INFRA_FOUND=0
for _svc in caddy authelia wg-easy; do
    if [[ -f "${STAGING_DIR}/infra-${_svc}/${_svc}-config.tar.gz" ]]; then
        INFRA_FOUND=1
        break
    fi
done

if [[ $INFRA_FOUND -eq 1 ]]; then
    echo -e "${BLUE}--- Restoring Infrastructure Services ---${NC}"

    if [[ -f "$INFRA_COMPOSE" ]]; then
        docker compose --env-file "${ENV_FILE}" -f "$INFRA_COMPOSE" down 2>/dev/null || true
    fi

    for _svc in caddy authelia wg-easy; do
        restore_infra_tar "$_svc"
    done

    if [[ -f "$INFRA_COMPOSE" ]]; then
        docker compose --env-file "${ENV_FILE}" -f "$INFRA_COMPOSE" up -d 2>/dev/null || true
        echo -e "${GREEN}  ✓ Infrastructure services restarted${NC}"
    fi

    echo ""
fi

# =============================================================================
# Summary
# =============================================================================

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Restore Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "Services are starting up. Allow 30-60 seconds for all services to be ready."
echo ""
echo "Verify services:"
echo "  docker compose -f ${SCRIPT_DIR}/docker-compose.yml ps"
echo ""

# Prune old pre-restore snapshots (keep last 3)
SNAP_COUNT=$(find "${SNAPSHOT_DIR}" -maxdepth 1 -name "pre-restore-*.tar.gz" 2>/dev/null | wc -l)
if [[ $SNAP_COUNT -gt 3 ]]; then
    find "${SNAPSHOT_DIR}" -maxdepth 1 -name "pre-restore-*.tar.gz" \
        | sort | head -n $((SNAP_COUNT - 3)) | xargs rm -f
fi
