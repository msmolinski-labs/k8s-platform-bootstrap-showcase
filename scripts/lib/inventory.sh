#!/usr/bin/env bash

INVENTORY_FILE="${INVENTORY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/ansible/inventory/hosts.yml}"

inventory_load() {
    if [[ ! -f "$INVENTORY_FILE" ]]; then
        echo "ERROR: Inventory file not found: ${INVENTORY_FILE}"
        exit 1
    fi

    if ! python3 -c "import yaml" &>/dev/null; then
        echo "  Installing python3-yaml (required to parse inventory)..."
        sudo apt-get install -y python3-yaml -qq
    fi

    local parsed
    parsed=$(python3 - "$INVENTORY_FILE" <<'EOF'
import yaml, sys

with open(sys.argv[1]) as f:
    inv = yaml.safe_load(f)

all_vars = inv.get('all', {}).get('vars', {})
ssh_key = all_vars.get('ansible_ssh_private_key_file', '~/.ssh/id_rsa')
ansible_user = all_vars.get('ansible_user', 'root')

print(f"SSH_KEY={ssh_key}")
print(f"ANSIBLE_USER={ansible_user}")

children = inv.get('all', {}).get('children', {})
for group_name, group in children.items():
    hosts = group.get('hosts', {}) or {}
    for hostname, host_vars in hosts.items():
        ip = (host_vars or {}).get('ansible_host', '')
        if ip:
            print(f"HOST {hostname} {ip}")
EOF
)

    SSH_KEY=""
    ANSIBLE_USER=""
    declare -gA HOSTS=()

    while IFS= read -r line; do
        if [[ "$line" == SSH_KEY=* ]]; then
            SSH_KEY="${line#SSH_KEY=}"
            SSH_KEY="${SSH_KEY/#\~/$HOME}"
        elif [[ "$line" == ANSIBLE_USER=* ]]; then
            ANSIBLE_USER="${line#ANSIBLE_USER=}"
        elif [[ "$line" == HOST\ * ]]; then
            read -r _ alias ip <<< "$line"
            HOSTS["$alias"]="$ip"
        fi
    done <<< "$parsed"
}

inventory_print() {
    echo ""
    printf "  %-20s %s\n" "ALIAS" "IP"
    printf "  %-20s %s\n" "-----" "--"
    for alias in $(echo "${!HOSTS[@]}" | tr ' ' '\n' | sort); do
        printf "  %-20s %s\n" "$alias" "${HOSTS[$alias]}"
    done
    echo ""
    echo "  SSH key:  ${SSH_KEY}"
    echo "  User:     ${ANSIBLE_USER}"
    echo ""
}
