#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/teardown-lb-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "teardown-lb started at $(date)"
echo "Log: ${LOG_FILE}"

ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/lb-prod/hosts.yml"

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

expected_branch_for_lb_env() {
    local env_name="$1"
    local cluster_env="${env_name#lb-}"
    if [[ "$cluster_env" == "prod" ]]; then
        echo "main"
    else
        echo "$cluster_env"
    fi
}

confirm() {
    echo ""
    read -r -p "$(echo -e "${BOLD}$1 [y/N]:${NC} ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

case "${_INV_NAME}" in
    lb-dev|lb-prod)
        ;;
    *)
        print_error "Unsupported load balancer inventory: ${INVENTORY}"
        print_info "Use ansible/inventory/lb-dev/hosts.yml or ansible/inventory/lb-prod/hosts.yml"
        exit 1
        ;;
esac

CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
EXPECTED_BRANCH="$(expected_branch_for_lb_env "${_INV_NAME}")"

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
    print_info "If you intended to teardown dev LB, run: ./scripts/teardown-lb.sh --inventory ansible/inventory/lb-dev/hosts.yml"
    print_info "If you intended to teardown prod LB, switch to branch main first."
    exit 1
fi

print_header "TEARDOWN LOAD BALANCER – ${_INV_NAME}"

echo -e "  ${RED}${BOLD}WARNING: This will remove nginx from the LB VPS.${NC}"
echo ""
echo -e "  Run this ONLY when permanently decommissioning the environment."
echo -e "  Do NOT run this during a normal cluster rebuild."
echo ""
echo -e "  After teardown:"
echo -e "    - nginx will be uninstalled from ${BOLD}${_INV_NAME}${NC} LB VPS"
echo -e "    - UFW will be reset to defaults (SSH remains open)"
echo -e "    - Cloudflare Origin Certificate will be removed from the VPS"
echo -e "      (your local files in ~/.cloudflare/ are NOT touched)"
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
    if ! confirm "Are you sure you want to teardown the ${_INV_NAME} load balancer?"; then
        print_warn "Teardown aborted."
        exit 0
    fi
fi

print_header "STEP 1: Verifying SSH connectivity to load balancer"

inventory_load

LB_IP=""
LB_ALIAS=""
for alias in "${!HOSTS[@]}"; do
    if [[ "$alias" == *"load-balancer"* ]] || [[ "$alias" == *"lb"* ]]; then
        LB_IP="${HOSTS[$alias]}"
        LB_ALIAS="$alias"
        break
    fi
done

if [[ -z "$LB_IP" ]]; then
    print_error "No load balancer host found in inventory."
    print_info  "Expected host alias containing 'load-balancer' or 'lb'."
    exit 1
fi

if ssh -i "${SSH_KEY}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o BatchMode=yes "${ANSIBLE_USER}@${LB_IP}" "echo ok" &>/dev/null; then
    print_ok "${LB_ALIAS} (${LB_IP})"
else
    print_error "${LB_ALIAS} (${LB_IP}) – connection failed"
    print_info  "Cannot reach LB VPS. Check SSH key and connectivity."
    exit 1
fi

print_header "STEP 2: Removing nginx from load balancer"

echo -e "  Target: ${BOLD}${LB_ALIAS} (${LB_IP})${NC}"
echo ""

ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${ANSIBLE_USER}@${LB_IP}" bash <<'REMOTE'
set -euo pipefail

echo "  → Stopping nginx..."
systemctl stop nginx 2>/dev/null || true
systemctl disable nginx 2>/dev/null || true

echo "  → Removing nginx config..."
rm -f /etc/nginx/sites-enabled/k8s-lb.conf
rm -f /etc/nginx/sites-available/k8s-lb.conf

echo "  → Removing Cloudflare Origin Certificate..."
rm -rf /etc/ssl/cloudflare

echo "  → Uninstalling nginx..."
apt-get remove --purge -y nginx nginx-common nginx-full 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

echo "  → Resetting UFW to defaults (SSH stays open)..."
ufw --force reset
ufw allow 22/tcp
ufw --force enable

echo "  → Done."
REMOTE

print_header "Load balancer teardown complete"

echo -e "  ${GREEN}${BOLD}nginx removed from ${LB_ALIAS} (${LB_IP})${NC}"
echo ""
echo -e "  UFW reset — only SSH (port 22) is open."
echo -e "  Your local cert files in ${YELLOW}~/.cloudflare/${NC} were NOT touched."
echo ""
echo -e "  To rebuild the load balancer later:"
echo -e "    ${YELLOW}./scripts/setup-lb.sh --inventory ${INVENTORY}${NC}"
echo ""
