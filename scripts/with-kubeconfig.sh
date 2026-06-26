#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/with-kubeconfig.sh --env <dev|prod> [--kubeconfig /path/to/file] -- <command> [args...]

Examples:
  ./scripts/with-kubeconfig.sh --env dev -- kubectl get nodes
  ./scripts/with-kubeconfig.sh --env prod -- ansible-playbook ansible/playbooks/13-deploy-garmin-ingest.yml -e env_name=prod

Defaults:
  --kubeconfig defaults to ~/.kube/<env>.yaml
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
        --)
            shift
            break
            ;;
        *)
            echo "ERROR: Unexpected argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${ENV_NAME}" ]]; then
    echo "ERROR: --env is required" >&2
    usage >&2
    exit 1
fi

case "${ENV_NAME}" in
    dev|prod)
        ;;
    *)
        echo "ERROR: Unsupported environment: ${ENV_NAME}" >&2
        exit 1
        ;;
esac

if [[ $# -eq 0 ]]; then
    echo "ERROR: Missing command after --" >&2
    usage >&2
    exit 1
fi

if [[ -z "${KUBECONFIG_PATH}" ]]; then
    KUBECONFIG_PATH="${HOME}/.kube/${ENV_NAME}.yaml"
fi

if [[ ! -f "${KUBECONFIG_PATH}" ]]; then
    echo "ERROR: kubeconfig file not found: ${KUBECONFIG_PATH}" >&2
    echo "Run bootstrap first or fetch the kubeconfig from the automation host." >&2
    exit 1
fi

export KUBECONFIG="${KUBECONFIG_PATH}"
exec "$@"