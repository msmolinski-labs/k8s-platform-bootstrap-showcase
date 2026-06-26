#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/teardown-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "teardown started at $(date)"
echo "Log: ${LOG_FILE}"

ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/prod/hosts.yml"
LEGACY_VAULT_FILE=""

for arg in "$@"; do
    case $arg in
        --inventory=*) INVENTORY="${arg#*=}" ;;
        --inventory)   shift; INVENTORY="$1" ;;
    esac
done

if [[ ! -f "${INVENTORY}" ]]; then
    echo "ERROR: Inventory file not found: ${INVENTORY}"
    exit 1
fi

export INVENTORY
# shellcheck source=./scripts/lib/inventory.sh
source "${SCRIPT_DIR}/lib/inventory.sh"

INVENTORY_DIR="$(dirname "${INVENTORY}")"
_INV_NAME="$(basename "${INVENTORY_DIR}")"
LEGACY_VAULT_FILE="${INVENTORY_DIR}/group_vars/all/vault.yml"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

print_header() { echo ""; echo -e "${BLUE}${BOLD}=== $1 ===${NC}"; echo ""; }
print_ok()     { echo -e "  ${GREEN}✓${NC} $1"; }
print_warn()   { echo -e "  ${YELLOW}⚠${NC}  $1"; }
print_error()  { echo -e "  ${RED}✗${NC} $1"; }
print_info()   { echo -e "  ${BLUE}→${NC} $1"; }

resolve_env_kubeconfig() {
    local env_name="$1"

    if [[ -n "${KUBECONFIG:-}" ]]; then
        echo "${KUBECONFIG}"
        return 0
    fi

    if [[ -f "${HOME}/.kube/${env_name}.yaml" ]]; then
        echo "${HOME}/.kube/${env_name}.yaml"
        return 0
    fi

    if [[ -f "${HOME}/.kube/config" ]]; then
        echo "${HOME}/.kube/config"
        return 0
    fi

    echo ""
}

expected_branch_for_env() {
    local env_name="$1"
    if [[ "$env_name" == "prod" ]]; then
        echo "main"
    else
        echo "$env_name"
    fi
}

case "${_INV_NAME}" in
    dev|prod)
        ;;
    *)
        print_error "Unsupported cluster inventory: ${INVENTORY}"
        print_info "Use ansible/inventory/dev/hosts.yml or ansible/inventory/prod/hosts.yml"
        print_info "Load balancer teardown is handled by ./scripts/teardown-lb.sh"
        exit 1
        ;;
esac

if [[ -f "${LEGACY_VAULT_FILE}" ]]; then
    print_error "Legacy ansible-vault file detected: ${LEGACY_VAULT_FILE}"
    print_info "Ansible auto-loads group_vars/all/vault.yml even during teardown."
    print_info "This repository now uses group_vars/all/secrets.sops.yaml instead."
    print_info "After confirming any needed values were migrated, rename or remove the legacy file and retry."
    print_info "Example: mv ${LEGACY_VAULT_FILE} ${LEGACY_VAULT_FILE}.legacy"
    exit 1
fi

CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
EXPECTED_BRANCH="$(expected_branch_for_env "${_INV_NAME}")"

if [[ "${CURRENT_BRANCH}" == "HEAD" ]]; then
    print_error "Detached HEAD detected. Teardown must run from a named branch."
    print_info "Expected branch for ${_INV_NAME}: ${EXPECTED_BRANCH}"
    exit 1
fi

if [[ "${CURRENT_BRANCH}" != "${EXPECTED_BRANCH}" ]]; then
    print_error "Inventory/branch mismatch detected."
    print_info "Inventory selects environment: ${_INV_NAME}"
    print_info "Current git branch: ${CURRENT_BRANCH}"
    print_info "Expected git branch: ${EXPECTED_BRANCH}"
    print_info "If you intended to teardown dev, run: ./scripts/teardown.sh --inventory ansible/inventory/dev/hosts.yml"
    print_info "If you intended to teardown prod, switch to branch main first."
    exit 1
fi

KUBECONFIG_PATH="$(resolve_env_kubeconfig "${_INV_NAME}")"
if [[ -n "${KUBECONFIG_PATH}" ]]; then
    export KUBECONFIG="${KUBECONFIG_PATH}"
fi

CURRENT_KUBECTL_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"

