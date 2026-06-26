#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${REPO_ROOT}/logs"
BOOTSTRAP_ENV_FILE="${BOOTSTRAP_ENV_FILE:-${REPO_ROOT}/.env.bootstrap.local}"

mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/bootstrap-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "Bootstrap started at $(date)"
echo "Log: ${LOG_FILE}"

ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/prod/hosts.yml"

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
# shellcheck source=./scripts/lib/local-tools.sh
source "${SCRIPT_DIR}/lib/local-tools.sh"

INVENTORY_DIR="$(dirname "${INVENTORY}")"
SECRETS_FILE="${INVENTORY_DIR}/group_vars/all/secrets.sops.yaml"
SOPS_HELPER="${REPO_ROOT}/scripts/sops_secrets.py"
LEGACY_VAULT_FILE="${INVENTORY_DIR}/group_vars/all/vault.yml"

_INV_NAME="$(basename "${INVENTORY_DIR}")"
PASSWORDS_FILE="${REPO_ROOT}/passwords-${_INV_NAME}-temp.txt"
SOPS_AGE_RECIPIENTS_VALUE=""
RUNTIME_SECRETS_FILE=""
POST_BOOTSTRAP_KUBECONFIG=""

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

cleanup() {
    [[ -n "${RUNTIME_SECRETS_FILE}" && -f "${RUNTIME_SECRETS_FILE}" ]] && rm -f "${RUNTIME_SECRETS_FILE}"
}

trap cleanup EXIT

