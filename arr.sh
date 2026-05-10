#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
USAGE
    ./arr.sh <command> [options]

COMMANDS
    deploy
        Deploy the full stack (infrastructure + media automation) in the
        correct order. Re-run safe: existing config files are preserved.
        Set FORCE_CADDYFILE=true to overwrite the deployed Caddyfile.

    destroy [--volumes] [--all] [-y]
        Stop and remove all containers.
          --volumes   Also remove Docker volumes (WARNING: deletes all data)
          --all       Remove volumes AND config directories on disk
          -y          Skip confirmation prompt

    backup
        Trigger built-in backups for *arr apps via their API, then tar
        configs for all other services. Archive saved to BACKUP_BASE
        (default: /data/backups/arr-stack). Keeps last 5 archives.

    restore <backup-file.tar.gz>
        Restore all service configs from a backup archive. Creates a
        pre-restore snapshot automatically. Stops services during restore
        and restarts them after.

    status
        Show container status for both stacks.

    logs [service]
        Follow logs from both stacks. Pass a service name to filter.
EOF
    exit "${1:-0}"
}

cmd_deploy() {
    exec "${SCRIPT_DIR}/deploy.sh" "$@"
}

cmd_destroy() {
    exec "${SCRIPT_DIR}/destroy.sh" "$@"
}

cmd_backup() {
    exec "${SCRIPT_DIR}/arr-stack/backup.sh" "$@"
}

cmd_restore() {
    if [[ $# -lt 1 ]]; then
        echo "Usage: ./arr.sh restore <backup-file.tar.gz>" >&2
        exit 1
    fi
    exec "${SCRIPT_DIR}/arr-stack/restore.sh" "$@"
}

cmd_status() {
    local ENV_FILE="${SCRIPT_DIR}/.env"
    echo "=== Infrastructure ==="
    docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" ps
    echo ""
    echo "=== Media Stack ==="
    docker compose --env-file "${ENV_FILE}" -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" ps
}

cmd_logs() {
    local ENV_FILE="${SCRIPT_DIR}/.env"
    if [[ $# -gt 0 ]]; then
        # If a service name is given, try both compose files
        docker compose --env-file "${ENV_FILE}" \
            -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" \
            -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" \
            logs -f "$@"
    else
        docker compose --env-file "${ENV_FILE}" \
            -f "${SCRIPT_DIR}/infrastructure/docker-compose.yml" \
            -f "${SCRIPT_DIR}/arr-stack/docker-compose.yml" \
            logs -f
    fi
}

case "${1:-}" in
    deploy)  shift; cmd_deploy "$@" ;;
    destroy) shift; cmd_destroy "$@" ;;
    backup)  shift; cmd_backup "$@" ;;
    restore) shift; cmd_restore "$@" ;;
    status)  cmd_status ;;
    logs)    shift; cmd_logs "$@" ;;
    -h|--help|help|"") usage 0 ;;
    *)
        echo "Unknown command: ${1}" >&2
        echo ""
        usage 1
        ;;
esac