if [[ -z "${CURRENT_KUBECTL_CONTEXT}" ]]; then
    print_error "kubectl current-context is not set."
    print_info "Expected kubectl context for ${_INV_NAME}: ${_INV_NAME}"
    if [[ -f "${HOME}/.kube/${_INV_NAME}.yaml" ]]; then
        print_info "Run: ./scripts/kubectl-env.sh --env ${_INV_NAME} get nodes"
    else
        print_info "Expected kubeconfig file: ${HOME}/.kube/${_INV_NAME}.yaml"
    fi
    exit 1
fi

if [[ "${CURRENT_KUBECTL_CONTEXT}" != "${_INV_NAME}" ]]; then
    print_error "kubectl context/environment mismatch detected."
    print_info "Inventory selects environment: ${_INV_NAME}"
    print_info "Current kubectl context: ${CURRENT_KUBECTL_CONTEXT}"
    print_info "Expected kubectl context: ${_INV_NAME}"
    print_info "Teardown uninstalls ArgoCD and Cilium from localhost before resetting nodes."
    if [[ "${KUBECONFIG_PATH}" == "${HOME}/.kube/config" ]]; then
        print_info "Run: kubectl config use-context ${_INV_NAME}"
    else
        print_info "Run: ./scripts/kubectl-env.sh --env ${_INV_NAME} get nodes"
    fi
    exit 1
fi

print_header "TEARDOWN CLUSTER – ${_INV_NAME}"

echo -e "  ${RED}${BOLD}WARNING: This will permanently destroy the cluster.${NC}"
echo ""
echo -e "  What will be destroyed:"
echo -e "    - Kubernetes cluster (all nodes)"
echo -e "    - All workloads and data in the cluster"
echo -e "    - MinIO storage data (Loki logs)"
echo -e "    - Local kubeconfig context for ${BOLD}${_INV_NAME}${NC}"
echo ""
echo -e "  What will NOT be affected:"
echo -e "    - Load balancer VPS (nginx stays running, returns 502)"
echo -e "    - Git repository"
echo -e "    - Local secrets files and temp password exports"
echo ""

if [[ "${_INV_NAME}" == "prod" ]]; then
    echo -e "  ${RED}${BOLD}This is a PRODUCTION environment.${NC}"
    echo -e "  Type ${BOLD}prod${NC} to confirm teardown:"
    echo ""
    read -r _confirm
    if [[ "${_confirm}" != "prod" ]]; then
        print_warn "Teardown aborted. You must type 'prod' exactly to confirm."
        exit 0
    fi
else
    echo ""
    read -r -p "$(echo -e "${BOLD}  Are you sure you want to teardown the ${_INV_NAME} cluster? [y/N]:${NC} ")" response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_warn "Teardown aborted."
        exit 0
    fi
fi

print_header "STEP 1: Verifying SSH connectivity"

inventory_load
inventory_print

all_ok=true
for alias in $(echo "${!HOSTS[@]}" | tr ' ' '\n' | sort); do
    ip="${HOSTS[$alias]}"
    if ssh -i "${SSH_KEY}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
        -o BatchMode=yes "${ANSIBLE_USER}@${ip}" "echo ok" &>/dev/null; then
        print_ok "${alias} (${ip})"
    else
        print_error "${alias} (${ip}) – connection failed"
        all_ok=false
    fi
done

if [[ "$all_ok" == false ]]; then
    echo ""
    print_warn "Some servers are unreachable. Teardown may be incomplete."
    echo ""
    read -r -p "$(echo -e "${BOLD}  Continue anyway? [y/N]:${NC} ")" response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        print_warn "Teardown aborted."
        exit 1
    fi
fi

print_header "STEP 2: Running teardown"

echo -e "  Environment: ${BOLD}${_INV_NAME}${NC}"
echo -e "  Inventory:   ${INVENTORY}"
echo ""

cd "${REPO_ROOT}"
ansible-playbook \
    -i "${INVENTORY}" \
    "${ANSIBLE_DIR}/teardown.yml" \
    -e "confirm_teardown=yes"

print_header "Teardown complete"

echo -e "  ${GREEN}${BOLD}Cluster ${_INV_NAME} destroyed.${NC}"
echo ""
echo -e "  Load balancer is still running and will return ${YELLOW}502 Bad Gateway${NC}."
echo -e "  This is expected — no cluster behind it."
echo ""
echo -e "  To rebuild:"
echo -e "    ${YELLOW}./scripts/bootstrap.sh --inventory ${INVENTORY}${NC}"
echo ""