load_bootstrap_env_file() {
    local env_file="$1"
    local line key value

    [[ -f "$env_file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" == *=* ]] || continue

        key="${line%%=*}"
        value="${line#*=}"

        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        if [[ "$value" =~ ^\".*\"$ || "$value" =~ ^\'.*\'$ ]]; then
            value="${value:1:-1}"
        fi

        if [[ -z "${!key:-}" ]]; then
            export "$key=$value"
        fi
    done < "$env_file"

    print_info "Loaded local bootstrap inputs from ${env_file}"
}

read_existing_secret() {
    local secret_key="$1"

    if [[ ! -f "${SECRETS_FILE}" ]]; then
        echo ""
        return 0
    fi

    python3 "${SOPS_HELPER}" get --file "${SECRETS_FILE}" --key "${secret_key}"
}

read_existing_sops_recipients() {
    [[ -f "${SECRETS_FILE}" ]] || return 0

    python3 - "${SECRETS_FILE}" <<'PYEOF'
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    data = yaml.safe_load(handle) or {}

age_entries = ((data.get("sops") or {}).get("age") or [])
recipients = [entry.get("recipient", "") for entry in age_entries if entry.get("recipient")]
print(",".join(recipients))
PYEOF
}

read_age_public_key_from_keys_file() {
    local keys_file="$1"

    [[ -f "${keys_file}" ]] || return 0
    grep '^# public key:' "${keys_file}" | awk '{print $NF}' | head -n 1
}

ensure_bootstrap_env_value() {
    local env_file="$1"
    local key="$2"
    local value="$3"

    [[ -n "${value}" ]] || return 0

    if [[ -f "${env_file}" ]] && grep -q "^${key}=" "${env_file}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${env_file}"
        return 0
    fi

    if [[ -f "${env_file}" ]] && [[ -n "$(tail -c 1 "${env_file}" 2>/dev/null)" ]]; then
        printf '\n' >> "${env_file}"
    fi

    printf '%s=%s\n' "${key}" "${value}" >> "${env_file}"
}

rename_kubeconfig_for_env() {
    local source_file="$1"
    local output_file="$2"
    local env_name="$3"
    local yq_bin

    yq_bin=$(command -v yq 2>/dev/null || echo ~/yq)
    "$yq_bin" e ".clusters[0].name = \"${env_name}\" |
        .contexts[0].name = \"${env_name}\" |
        .contexts[0].context.cluster = \"${env_name}\" |
        .contexts[0].context.user = \"${env_name}-admin\" |
        .users[0].name = \"${env_name}-admin\" |
        .current-context = \"${env_name}\"" \
        "$source_file" > "$output_file"
}

merge_named_kubeconfig() {
    local named_file="$1"
    local env_name="$2"
    local existing_file="$3"

    mkdir -p "${HOME}/.kube"
    [[ -f "${HOME}/.kube/config" ]] && cp "${HOME}/.kube/config" "${HOME}/.kube/config.bak"

    if [[ -f "${HOME}/.kube/config" ]]; then
        cp "${HOME}/.kube/config" "$existing_file"

        KUBECONFIG="$existing_file" kubectl config delete-context "$env_name" 2>/dev/null || true
        KUBECONFIG="$existing_file" kubectl config delete-cluster "$env_name" 2>/dev/null || true
        KUBECONFIG="$existing_file" kubectl config delete-user "${env_name}-admin" 2>/dev/null || true
        KUBECONFIG="$existing_file" kubectl config delete-context kubernetes-admin@kubernetes 2>/dev/null || true
        KUBECONFIG="$existing_file" kubectl config delete-cluster kubernetes 2>/dev/null || true
        KUBECONFIG="$existing_file" kubectl config delete-user kubernetes-admin 2>/dev/null || true

        KUBECONFIG="${existing_file}:${named_file}" kubectl config view --flatten > "${HOME}/.kube/config.merged"
        mv "${HOME}/.kube/config.merged" "${HOME}/.kube/config"
    else
        cp "$named_file" "${HOME}/.kube/config"
    fi

    chmod 600 "${HOME}/.kube/config"
    POST_BOOTSTRAP_KUBECONFIG="${HOME}/.kube/config"
    export KUBECONFIG="${HOME}/.kube/config"
    kubectl config delete-context kubernetes-admin@kubernetes 2>/dev/null || true
    kubectl config delete-cluster kubernetes 2>/dev/null || true
    kubectl config delete-user kubernetes-admin 2>/dev/null || true
    kubectl config use-context "$env_name" 2>/dev/null || true

    print_ok "kubeconfig merged – context: ${env_name}"
    print_ok "Switch clusters: kubectl config use-context dev|prod"
}

export_named_kubeconfig() {
    local named_file="$1"
    local export_path="$2"
    local env_name="$3"

    mkdir -p "$(dirname "$export_path")"
    cp "$named_file" "$export_path"
    chmod 600 "$export_path"
    POST_BOOTSTRAP_KUBECONFIG="$export_path"
    export KUBECONFIG="$export_path"

    print_ok "kubeconfig exported – context: ${env_name}"
    print_info "Exported kubeconfig: ${export_path}"
    print_info "Use with kubectl: KUBECONFIG=${export_path} kubectl get nodes"
}

use_post_bootstrap_kubeconfig() {
    if [[ -n "${POST_BOOTSTRAP_KUBECONFIG}" ]]; then
        KUBECONFIG="${POST_BOOTSTRAP_KUBECONFIG}" kubectl "$@"
    else
        kubectl "$@"
    fi
}

handle_post_bootstrap_kubeconfig() {
    local env_name="$1"
    local inventory_file="$2"
    local export_path_default="${HOME}/.kube/${env_name}.yaml"
    local kubeconfig_mode="${BOOTSTRAP_KUBECONFIG_MODE:-export}"
    local export_path="${BOOTSTRAP_KUBECONFIG_EXPORT_PATH:-${export_path_default}}"
    local kubeconfig_tmp="${HOME}/.kube/config-${env_name}-new"
    local kubeconfig_named="${kubeconfig_tmp}-named"
    local kubeconfig_existing="${HOME}/.kube/config-${env_name}-existing"
    local control_plane_ip

    case "$kubeconfig_mode" in
        merge|export|skip)
            ;;
        *)
            print_error "Unsupported BOOTSTRAP_KUBECONFIG_MODE: ${kubeconfig_mode}"
            print_info "Supported values: merge, export, skip"
            return 1
            ;;
    esac

    if [[ "$kubeconfig_mode" == "skip" ]]; then
        print_info "Skipping kubeconfig handling (BOOTSTRAP_KUBECONFIG_MODE=skip)"
        return 0
    fi

    control_plane_ip=$(python3 - "$inventory_file" <<'PYEOF'
import yaml, sys
with open(sys.argv[1], encoding='utf-8') as handle:
    inv = yaml.safe_load(handle)
cp = inv['all']['children']['control_plane']['hosts']
print(list(cp.values())[0]['ansible_host'])
PYEOF
)

    if [[ -z "$control_plane_ip" ]]; then
        print_warn "Could not determine control-plane IP – kubeconfig handling skipped"
        return 0
    fi

    mkdir -p "${HOME}/.kube"

    if ! scp -q -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
        "${ANSIBLE_USER}@${control_plane_ip}:/etc/kubernetes/admin.conf" \
        "$kubeconfig_tmp" 2>/dev/null; then
        print_warn "Could not fetch kubeconfig from ${control_plane_ip} – kubeconfig handling skipped"
        return 0
    fi

    rename_kubeconfig_for_env "$kubeconfig_tmp" "$kubeconfig_named" "$env_name"

    case "$kubeconfig_mode" in
        merge)
            merge_named_kubeconfig "$kubeconfig_named" "$env_name" "$kubeconfig_existing"
            ;;
        export)
            export_named_kubeconfig "$kubeconfig_named" "$export_path" "$env_name"
            ;;
    esac

    rm -f "$kubeconfig_tmp" "$kubeconfig_named" "$kubeconfig_existing"
}

