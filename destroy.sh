#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Home Server Stack - Destroy Script
# =============================================================================
# Stops and removes containers from both stacks. Optionally removes volumes
# and config directories.
#
# Usage: ./destroy.sh [OPTIONS]
#
# Options:
#   --volumes    Also remove Docker volumes (WARNING: deletes all data!)
#   --all        Remove Docker volumes AND config directories on disk
#   --yes, -y    Skip confirmation prompt
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

REMOVE_VOLUMES=false
REMOVE_ALL=false
SKIP_CONFIRM=false

for arg in "$@"; do
    case $arg in
        --volumes)
            REMOVE_VOLUMES=true
            ;;
        --all)
            REMOVE_VOLUMES=true
            REMOVE_ALL=true
            ;;
        --yes|-y)
            SKIP_CONFIRM=true
            ;;
        --help|-h)
            sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
    esac
done

# Resolve config directories from the single root .env, or fall back to defaults.
if [[ -f "${ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi
INFRASTRUCTURE_CONFIG_DIR="${INFRASTRUCTURE_CONFIG_DIR:-/data/docker/infrastructure/config}"
ARR_CONFIG_DIR="${ARR_CONFIG_DIR:-/data/docker/arr-stack/config}"

clear

echo -e "${RED}========================================${NC}"
echo -e "${RED}Home Server Stack - Destroy${NC}"
echo -e "${RED}========================================${NC}"
echo ""

echo -e "${YELLOW}This will stop and remove:${NC}"
echo "  • All infrastructure containers (Caddy, Portainer, DDNS, wg-easy, Authelia, Dashdot)"
echo "  • All media containers (Gluetun, Deluge, *arr apps, Jellyfin, Jellyseerr, Homarr)"
echo "  • Docker network: home_network"
if [[ "$REMOVE_ALL" == "true" ]]; then
    echo -e "  ${RED}• ALL DOCKER VOLUMES (IRREVERSIBLE!)${NC}"
    echo -e "  ${RED}• Config directory: ${ARR_CONFIG_DIR}${NC}"
    echo -e "  ${RED}• Config directory: ${INFRASTRUCTURE_CONFIG_DIR}${NC}"
elif [[ "$REMOVE_VOLUMES" == "true" ]]; then
    echo -e "  ${RED}• ALL DOCKER VOLUMES${NC}"
    echo "  • Config directories on disk preserved (use --all to remove)"
else
    echo "  • Volumes preserved (use --volumes to remove)"
    echo "  • Config directories preserved (use --all to remove)"
fi
echo ""

if [[ "$SKIP_CONFIRM" == "false" ]]; then
    read -p "Type 'yes' to confirm: " -r
    echo
    if [[ ! $REPLY == "yes" ]]; then
        echo "Destroy cancelled."
        exit 0
    fi
    echo ""
fi

COMPOSE_OPTS=""
if [[ "$REMOVE_VOLUMES" == "true" ]]; then
    COMPOSE_OPTS="-v"
fi

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Destroying media stack${NC}"
echo -e "${BLUE}========================================${NC}"
if docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
    docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" down $COMPOSE_OPTS
    echo -e "${GREEN}✓ Media stack destroyed${NC}"
else
    echo -e "${YELLOW}⚠ Media stack not running${NC}"
fi
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Destroying infrastructure stack${NC}"
echo -e "${BLUE}========================================${NC}"
if docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
    docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" down $COMPOSE_OPTS
    echo -e "${GREEN}✓ Infrastructure stack destroyed${NC}"
else
    echo -e "${YELLOW}⚠ Infrastructure stack not running${NC}"
fi
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Cleanup${NC}"
echo -e "${BLUE}========================================${NC}"

# Remove orphaned containers from the known service set.
KNOWN_CONTAINERS=(
    caddy portainer ddns-updater wg-easy authelia dashdot
    gluetun deluge prowlarr radarr sonarr lidarr bazarr
    jellyfin jellyseerr homarr
)
ORPHANS=()
for name in "${KNOWN_CONTAINERS[@]}"; do
    if docker ps -aq --filter "name=^${name}$" --format '{{.Names}}' 2>/dev/null | grep -q .; then
        ORPHANS+=("$name")
    fi
done
if [[ ${#ORPHANS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}Removing orphaned containers: ${ORPHANS[*]}${NC}"
    docker rm -f "${ORPHANS[@]}" 2>/dev/null || true
    echo -e "${GREEN}✓ Orphaned containers removed${NC}"
fi

# Remove home_network if no longer in use.
if docker network inspect home_network &>/dev/null; then
    NETWORK_IN_USE=$(docker network inspect home_network --format='{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || true)
    if [[ -z "$NETWORK_IN_USE" ]]; then
        docker network rm home_network 2>/dev/null || true
        echo -e "${GREEN}✓ Network removed${NC}"
    else
        echo -e "${YELLOW}⚠ home_network still in use by: $NETWORK_IN_USE${NC}"
    fi
fi
echo ""

if [[ "$REMOVE_ALL" == "true" ]]; then
    echo -e "${RED}========================================${NC}"
    echo -e "${RED}Deleting config directories${NC}"
    echo -e "${RED}========================================${NC}"
    for dir in "$ARR_CONFIG_DIR" "$INFRASTRUCTURE_CONFIG_DIR"; do
        if [[ -d "$dir" ]]; then
            sudo rm -rf "$dir"
            echo -e "${GREEN}✓ Deleted ${dir}${NC}"
        else
            echo -e "${YELLOW}⚠ ${dir} not found, skipping${NC}"
        fi
    done
    echo ""
fi

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Destroy complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

if [[ "$REMOVE_ALL" == "true" ]]; then
    echo -e "${RED}⚠ All volumes and config directories deleted${NC}"
    echo "Start fresh with: ./deploy.sh"
elif [[ "$REMOVE_VOLUMES" == "true" ]]; then
    echo -e "${RED}⚠ Volumes removed${NC}"
    echo "Config dirs preserved at: ${INFRASTRUCTURE_CONFIG_DIR}, ${ARR_CONFIG_DIR}"
    echo "Redeploy with: ./deploy.sh"
else
    echo "Volumes and config preserved at: ${INFRASTRUCTURE_CONFIG_DIR}, ${ARR_CONFIG_DIR}, /data/media/"
    echo "Redeploy with: ./deploy.sh"
    echo "Full wipe: ./destroy.sh --all"
fi
echo ""
