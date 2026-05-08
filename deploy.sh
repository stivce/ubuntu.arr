#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Home Server Stack - Master Deployment Script
# =============================================================================
# Orchestrates deployment of both infrastructure and arr-stack in correct order.
# Re-run safe: existing config files are preserved (set FORCE_CADDYFILE=true to
# overwrite the deployed Caddyfile from the repo template).
#
# Usage: ./deploy.sh
# =============================================================================

clear

cat << "EOF"
 _   _                        ____
| | | | ___  _ __ ___   ___  / ___|  ___ _ ____   _____ _ __
| |_| |/ _ \| '_ ` _ \ / _ \ \___ \ / _ \ '__\ \ / / _ \ '__|
|  _  | (_) | | | | | |  __/  ___) |  __/ |   \ V /  __/ |
|_| |_|\___/|_| |_| |_|\___| |____/ \___|_|    \_/ \___|_|

 ____  _             _
/ ___|| |_ __ _  ___| | __
\___ \| __/ _` |/ __| |/ /
 ___) | || (_| | (__|   <
|____/ \__\__,_|\___|_|\_\

EOF

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# shellcheck source=lib/deploy-helpers.sh
source "${SCRIPT_DIR}/lib/deploy-helpers.sh"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Home Server Stack Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

ensure_env_file "${ENV_FILE}" "${ENV_EXAMPLE}"
# shellcheck disable=SC1090
source "${ENV_FILE}"

INFRASTRUCTURE_CONFIG_DIR="${INFRASTRUCTURE_CONFIG_DIR:-/data/docker/infrastructure/config}"
ARR_CONFIG_DIR="${ARR_CONFIG_DIR:-/data/docker/arr-stack/config}"
DATA_DIR="${DATA_DIR:-/data/media}"

echo -e "${BLUE}Configuration:${NC}"
echo -e "  Domain: ${DOMAIN:-yourdomain.com}"
echo -e "  Infrastructure config: ${INFRASTRUCTURE_CONFIG_DIR}"
echo -e "  Arr-stack config: ${ARR_CONFIG_DIR}"
echo -e "  Media directory: ${DATA_DIR}"
echo -e "  Timezone: ${TZ:-Europe/Vienna}"
echo ""

require_env_var HOMARR_SECRET_KEY "Generate with: openssl rand -hex 32"

# =============================================================================
# Step 1: Deploy Infrastructure Stack
# =============================================================================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Step 1: Infrastructure Stack${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${BLUE}Creating infrastructure directories...${NC}"
mkdir -p "${INFRASTRUCTURE_CONFIG_DIR}"/{caddy,portainer,ddns-updater,wg-easy,authelia}
echo -e "${GREEN}✓ Infrastructure directories created${NC}"
echo ""

echo -e "${BLUE}Configuring Authelia authentication...${NC}"
ensure_authelia_secrets "${ENV_FILE}"
deploy_authelia_config \
    "${SCRIPT_DIR}/infrastructure/authelia/configuration.yml" \
    "${INFRASTRUCTURE_CONFIG_DIR}/authelia" \
    "${DOMAIN:-yourdomain.com}" \
    "${AUTHELIA_JWT_SECRET}"
deploy_authelia_users \
    "${SCRIPT_DIR}/infrastructure/authelia/users_database.yml" \
    "${INFRASTRUCTURE_CONFIG_DIR}/authelia"
echo -e "${GREEN}✓ Authelia configured${NC}"
echo ""

echo -e "${BLUE}Syncing Caddyfile...${NC}"
sync_caddyfile \
    "${SCRIPT_DIR}/infrastructure/Caddyfile" \
    "${INFRASTRUCTURE_CONFIG_DIR}/caddy/Caddyfile"
echo ""

generate_ddns_config "${INFRASTRUCTURE_CONFIG_DIR}/ddns-updater"
echo ""

echo -e "${BLUE}Deploying infrastructure services...${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" up -d
docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true
echo -e "${GREEN}✓ Infrastructure stack deployed${NC}"
echo ""

echo -e "${BLUE}Waiting for infrastructure services to be ready...${NC}"
sleep 5

if docker network inspect home_network &>/dev/null; then
    echo -e "${GREEN}✓ Infrastructure network (home_network) created${NC}"
else
    echo -e "${RED}✗ Infrastructure network creation failed${NC}"
    exit 1
fi
echo ""

# =============================================================================
# Step 2: Deploy Arr-Stack
# =============================================================================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Step 2: Media Automation Stack${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo "Validating VPN configuration..."
if validate_vpn_credentials; then
    echo -e "${GREEN}✓ ${VPN_SERVICE_PROVIDER:-mullvad} VPN credentials found${NC}"
else
    echo -e "${YELLOW}⚠️  WARNING: VPN credentials not configured in .env${NC}"
    echo "   Deluge will route through VPN but connection may fail"
    echo "   Please configure ${VPN_SERVICE_PROVIDER:-mullvad} credentials in .env"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Deployment cancelled"
        exit 1
    fi
fi
echo ""

echo -e "${BLUE}Creating arr-stack directories...${NC}"
mkdir -p "${ARR_CONFIG_DIR}"/{gluetun,deluge,lidarr,bazarr,radarr,sonarr,prowlarr,jellyfin,jellyseerr,homarr}
mkdir -p "${DATA_DIR}"/{movies,tvseries,anime,music,iptv,downloads}
echo -e "${GREEN}✓ Arr-stack directories created${NC}"
echo ""

echo -e "${BLUE}Deploying media automation services...${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" up -d
echo -e "${GREEN}✓ Media automation stack deployed${NC}"
echo ""

# =============================================================================
# Step 3: Verify Deployment
# =============================================================================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Status${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${BLUE}Infrastructure Services:${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" ps
echo ""

echo -e "${BLUE}Media Services:${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" ps
echo ""

echo -e "${BLUE}Verifying VPN connection...${NC}"
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
        echo "   Check logs: docker logs gluetun"
    fi
elif [[ -n "${VPN_IP}" ]]; then
    echo -e "${GREEN}✓ VPN connected - Public IP: ${VPN_IP}${NC}"
else
    echo -e "${YELLOW}⚠️  VPN status unknown - check logs: docker logs gluetun${NC}"
fi
echo ""

# =============================================================================
# Step 4: Display Access Information
# =============================================================================

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Service Access Information${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

echo -e "${GREEN}📥 FIRST TIME SETUP - Install Root CA Certificate:${NC}"
echo -e "   ${BLUE}https://ca.${DOMAIN:-yourdomain.com}/root.crt${NC}"
echo ""

echo -e "${GREEN}Infrastructure Services:${NC}"
echo -e "  Authelia:      https://auth.${DOMAIN:-yourdomain.com}"
echo -e "  Dashdot:       https://dash.${DOMAIN:-yourdomain.com}"
echo -e "  Portainer:     https://portainer.${DOMAIN:-yourdomain.com}"
echo -e "  DDNS Updater:  https://ddns.${DOMAIN:-yourdomain.com}"
echo -e "  WireGuard:     https://wireguard.${DOMAIN:-yourdomain.com}"
echo ""

echo -e "${GREEN}Media Services:${NC}"
for svc in homarr prowlarr radarr sonarr lidarr bazarr jellyfin jellyseerr deluge; do
    echo -e "  ${svc^}: https://${svc}.${DOMAIN:-yourdomain.com}"
done
echo ""

echo -e "${GREEN}✓ Home server stack deployed successfully!${NC}"
echo ""
