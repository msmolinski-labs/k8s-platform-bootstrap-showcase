#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  ./scripts/fetch-kubeconfig.sh --env <dev|prod> --host <automation-host> [options]

Options:
  --ssh-user <user>       Remote SSH user. Default: current local user.
  --ssh-key <path>        SSH private key. Default: ~/.ssh/k8s_homepl
  --remote-path <path>    Remote kubeconfig path. Default: ~/.kube/<env>.yaml
  --local-path <path>     Local destination path. Default: ~/.kube/<env>.yaml

Examples:
  ./scripts/fetch-kubeconfig.sh --env dev --host ops.example.com --ssh-user runner
  ./scripts/fetch-kubeconfig.sh --env prod --host 10.0.0.20 --remote-path /opt/kubeconfigs/prod.yaml
EOF
}

ENV_NAME=""
HOST=""
SSH_USER="${USER}"
SSH_KEY="${HOME}/.ssh/k8s_homepl"
REMOTE_PATH=""
LOCAL_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_NAME="$2"
            shift 2
            ;;
        --host)
            HOST="$2"
            shift 2
            ;;
        --ssh-user)
            SSH_USER="$2"
            shift 2
            ;;
        --ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        --remote-path)
            REMOTE_PATH="$2"
            shift 2
            ;;
        --local-path)
            LOCAL_PATH="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unexpected argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "${ENV_NAME}" || -z "${HOST}" ]]; then
    echo "ERROR: --env and --host are required" >&2
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

if [[ -z "${REMOTE_PATH}" ]]; then
    REMOTE_PATH="~/.kube/${ENV_NAME}.yaml"
fi

if [[ -z "${LOCAL_PATH}" ]]; then
    LOCAL_PATH="${HOME}/.kube/${ENV_NAME}.yaml"
fi

mkdir -p "$(dirname "${LOCAL_PATH}")"

if [[ -f "${LOCAL_PATH}" ]]; then
    cp "${LOCAL_PATH}" "${LOCAL_PATH}.bak"
    echo "Backed up existing kubeconfig to ${LOCAL_PATH}.bak"
fi

scp -q -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SSH_USER}@${HOST}:${REMOTE_PATH}" \
    "${LOCAL_PATH}"

chmod 600 "${LOCAL_PATH}"

echo "Fetched kubeconfig for ${ENV_NAME} to ${LOCAL_PATH}"
echo "Run: ./scripts/kubectl-env.sh --env ${ENV_NAME} get nodes"