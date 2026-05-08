#!/usr/bin/env bash
# Shared helpers for deploy scripts. Sourced by deploy.sh, infrastructure/deploy.sh, arr-stack/deploy.sh.

# Colors (only set if not already defined)
: "${GREEN:=$'\033[0;32m'}"
: "${BLUE:=$'\033[0;34m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${RED:=$'\033[0;31m'}"
: "${NC:=$'\033[0m'}"

# Portable in-place sed (works on BSD/macOS and GNU/Linux)
sed_inplace() {
    local expr="$1"
    local file="$2"
    local tmp
    tmp="$(mktemp)"
    sed "$expr" "$file" > "$tmp" && mv "$tmp" "$file"
}

# Persist a key=value to an env file. Sets only if missing or empty.
persist_env_var() {
    local var_name="$1" var_value="$2" env_file="$3"
    if grep -qE "^${var_name}=.+" "${env_file}"; then
        return 0
    elif grep -qE "^${var_name}=" "${env_file}"; then
        sed_inplace "s|^${var_name}=.*|${var_name}=${var_value}|" "${env_file}"
    else
        printf '\n%s=%s\n' "${var_name}" "${var_value}" >> "${env_file}"
    fi
}

# Ensure .env exists. If not, copy from .env.example and prompt the user to edit.
ensure_env_file() {
    local env_file="$1" env_example="$2"
    if [[ ! -f "${env_file}" ]]; then
        echo -e "${YELLOW}⚠ No .env file found. Creating from template...${NC}"
        cp "${env_example}" "${env_file}"
        echo -e "${GREEN}✓ Created ${env_file}${NC}"
        echo -e "${YELLOW}⚠ Please edit .env and configure your settings before continuing${NC}"
        echo ""
        read -p "Press Enter to continue after configuring .env, or Ctrl+C to exit..."
    fi
}

# Generate Authelia secrets in .env if missing.
ensure_authelia_secrets() {
    local env_file="$1"
    if [[ -z "${AUTHELIA_JWT_SECRET:-}" ]]; then
        AUTHELIA_JWT_SECRET=$(openssl rand -hex 32)
        persist_env_var "AUTHELIA_JWT_SECRET" "${AUTHELIA_JWT_SECRET}" "${env_file}"
        echo -e "${GREEN}  Generated AUTHELIA_JWT_SECRET${NC}"
    fi
    if [[ -z "${AUTHELIA_SESSION_SECRET:-}" ]]; then
        AUTHELIA_SESSION_SECRET=$(openssl rand -hex 32)
        persist_env_var "AUTHELIA_SESSION_SECRET" "${AUTHELIA_SESSION_SECRET}" "${env_file}"
        echo -e "${GREEN}  Generated AUTHELIA_SESSION_SECRET${NC}"
    fi
    if [[ -z "${AUTHELIA_STORAGE_ENCRYPTION_KEY:-}" ]]; then
        AUTHELIA_STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 32)
        persist_env_var "AUTHELIA_STORAGE_ENCRYPTION_KEY" "${AUTHELIA_STORAGE_ENCRYPTION_KEY}" "${env_file}"
        echo -e "${GREEN}  Generated AUTHELIA_STORAGE_ENCRYPTION_KEY${NC}"
    fi
    export AUTHELIA_IDENTITY_VALIDATION_RESET_PASSWORD_JWT_SECRET="${AUTHELIA_JWT_SECRET}"
    export AUTHELIA_SESSION_SECRET
    export AUTHELIA_STORAGE_ENCRYPTION_KEY
}

# Render Authelia configuration.yml from template (only if not already deployed).
deploy_authelia_config() {
    local template="$1" target_dir="$2" domain="$3" jwt_secret="$4"
    local target="${target_dir}/configuration.yml"
    if [[ ! -f "${target}" ]]; then
        sed -e "s/__DOMAIN__/${domain}/g" \
            -e "s/__JWT_SECRET__/${jwt_secret}/g" \
            "${template}" > "${target}"
        echo -e "${GREEN}  ✓ Authelia configuration generated${NC}"
    fi
}

