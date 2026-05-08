#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Infrastructure Stack - Standalone Deployment Script
# =============================================================================
# Deploys only the infrastructure stack (Caddy, Portainer, DDNS, WireGuard,
# Authelia). For full stack deployment, use ../deploy.sh from the repo root.
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
echo -e "${BLUE}Infrastructure Stack Deployment${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

ensure_env_file "${ENV_FILE}" "${ENV_EXAMPLE}"
# shellcheck disable=SC1090
source "${ENV_FILE}"

INFRASTRUCTURE_CONFIG_DIR="${INFRASTRUCTURE_CONFIG_DIR:-/data/docker/infrastructure/config}"

echo -e "${BLUE}Configuration:${NC}"
echo -e "  Config directory: ${INFRASTRUCTURE_CONFIG_DIR}"
echo -e "  Domain: ${DOMAIN:-yourdomain.com}"
echo -e "  Timezone: ${TZ:-Europe/Vienna}"
echo ""

echo -e "${BLUE}Creating configuration directories...${NC}"
mkdir -p "${INFRASTRUCTURE_CONFIG_DIR}"/{caddy,portainer,ddns-updater,wg-easy,authelia}
echo -e "${GREEN}✓ Configuration directories created${NC}"
echo ""

echo -e "${BLUE}Configuring Authelia authentication...${NC}"
ensure_authelia_secrets "${ENV_FILE}"
deploy_authelia_config \
    "${SCRIPT_DIR}/authelia/configuration.yml" \
    "${INFRASTRUCTURE_CONFIG_DIR}/authelia" \
    "${DOMAIN:-yourdomain.com}" \
    "${AUTHELIA_JWT_SECRET}"
deploy_authelia_users \
    "${SCRIPT_DIR}/authelia/users_database.yml" \
    "${INFRASTRUCTURE_CONFIG_DIR}/authelia"
echo -e "${GREEN}✓ Authelia configured${NC}"
echo ""

echo -e "${BLUE}Syncing Caddyfile...${NC}"
sync_caddyfile \
    "${SCRIPT_DIR}/Caddyfile" \
    "${INFRASTRUCTURE_CONFIG_DIR}/caddy/Caddyfile"
echo ""

generate_ddns_config "${INFRASTRUCTURE_CONFIG_DIR}/ddns-updater"
echo ""

echo -e "${BLUE}Deploying infrastructure stack...${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" up -d
docker exec caddy caddy reload --config /etc/caddy/Caddyfile 2>/dev/null || true

sleep 3

echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Deployment Status${NC}"
echo -e "${BLUE}========================================${NC}"
docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/docker-compose.yml" ps
echo ""

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}Service Access Information${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "${GREEN}Infrastructure Services:${NC}"
echo -e "  Authelia:      https://auth.${DOMAIN:-yourdomain.com}"
echo -e "  Dashdot:       https://dash.${DOMAIN:-yourdomain.com}"
echo -e "  Portainer:     https://portainer.${DOMAIN:-yourdomain.com}"
echo -e "  DDNS Updater:  https://ddns.${DOMAIN:-yourdomain.com}"
echo -e "  WireGuard:     https://wireguard.${DOMAIN:-yourdomain.com}"
echo ""
echo -e "${YELLOW}Root CA: https://ca.${DOMAIN:-yourdomain.com}/root.crt${NC}"
echo ""
echo -e "${GREEN}✓ Infrastructure stack deployed successfully!${NC}"
echo ""
