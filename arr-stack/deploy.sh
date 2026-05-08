#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Media Automation Stack (arr-stack) - Standalone Deployment Script
# =============================================================================
# Deploys only the media automation stack.
# REQUIRES: Infrastructure stack to be deployed first (provides home_network).
# For full deployment use ../deploy.sh from the repo root.
#
# Usage: ./deploy.sh
# =============================================================================

clear

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
ENV_FILE="${ROOT_DIR}/.env"
ENV_EXAMPLE="${ROOT_DIR}/.env.example"

# shellcheck source=../lib/deploy-helpers.sh
source "${ROOT_DIR}/lib/deploy-helpers.sh"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Media Automation Stack Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo "Checking infrastructure requirements..."
if ! docker network inspect home_network &>/dev/null; then
    echo -e "${RED}✗ Infrastructure network not found${NC}"
    echo ""
    echo "This stack requires the infrastructure stack first:"
    echo "  cd ../infrastructure && ./deploy.sh"
    exit 1
fi
echo -e "${GREEN}✓ Infrastructure network (home_network) found${NC}"
echo ""

ensure_env_file "${ENV_FILE}" "${ENV_EXAMPLE}"
# shellcheck disable=SC1090
source "${ENV_FILE}"

ARR_CONFIG_DIR="${ARR_CONFIG_DIR:-/data/docker/arr-stack/config}"
DATA_DIR="${DATA_DIR:-/data/media}"

echo -e "${BLUE}Configuration:${NC}"
echo -e "  Config directory: ${ARR_CONFIG_DIR}"
echo -e "  Media directory: ${DATA_DIR}"
echo -e "  Timezone: ${TZ:-Europe/Vienna}"
echo ""

require_env_var HOMARR_SECRET_KEY "Generate with: openssl rand -hex 32"

echo "Validating VPN configuration..."
if validate_vpn_credentials; then
    echo -e "${GREEN}✓ ${VPN_SERVICE_PROVIDER:-mullvad} VPN credentials found${NC}"
else
    echo -e "${YELLOW}⚠️  WARNING: VPN credentials not configured in .env${NC}"
    echo "   Configure ${VPN_SERVICE_PROVIDER:-mullvad} credentials in .env"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled"
        exit 1
    fi
fi
echo ""

echo -e "${BLUE}Creating directories...${NC}"
mkdir -p "${ARR_CONFIG_DIR}"/{gluetun,deluge,lidarr,bazarr,radarr,sonarr,prowlarr,jellyfin,jellyseerr,homarr}
mkdir -p "${DATA_DIR}"/{movies,tvseries,anime,music,iptv,downloads}
echo -e "${GREEN}✓ Directories created${NC}"
echo ""

echo -e "${BLUE}Deploying stack with Docker Compose...${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" up -d
echo ""

echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" ps
echo ""

echo "Waiting for VPN to establish connection..."
VPN_IP=""
for i in {1..30}; do
    VPN_IP=$(docker exec gluetun wget -qO- --timeout=2 -4 https://api.ipify.org 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || echo "")
    if [[ -n "${VPN_IP}" ]]; then
        echo -e "${GREEN}✓ VPN connected after ${i} seconds${NC}"
        break
    fi
    sleep 1
done

HOST_IP=$(curl -4 -s --max-time 5 https://api.ipify.org 2>/dev/null || echo "")

if [[ -n "${VPN_IP}" ]] && [[ -n "${HOST_IP}" ]]; then
    echo "VPN IP (Deluge):  ${VPN_IP}"
    echo "Host IP (Server): ${HOST_IP}"
    if [[ "${VPN_IP}" != "${HOST_IP}" ]]; then
        echo -e "${GREEN}✓ VPN is working - Your torrent traffic is protected!${NC}"
    else
        echo -e "${RED}⚠️  WARNING: VPN IP matches host IP - VPN may not be working!${NC}"
    fi
elif [[ -n "${VPN_IP}" ]]; then
    echo -e "${GREEN}✓ VPN connected - Public IP: ${VPN_IP}${NC}"
else
    echo -e "${YELLOW}⚠️  VPN status unknown - check logs: docker logs gluetun${NC}"
fi
echo ""

echo "Access services via Caddy at https://<service>.${DOMAIN:-yourdomain.com}"
echo "Direct local HTTP ports: see arr-stack/docker-compose.yml"
echo ""
echo -e "${GREEN}✓ Media automation stack deployed successfully!${NC}"
echo ""