# Create the Authelia users database (only if not already deployed).
deploy_authelia_users() {
    local fallback_template="$1" target_dir="$2"
    local target="${target_dir}/users_database.yml"
    [[ -f "${target}" ]] && return 0
    if [[ -n "${AUTHELIA_DEFAULT_PASSWORD_HASH:-}" ]]; then
        local user="${AUTHELIA_DEFAULT_USER:-admin}"
        cat > "${target}" <<USEREOF
users:
  ${user}:
    disabled: false
    displayname: '${user}'
    password: '${AUTHELIA_DEFAULT_PASSWORD_HASH}'
    email: 'admin@example.com'
    groups:
      - 'admins'
USEREOF
        echo -e "${GREEN}  ✓ Authelia users database created with user '${user}'${NC}"
    else
        echo -e "${RED}  ✗ AUTHELIA_DEFAULT_PASSWORD_HASH not set in .env${NC}"
        echo "     Generate one with:"
        echo "     docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password 'YOUR_PASSWORD'"
        read -p "Continue without Authelia user? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Deployment cancelled. Set AUTHELIA_DEFAULT_PASSWORD_HASH in .env first."
            exit 1
        fi
        cp "${fallback_template}" "${target}"
    fi
}

# Copy Caddyfile only if not already deployed (preserves manual edits).
# Use --force-caddyfile env or a flag to overwrite explicitly.
sync_caddyfile() {
    local source="$1" target="$2"
    if [[ ! -f "${target}" ]]; then
        cp "${source}" "${target}"
        echo -e "${GREEN}✓ Caddyfile installed${NC}"
    elif [[ "${FORCE_CADDYFILE:-false}" == "true" ]]; then
        cp "${source}" "${target}"
        echo -e "${YELLOW}✓ Caddyfile overwritten (FORCE_CADDYFILE=true)${NC}"
    else
        echo -e "${BLUE}  Caddyfile already exists, preserving manual edits${NC}"
        echo -e "${BLUE}  (set FORCE_CADDYFILE=true to overwrite)${NC}"
    fi
}

# Generate DDNS config.json if DDNS_ENABLED=true and inputs are present.
generate_ddns_config() {
    local target_dir="$1"
    [[ "${DDNS_ENABLED:-false}" == "true" ]] || {
        echo -e "${BLUE}DDNS auto-configuration disabled (DDNS_ENABLED=false)${NC}"
        return 0
    }
    if [[ -z "${DDNS_CLOUDFLARE_TOKEN:-}" ]] || [[ -z "${DDNS_CLOUDFLARE_ZONE_ID:-}" ]]; then
        echo -e "${YELLOW}⚠ DDNS_ENABLED=true but missing DDNS_CLOUDFLARE_TOKEN or DDNS_CLOUDFLARE_ZONE_ID${NC}"
        echo "   Skipping DDNS auto-configuration. Configure manually via Web UI."
        return 0
    fi
    local target="${target_dir}/config.json"
    if [[ -f "${target}" ]]; then
        echo -e "${BLUE}  DDNS config.json already exists, preserving${NC}"
        return 0
    fi
    cat > "${target}" <<EOF
{
  "settings": [
    {
      "provider": "${DDNS_PROVIDER:-cloudflare}",
      "zone_identifier": "${DDNS_CLOUDFLARE_ZONE_ID}",
      "domain": "${DDNS_DOMAIN:-${DOMAIN}}",
      "host": "${DDNS_HOST:-@}",
      "ttl": ${DDNS_TTL:-300},
      "token": "${DDNS_CLOUDFLARE_TOKEN}",
      "ip_version": "${DDNS_IP_VERSION:-ipv4}",
      "proxied": ${DDNS_PROXIED:-false}
    }
  ]
}
EOF
    echo -e "${GREEN}✓ DDNS config.json generated${NC}"
}

# Validate that critical secrets are non-empty before bringing up compose.
require_env_var() {
    local var_name="$1" hint="$2"
    if [[ -z "${!var_name:-}" ]]; then
        echo -e "${RED}✗ Required variable ${var_name} is not set in .env${NC}"
        echo "   ${hint}"
        exit 1
    fi
}

# Validate VPN credentials based on VPN_SERVICE_PROVIDER. Returns 0 if OK, 1 if missing.
validate_vpn_credentials() {
    local provider="${VPN_SERVICE_PROVIDER:-mullvad}"
    if [[ "${provider}" == "mullvad" ]]; then
        [[ -n "${MULLVAD_PRIVATE_KEY:-}" ]] && return 0
    elif [[ "${provider}" == "nordvpn" ]]; then
        [[ -n "${NORDVPN_USER:-}" ]] && [[ -n "${NORDVPN_PASSWORD:-}" ]] && return 0
    fi
    return 1
}