is_contaminated_secret_value() {
    local value="$1"

    [[ "$value" == *$'\n'* ]] && return 0
    [[ "$value" == *$'\r'* ]] && return 0
    [[ "$value" == *$'\033'* ]] && return 0
    [[ "$value" == *"loaded from bootstrap environment"* ]] && return 0
    [[ "$value" == *"reused from"* ]] && return 0
    [[ "$value" == *"generated automatically"* ]] && return 0
    return 1
}

sanitize_existing_secret_value() {
    local secret_name="$1"
    local value="$2"

    if [[ -z "$value" ]]; then
        echo ""
        return 0
    fi

    if is_contaminated_secret_value "$value"; then
        print_warn "Ignoring contaminated existing value for ${secret_name}; bootstrap will write a fresh one." >&2
        echo ""
        return 0
    fi

    echo "$value"
}

get_or_prompt_password() {
    local prompt="$1"
    local existing_value="$2"
    local explicit_value="${3:-}"

    if [[ -n "${explicit_value}" ]]; then
        print_ok "${prompt} loaded from bootstrap environment" >&2
        echo "${explicit_value}"
        return 0
    fi

    if [[ -n "${existing_value}" ]]; then
        print_ok "${prompt} reused from ${SECRETS_FILE}" >&2
        echo "${existing_value}"
        return 0
    fi

    local generated_value
    generated_value="$(gen_password)"
    print_info "${prompt} generated automatically" >&2
    echo "${generated_value}"
}

expected_branch_for_env() {
    local env_name="$1"
    if [[ "$env_name" == "prod" ]]; then
        echo "main"
    else
        echo "$env_name"
    fi
}

gen_password() {
    set +o pipefail
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
    set -o pipefail
}

case "${_INV_NAME}" in
    dev|prod)
        ;;
    *)
        print_error "Unsupported cluster inventory: ${INVENTORY}"
        print_info "Use ansible/inventory/dev/hosts.yml or ansible/inventory/prod/hosts.yml"
        print_info "For load balancer use ./scripts/setup-lb.sh with ansible/inventory/lb-dev/hosts.yml or ansible/inventory/lb-prod/hosts.yml"
        exit 1
        ;;
esac

if [[ -f "${LEGACY_VAULT_FILE}" ]]; then
    print_error "Legacy ansible-vault file detected: ${LEGACY_VAULT_FILE}"
    print_info "Ansible auto-loads group_vars/all/vault.yml and will try to decrypt it during bootstrap."
    print_info "This repository now uses group_vars/all/secrets.sops.yaml instead."
    print_info "After confirming any needed values were migrated, rename or remove the legacy file and retry."
    print_info "Example: mv ${LEGACY_VAULT_FILE} ${LEGACY_VAULT_FILE}.legacy"
    exit 1
fi

load_bootstrap_env_file "${BOOTSTRAP_ENV_FILE}"
SOPS_AGE_RECIPIENTS_VALUE="${SOPS_AGE_RECIPIENTS:-${BOOTSTRAP_SOPS_AGE_RECIPIENTS:-}}"
if [[ -z "${SOPS_AGE_RECIPIENTS_VALUE}" ]]; then
    SOPS_AGE_RECIPIENTS_VALUE="$(read_existing_sops_recipients)"
fi

print_header "STEP 1: Preparing local tools"

