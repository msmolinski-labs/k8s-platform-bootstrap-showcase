#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/kubectl-env.sh --env <dev|prod> [--kubeconfig /path/to/file] <kubectl-args...>

Examples:
  ./scripts/kubectl-env.sh --env dev get nodes
  ./scripts/kubectl-env.sh --env prod get applications -n argocd
EOF
}

ENV_NAME=""
KUBECONFIG_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_NAME="$2"
            shift 2
            ;;
        --kubeconfig)
            KUBECONFIG_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

if [[ -z "${ENV_NAME}" ]]; then
    echo "ERROR: --env is required" >&2
    usage >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "ERROR: Missing kubectl arguments" >&2
    usage >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -n "${KUBECONFIG_PATH}" ]]; then
    exec "${SCRIPT_DIR}/with-kubeconfig.sh" --env "${ENV_NAME}" --kubeconfig "${KUBECONFIG_PATH}" -- kubectl "$@"
fi

exec "${SCRIPT_DIR}/with-kubeconfig.sh" --env "${ENV_NAME}" -- kubectl "$@"