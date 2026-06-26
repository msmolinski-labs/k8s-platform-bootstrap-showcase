#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/setup-lb-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "setup-lb started at $(date)"
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

case "${_INV_NAME}" in
    lb-dev|lb-prod)
        ;;
    *)
        print_error "Unsupported load balancer inventory: ${INVENTORY}"
        print_info "Use ansible/inventory/lb-dev/hosts.yml or ansible/inventory/lb-prod/hosts.yml"
        print_info "Cluster bootstrap is handled by ./scripts/bootstrap.sh with ansible/inventory/dev/hosts.yml or prod/hosts.yml"
        exit 1
        ;;
esac

LB_ENV_NAME="${_INV_NAME#lb-}"

print_header "STEP 1: Verifying local tools"

MISSING=()
for tool in ansible ansible-playbook; do
    if command -v "$tool" &>/dev/null; then
        print_ok "$tool"
    else
        print_error "$tool – NOT FOUND"
        MISSING+=("$tool")
    fi
done

if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo ""
    print_error "Missing tools: ${MISSING[*]}"
    print_info  "Run ./scripts/setup-local.sh first."
    exit 1
fi

print_header "STEP 2: Verifying Cloudflare Origin Certificate"

VARS_FILE="${INVENTORY_DIR}/group_vars/all/vars.yml"

if [[ ! -f "${VARS_FILE}" ]]; then
    print_error "vars.yml not found: ${VARS_FILE}"
    exit 1
fi

CERT_SRC=$(python3 -c "
import yaml
with open('${VARS_FILE}') as f:
    v = yaml.safe_load(f)
print(v.get('cloudflare_origin_cert_src', ''))
" 2>/dev/null)

KEY_SRC=$(python3 -c "
import yaml
with open('${VARS_FILE}') as f:
    v = yaml.safe_load(f)
print(v.get('cloudflare_origin_key_src', ''))
" 2>/dev/null)

CERT_SRC="${CERT_SRC/#\~/$HOME}"
KEY_SRC="${KEY_SRC/#\~/$HOME}"

all_ok=true

if [[ -f "${CERT_SRC}" ]]; then
    print_ok "Origin certificate: ${CERT_SRC}"
else
    print_error "Origin certificate NOT FOUND: ${CERT_SRC}"
    all_ok=false
fi

if [[ -f "${KEY_SRC}" ]]; then
    print_ok "Origin private key: ${KEY_SRC}"
else
    print_error "Origin private key NOT FOUND: ${KEY_SRC}"
    all_ok=false
fi

if [[ "$all_ok" == false ]]; then
    echo ""
    print_error "Missing Cloudflare Origin Certificate files."
    echo ""
    echo -e "  Generate them in Cloudflare dashboard:"
    echo -e "    ${BOLD}SSL/TLS → Origin Server → Create Certificate${NC}"
        if [[ "${LB_ENV_NAME}" == "prod" ]]; then
            echo -e "    Hostnames: ${YELLOW}*.klexify.io${NC} + ${YELLOW}klexify.io${NC}"
        else
            echo -e "    Hostnames: ${YELLOW}*.dev-klexify.cloud${NC} + ${YELLOW}dev-klexify.cloud${NC}"
        fi
    echo -e "    Validity:  ${YELLOW}15 years${NC}"
    echo ""
    echo -e "  Save the files to:"
    echo -e "    ${YELLOW}${CERT_SRC}${NC}  ← paste Origin Certificate (PEM)"
    echo -e "    ${YELLOW}${KEY_SRC}${NC}  ← paste Private Key (PEM)"
    echo ""
    echo -e "  Then re-run this script."
    exit 1
fi

print_header "STEP 3: Verifying SSH connectivity to load balancer"

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
    print_info  "Check: ${INVENTORY}"
    exit 1
fi

if ssh -i "${SSH_KEY}" -o ConnectTimeout=5 -o StrictHostKeyChecking=no \
    -o BatchMode=yes "${ANSIBLE_USER}@${LB_IP}" "echo ok" &>/dev/null; then
    print_ok "${LB_ALIAS} (${LB_IP})"
else
    print_error "${LB_ALIAS} (${LB_IP}) – connection failed"
    echo ""
    print_info "Make sure your SSH key is on the LB VPS:"
    echo -e "    ${YELLOW}ssh-copy-id -i ${SSH_KEY}.pub ${ANSIBLE_USER}@${LB_IP}${NC}"
    exit 1
fi

print_header "STEP 4: Setting up load balancer"

echo -e "  Environment: ${BOLD}${_INV_NAME}${NC}"
echo -e "  LB VPS:      ${BOLD}${LB_ALIAS} (${LB_IP})${NC}"
echo -e "  Inventory:   ${INVENTORY}"
echo ""

cd "${REPO_ROOT}"

ansible-playbook \
    -i "${INVENTORY}" \
    "${ANSIBLE_DIR}/playbooks/12-setup-load-balancer.yml"

print_header "Load balancer ready"

echo -e "  ${GREEN}${BOLD}nginx installed and configured on ${LB_ALIAS} (${LB_IP})${NC}"
echo ""
echo -e "  Verify:"
echo -e "    ${YELLOW}ssh -i ${SSH_KEY} ${ANSIBLE_USER}@${LB_IP} \"nginx -t && systemctl status nginx\"${NC}"
echo ""
echo -e "  At this point nginx will return ${YELLOW}502 Bad Gateway${NC} — that is expected."
echo -e "  The cluster does not exist yet. Run bootstrap.sh to bring it up."
echo ""
_CLUSTER_INV="${INVENTORY/\/lb-/\/}"
echo -e "  Next step:"
echo -e "    ${YELLOW}./scripts/bootstrap.sh --inventory ${_CLUSTER_INV}${NC}"
echo ""