if ! ensure_named_tools python3 git ansible kubectl helm cilium kubeseal sops age; then
    echo ""
    print_error "Bootstrap cannot continue without the required local tools."
    print_info "If auto-install failed, inspect sudo/network access and retry."
    exit 1
fi


AGE_KEYS_FILE="${HOME}/.config/sops/age/keys.txt"

if [[ ! -f "${AGE_KEYS_FILE}" ]] || ! grep -q "^AGE-SECRET-KEY" "${AGE_KEYS_FILE}" 2>/dev/null; then
    print_info "No age private key found at ${AGE_KEYS_FILE}. Generating one now..."
    mkdir -p "$(dirname "${AGE_KEYS_FILE}")"
    chmod 700 "$(dirname "${AGE_KEYS_FILE}")"
    age-keygen -o "${AGE_KEYS_FILE}" 2>/dev/null
    chmod 600 "${AGE_KEYS_FILE}"
    _GENERATED_AGE_PUBKEY="$(read_age_public_key_from_keys_file "${AGE_KEYS_FILE}")"
    print_ok "Generated new age key. Public key: ${_GENERATED_AGE_PUBKEY}"
else
    print_ok "age private key found at ${AGE_KEYS_FILE}"
fi

if [[ -z "${SOPS_AGE_RECIPIENTS_VALUE}" ]]; then
    SOPS_AGE_RECIPIENTS_VALUE="$(read_age_public_key_from_keys_file "${AGE_KEYS_FILE}")"
fi

if [[ -n "${SOPS_AGE_RECIPIENTS_VALUE}" ]]; then
    ensure_bootstrap_env_value "${BOOTSTRAP_ENV_FILE}" "BOOTSTRAP_SOPS_AGE_RECIPIENTS" "${SOPS_AGE_RECIPIENTS_VALUE}"
    load_bootstrap_env_file "${BOOTSTRAP_ENV_FILE}"
    SOPS_AGE_RECIPIENTS_VALUE="${SOPS_AGE_RECIPIENTS:-${BOOTSTRAP_SOPS_AGE_RECIPIENTS:-${SOPS_AGE_RECIPIENTS_VALUE}}}"
    print_ok "age recipient resolved for SOPS"
fi

print_header "STEP 1.5: Verifying environment mapping"

CURRENT_BRANCH="$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD)"
EXPECTED_BRANCH="$(expected_branch_for_env "${_INV_NAME}")"

if [[ "${CURRENT_BRANCH}" == "HEAD" ]]; then
    print_error "Detached HEAD detected. Bootstrap must run from a named branch."
    print_info "Expected branch for ${_INV_NAME}: ${EXPECTED_BRANCH}"
    exit 1
fi

if [[ "${CURRENT_BRANCH}" != "${EXPECTED_BRANCH}" ]]; then
    print_error "Inventory/branch mismatch detected."
    print_info "Inventory selects environment: ${_INV_NAME}"
    print_info "Current git branch: ${CURRENT_BRANCH}"
    print_info "Expected git branch: ${EXPECTED_BRANCH}"
    print_info "Switch branch first so generated SealedSecrets and ArgoCD sync target the same environment."
    exit 1
fi

print_ok "Environment mapping confirmed: ${_INV_NAME} -> ${CURRENT_BRANCH}"

print_header "STEP 2: Verifying git push access"

if git -C "${REPO_ROOT}" push --dry-run origin HEAD &>/dev/null; then
    print_ok "Git push access confirmed"
else
    print_warn "Cannot push to git remote."
    print_error "Bootstrap stops here because Phase 11 pushes SealedSecrets to git."
    print_info "Fix git auth and re-run bootstrap.sh."
    print_info "Option A (HTTPS): git remote set-url origin https://<YOUR_TOKEN>@github.com/msmolinski-labs/k8s-cluster-bootstrap.git"
    print_info "Option B (SSH):   git remote set-url origin git@github.com:msmolinski-labs/k8s-cluster-bootstrap.git"
    exit 1
fi

print_header "STEP 3: Verifying SSH connectivity"

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
    print_error "One or more servers are unreachable."
    print_info  "Run ./scripts/setup-local.sh to re-check SSH keys and connectivity."
    exit 1
fi

print_header "STEP 4: Passwords"

