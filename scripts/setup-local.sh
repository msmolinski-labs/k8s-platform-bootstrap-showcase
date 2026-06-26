#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./scripts/lib/local-tools.sh
source "${SCRIPT_DIR}/lib/local-tools.sh"
# shellcheck source=./scripts/lib/inventory.sh
source "${SCRIPT_DIR}/lib/inventory.sh"

ensure_python_yaml_runtime

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

confirm() {
    echo ""
    read -r -p "$(echo -e "${BOLD}$1 [y/N]:${NC} ")" response
    [[ "$response" =~ ^[Yy]$ ]]
}

print_header "STEP 1: Installing required tools"

if ! ensure_named_tools git ansible kubectl helm cilium kubeseal yq sops age; then
    print_error "Local workstation setup failed while installing required tools."
    exit 1
fi

print_header "Loading inventory"
inventory_load
inventory_print

print_header "STEP 2: SSH key for cluster nodes"

if [[ -f "${SSH_KEY}" ]]; then
    print_ok "SSH key already exists: ${SSH_KEY}"
else
    print_info "Generating new ED25519 SSH key: ${SSH_KEY}"
    mkdir -p "$(dirname "${SSH_KEY}")"
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "k8s-cluster-bootstrap"
    print_ok "SSH key generated: ${SSH_KEY}"
fi

echo ""
echo -e "${BOLD}  Your public key – copy and paste to each VPS:${NC}"
echo ""
echo -e "  ${YELLOW}$(cat "${SSH_KEY}.pub")${NC}"
echo ""

print_header "STEP 3: SSH config aliases"

SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$HOME/.ssh"
touch "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

for alias in "${!HOSTS[@]}"; do
    ip="${HOSTS[$alias]}"
    if grep -q "^Host ${alias}$" "$SSH_CONFIG" 2>/dev/null; then
        print_ok "Alias '${alias}' already in ~/.ssh/config"
    else
        cat >> "$SSH_CONFIG" <<EOF

Host ${alias}
    HostName ${ip}
    User ${ANSIBLE_USER}
    IdentityFile ${SSH_KEY}
    StrictHostKeyChecking no
EOF
        print_ok "Added alias '${alias}' → ${ip}"
    fi
done

print_header "STEP 4: Upload public key to VPS servers"

echo -e "  Upload your public key to all servers before continuing."
echo -e "  Run from a separate terminal:"
echo ""
for alias in $(echo "${!HOSTS[@]}" | tr ' ' '\n' | sort); do
    ip="${HOSTS[$alias]}"
    echo -e "    ${YELLOW}ssh-copy-id -i ${SSH_KEY}.pub ${ANSIBLE_USER}@${ip}${NC}  # ${alias}"
done
echo ""
echo -e "  If the VPS only allows password login on first access:"
echo -e "    ${YELLOW}ssh-copy-id -i ${SSH_KEY}.pub -o PubkeyAuthentication=no ${ANSIBLE_USER}@<IP>${NC}"
echo ""

if ! confirm "Have you uploaded the public key to all servers?"; then
    echo ""
    print_warn "Skipping connectivity check."
    print_info "Run this script again after uploading the key."
    echo ""
    exit 0
fi

print_header "STEP 5: Verifying SSH connectivity"

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
    print_error "One or more servers are unreachable."
    print_info  "Verify the public key was uploaded correctly and the server is online."
    exit 1
fi

print_header "STEP 6: Verifying git authentication"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.."; pwd)"

if git -C "${REPO_ROOT}" push --dry-run origin HEAD &>/dev/null; then
    print_ok "Git push access confirmed"
else
    print_warn "Cannot push to git remote. Ansible will not be able to push SealedSecrets."
    echo ""
    echo -e "  Fix git auth using one of these options:"
    echo ""
    echo -e "  ${BOLD}Option A – GitHub Personal Access Token (recommended for HTTPS):${NC}"
    echo -e "    ${YELLOW}git remote set-url origin https://<YOUR_TOKEN>@github.com/msmolinski-labs/k8s-cluster-bootstrap.git${NC}"
    echo ""
    echo -e "  ${BOLD}Option B – SSH remote:${NC}"
    echo -e "    ${YELLOW}git remote set-url origin git@github.com:msmolinski-labs/k8s-cluster-bootstrap.git${NC}"
    echo -e "    # Ensure your SSH key is added to GitHub"
    echo ""
    echo -e "  ${BOLD}Option C – Git credential store (HTTPS):${NC}"
    echo -e "    ${YELLOW}git config --global credential.helper store${NC}"
    echo -e "    # Then do one manual push and enter your token when prompted"
    echo ""
    if ! confirm "Continue anyway (git push will fail during bootstrap)?" ; then
        echo ""
        print_warn "Fix git auth and run setup-local.sh again."
        exit 1
    fi
fi

print_header "Setup complete"

echo -e "  ${GREEN}${BOLD}Local environment is ready.${NC}"
echo ""
echo -e "  Next step:"
echo -e "    ${YELLOW}./scripts/bootstrap.sh${NC}"
echo ""