EXISTING_MINIO_ROOT_PASSWORD="$(sanitize_existing_secret_value "MinIO root password" "$(read_existing_secret vault_minio_root_password)")"
EXISTING_MINIO_LOKI_SECRET_KEY="$(sanitize_existing_secret_value "Loki MinIO secret key" "$(read_existing_secret vault_minio_loki_secret_key)")"
EXISTING_GRAFANA_ADMIN_PASSWORD="$(sanitize_existing_secret_value "Grafana admin password" "$(read_existing_secret vault_grafana_admin_password)")"
EXISTING_ALERTMANAGER_SLACK_WEBHOOK="$(read_existing_secret vault_alertmanager_slack_webhook)"
EXISTING_GITHUB_TOKEN="$(read_existing_secret vault_github_token)"

MINIO_ROOT_USER="minioadmin"
MINIO_ROOT_PASSWORD=$(get_or_prompt_password "MinIO root password" "${EXISTING_MINIO_ROOT_PASSWORD}" "${BOOTSTRAP_MINIO_ROOT_PASSWORD:-}")
MINIO_LOKI_SECRET_KEY=$(get_or_prompt_password "Loki MinIO secret key" "${EXISTING_MINIO_LOKI_SECRET_KEY}" "${BOOTSTRAP_MINIO_LOKI_SECRET_KEY:-}")
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASSWORD=$(get_or_prompt_password "Grafana admin password" "${EXISTING_GRAFANA_ADMIN_PASSWORD}" "${BOOTSTRAP_GRAFANA_ADMIN_PASSWORD:-}")

print_header "STEP 5: External credentials"

ALERTMANAGER_SLACK_WEBHOOK="${BOOTSTRAP_SLACK_WEBHOOK:-${EXISTING_ALERTMANAGER_SLACK_WEBHOOK}}"
if [[ -n "$ALERTMANAGER_SLACK_WEBHOOK" ]]; then
    print_ok "Slack webhook resolved without prompt"
else
    ALERTMANAGER_SLACK_WEBHOOK="https://hooks.slack.com/services/DUMMY/DUMMY/DUMMY"
    print_warn "Slack webhook not provided. Using dummy placeholder in ${SECRETS_FILE}."
fi

GITHUB_TOKEN="${BOOTSTRAP_GITHUB_TOKEN:-${EXISTING_GITHUB_TOKEN}}"
if [[ -n "$GITHUB_TOKEN" ]]; then
    print_ok "GitHub token resolved without prompt"
else
    GITHUB_TOKEN=""
    print_warn "GitHub token not provided. ArgoCD repo registration will be skipped until you add it to ${SECRETS_FILE}."
fi

echo ""
if [[ "$ALERTMANAGER_SLACK_WEBHOOK" == *"DUMMY"* ]]; then
    print_warn "Dummy values used. Alertmanager will not send notifications until you update ${SECRETS_FILE}"
fi

if [[ -z "$GITHUB_TOKEN" ]]; then
    print_warn "No GitHub token provided. ArgoCD will not be able to sync from private repo."
fi

if [[ -z "${SOPS_AGE_RECIPIENTS_VALUE}" ]]; then
    print_error "Missing age recipients for SOPS encryption."
    print_info "Set BOOTSTRAP_SOPS_AGE_RECIPIENTS in ${BOOTSTRAP_ENV_FILE} or export SOPS_AGE_RECIPIENTS before running bootstrap.sh."
    print_info "If ${SECRETS_FILE} already exists, verify it still contains SOPS recipient metadata."
    exit 1
fi

print_header "STEP 6: Writing SOPS secrets"

python3 "${SOPS_HELPER}" upsert \
    --file "${SECRETS_FILE}" \
    --age-recipients "${SOPS_AGE_RECIPIENTS_VALUE}" \
    --set "vault_minio_root_user=${MINIO_ROOT_USER}" \
    --set "vault_minio_root_password=${MINIO_ROOT_PASSWORD}" \
    --set "vault_minio_loki_secret_key=${MINIO_LOKI_SECRET_KEY}" \
    --set "vault_grafana_admin_user=${GRAFANA_ADMIN_USER}" \
    --set "vault_grafana_admin_password=${GRAFANA_ADMIN_PASSWORD}" \
    --set "vault_alertmanager_slack_webhook=${ALERTMANAGER_SLACK_WEBHOOK}" \
    --set "vault_github_token=${GITHUB_TOKEN}"
print_ok "secrets.sops.yaml updated: ${SECRETS_FILE}"

cat > "$PASSWORDS_FILE" <<EOF

MinIO root user:          ${MINIO_ROOT_USER}
MinIO root password:      ${MINIO_ROOT_PASSWORD}

Loki MinIO user:          loki  (fixed)
Loki MinIO secret key:    ${MINIO_LOKI_SECRET_KEY}

Grafana admin user:       ${GRAFANA_ADMIN_USER}
Grafana admin password:   ${GRAFANA_ADMIN_PASSWORD}

Alertmanager Slack:       ${ALERTMANAGER_SLACK_WEBHOOK}

SOPS secrets file:        ${SECRETS_FILE}
EOF
chmod 600 "$PASSWORDS_FILE"

echo ""
echo -e "${BOLD}  ╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}  ║         GENERATED PASSWORDS – SAVE THESE NOW        ║${NC}"
echo -e "${BOLD}  ╚══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  MinIO root password:    ${YELLOW}${MINIO_ROOT_PASSWORD}${NC}"
echo -e "  Loki secret key:        ${YELLOW}${MINIO_LOKI_SECRET_KEY}${NC}"
echo -e "  Grafana admin password: ${YELLOW}${GRAFANA_ADMIN_PASSWORD}${NC}"
echo ""
echo -e "  Full list saved to: ${YELLOW}${PASSWORDS_FILE}${NC}"
echo -e "  ${RED}Delete that file after saving passwords to a password manager.${NC}"
echo ""

print_header "STEP 7: Starting Ansible bootstrap"

echo -e "  Inventory: ${INVENTORY}"
echo -e "  Playbook:  ${ANSIBLE_DIR}/site.yml"
echo ""

cd "${REPO_ROOT}"
RUNTIME_SECRETS_FILE="$(mktemp)"
chmod 600 "${RUNTIME_SECRETS_FILE}"
sops --decrypt "${SECRETS_FILE}" > "${RUNTIME_SECRETS_FILE}"

ansible-playbook \
    -i "${INVENTORY}" \
    "${ANSIBLE_DIR}/site.yml" \
    -e "env_name=${_INV_NAME}" \
    -e "@${RUNTIME_SECRETS_FILE}"

print_header "Handling kubeconfig"

_ENV_NAME="$(basename "${INVENTORY_DIR}")"
handle_post_bootstrap_kubeconfig "${_ENV_NAME}" "${INVENTORY}"

print_header "Bootstrap complete"

ARGOCD_PASSWORD=""
for _i in $(seq 1 6); do
    _pass=$(use_post_bootstrap_kubeconfig -n argocd get secret argocd-initial-admin-secret \
        -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null)
    if [[ -n "$_pass" ]]; then
        ARGOCD_PASSWORD="$_pass"
        break
    fi
    sleep 5
done
[[ -z "$ARGOCD_PASSWORD" ]] && ARGOCD_PASSWORD="(not found – run: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"

_MINIO_IP=$(python3 - "${INVENTORY}" <<'PYEOF'
import yaml, sys
with open(sys.argv[1]) as f:
    inv = yaml.safe_load(f)
st = inv['all']['children'].get('storage_nodes', {}).get('hosts', {})
print(list(st.values())[0]['ansible_host'] if st else '')
PYEOF
)
{
    echo ""
    echo "ArgoCD admin user:        admin"
    echo "ArgoCD admin password:    ${ARGOCD_PASSWORD}"
    echo ""
    echo "MinIO endpoint:           http://${_MINIO_IP}:9000"
    echo "MinIO Console:            http://${_MINIO_IP}:9001  (SSH tunnel only)"
    echo "MinIO root user:          ${MINIO_ROOT_USER}"
    echo "MinIO root password:      ${MINIO_ROOT_PASSWORD}"
} >> "${PASSWORDS_FILE}"

echo -e "  ${GREEN}${BOLD}Ansible bootstrap finished.${NC}"
echo -e "  ArgoCD is syncing applications – verify status below before use."
echo ""

_KUBECTL_HINT_PREFIX=""
if [[ -n "${POST_BOOTSTRAP_KUBECONFIG}" && "${POST_BOOTSTRAP_KUBECONFIG}" != "${HOME}/.kube/config" ]]; then
    _KUBECTL_HINT_PREFIX="KUBECONFIG=${POST_BOOTSTRAP_KUBECONFIG} "
fi

echo -e "  Check cluster status:"
echo -e "    ${YELLOW}${_KUBECTL_HINT_PREFIX}kubectl get nodes${NC}"
echo -e "    ${YELLOW}${_KUBECTL_HINT_PREFIX}kubectl get applications -n argocd${NC}"
echo -e "    ${YELLOW}${_KUBECTL_HINT_PREFIX}kubectl get pods -n monitoring${NC}"
echo ""
_BASE_DOMAIN=$(python3 -c "
import yaml
with open('${INVENTORY_DIR}/group_vars/all/vars.yml') as f:
    v = yaml.safe_load(f)
print(v.get('base_domain', 'klexify.io'))
" 2>/dev/null || echo 'klexify.io')

echo -e "  ArgoCD:"
echo -e "    ${YELLOW}${_KUBECTL_HINT_PREFIX}kubectl port-forward svc/argocd-server -n argocd 8080:443${NC}"
echo -e "    https://argocd.${_BASE_DOMAIN}"
echo -e "    User: ${YELLOW}admin${NC}  Password: ${YELLOW}${ARGOCD_PASSWORD}${NC}"
echo ""
echo -e "  Grafana:"
echo -e "    ${YELLOW}${_KUBECTL_HINT_PREFIX}kubectl port-forward svc/prometheus-stack-grafana -n monitoring 3000:80${NC}"
echo -e "    User: ${YELLOW}admin${NC}  Password: ${YELLOW}${GRAFANA_ADMIN_PASSWORD}${NC}"
echo ""
echo -e "  MinIO Console (SSH tunnel):"
echo -e "    ${YELLOW}ssh -L 9001:127.0.0.1:9001 root@${_MINIO_IP}${NC}"
echo -e "    ${YELLOW}http://localhost:9001${NC}"
echo -e "    User: ${YELLOW}${MINIO_ROOT_USER}${NC}  Password: ${YELLOW}${MINIO_ROOT_PASSWORD}${NC}"
echo ""

if [[ "$ALERTMANAGER_SLACK_WEBHOOK" == *"DUMMY"* ]]; then
    echo -e "  ${YELLOW}${BOLD}TODO – configure Alertmanager notifications:${NC}"
    echo -e "    sops edit ${SECRETS_FILE}"
    echo -e "    TMP_SECRETS_FILE=\$(mktemp)"
    echo -e "    sops --decrypt ${SECRETS_FILE} > \"\${TMP_SECRETS_FILE}\""
    echo -e "    ansible-playbook -i ${INVENTORY} ${ANSIBLE_DIR}/site.yml --tags seal_secrets -e \"env_name=${_INV_NAME}\" -e @\"\${TMP_SECRETS_FILE}\""
    echo -e "    rm -f \"\${TMP_SECRETS_FILE}\""
    echo ""
fi

echo -e "  ${RED}Remember to delete ${PASSWORDS_FILE} after saving passwords securely.${NC}"
echo ""
echo -e "  Kubeconfig:"
if [[ -n "${POST_BOOTSTRAP_KUBECONFIG}" ]]; then
    echo -e "    Active file: ${YELLOW}${POST_BOOTSTRAP_KUBECONFIG}${NC}"
    echo -e "    Repeat bootstrap for ${YELLOW}prod${NC} to get a separate kubeconfig file for that environment."
else
    echo -e "    No kubeconfig file was updated by this run."
fi
echo ""
echo -e "  Lens (Windows):"
if [[ -n "${POST_BOOTSTRAP_KUBECONFIG}" && "${POST_BOOTSTRAP_KUBECONFIG}" != "${HOME}/.kube/config" ]]; then
    echo -e "    Add the kubeconfig file shown above as a separate cluster source."
    echo -e "    Add ${YELLOW}dev.yaml${NC} and ${YELLOW}prod.yaml${NC} as separate cluster sources."
else
    echo -e "    Add kubeconfig folder: ${YELLOW}\\\\\\\\wsl\$\\\\Ubuntu\\\\home\\\\${USER}\\\\.kube${NC}"
fi
echo ""
