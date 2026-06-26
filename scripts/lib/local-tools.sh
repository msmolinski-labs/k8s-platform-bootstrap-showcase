#!/usr/bin/env bash

tool_log_ok() {
    if declare -F print_ok >/dev/null; then
        print_ok "$1"
    else
        echo "$1"
    fi
}

tool_log_info() {
    if declare -F print_info >/dev/null; then
        print_info "$1"
    else
        echo "$1"
    fi
}

tool_log_error() {
    if declare -F print_error >/dev/null; then
        print_error "$1"
    else
        echo "$1" >&2
    fi
}

ensure_local_bin_paths() {
    export PATH="$PATH:$HOME/.local/bin:$HOME"
}

ensure_python_yaml_runtime() {
    if ! command -v python3 &>/dev/null; then
        tool_log_info "Installing python3 and python3-yaml..."
        sudo apt-get update -qq
        sudo apt-get install -y python3 python3-yaml -qq
        return 0
    fi

    if ! python3 -c "import yaml" &>/dev/null; then
        tool_log_info "Installing python3-yaml..."
        sudo apt-get install -y python3-yaml -qq
    fi
}

tool_check_cmd() {
    case "$1" in
        git) echo "command -v git" ;;
        ansible) echo "command -v ansible && command -v ansible-playbook" ;;
        kubectl) echo "command -v kubectl" ;;
        helm) echo "command -v helm" ;;
        cilium) echo "command -v cilium" ;;
        kubeseal) echo "command -v kubeseal" ;;
        yq) echo "command -v yq || test -f \"$HOME/yq\"" ;;
        sops) echo "command -v sops" ;;
        age) echo "command -v age-keygen" ;;
        python3) echo "command -v python3 && python3 -c \"import yaml\"" ;;
        *) return 1 ;;
    esac
}

install_git() {
    sudo apt-get update -qq
    sudo apt-get install -y git curl wget tar -qq
}

install_ansible() {
    sudo apt-get update -qq
    sudo apt-get install -y python3 python3-pip pipx -qq
    pipx install --include-deps ansible
    pipx ensurepath
    ensure_local_bin_paths
}

install_kubectl() {
    local version
    sudo apt-get update -qq
    sudo apt-get install -y curl ca-certificates -qq
    version=$(curl -fsSL --retry 3 --connect-timeout 10 https://dl.k8s.io/release/stable.txt)
    curl -fsSLO --retry 3 --connect-timeout 10 "https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
    sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
    rm -f kubectl
}

install_helm() {
    sudo apt-get update -qq
    sudo apt-get install -y curl ca-certificates -qq
    curl -fsSL --retry 3 --connect-timeout 10 \
        https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash &>/dev/null
}

install_cilium_cli() {
    local version
    sudo apt-get update -qq
    sudo apt-get install -y curl tar -qq
    version=$(curl -fsSL --retry 3 --connect-timeout 10 \
        https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    curl -fsSL --retry 3 --connect-timeout 10 --remote-name-all \
        "https://github.com/cilium/cilium-cli/releases/download/${version}/cilium-linux-amd64.tar.gz"
    tar -xzf cilium-linux-amd64.tar.gz
    sudo mv cilium /usr/local/bin/
    rm -f cilium-linux-amd64.tar.gz
}

install_kubeseal() {
    local version
    sudo apt-get update -qq
    sudo apt-get install -y curl tar -qq
    version=$(curl -fsSL --retry 3 --connect-timeout 10 \
        https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
        | grep tag_name | cut -d '"' -f 4 | sed 's/v//')
    curl -fsSLO --retry 3 --connect-timeout 10 \
        "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${version}/kubeseal-${version}-linux-amd64.tar.gz"
    tar -xzf "kubeseal-${version}-linux-amd64.tar.gz" kubeseal
    sudo install -m 755 kubeseal /usr/local/bin/kubeseal
    rm -f "kubeseal-${version}-linux-amd64.tar.gz" kubeseal
}

install_yq() {
    sudo apt-get update -qq
    sudo apt-get install -y wget -qq
    wget -qO ~/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    chmod +x ~/yq
    if ! grep -q 'export PATH=.*HOME' ~/.bashrc 2>/dev/null; then
        echo 'export PATH="$HOME:$PATH"' >> ~/.bashrc
    fi
    ensure_local_bin_paths
}

install_sops() {
    local version
    sudo apt-get update -qq
    sudo apt-get install -y curl -qq
    version=$(curl -fsSL --retry 3 --connect-timeout 10 https://api.github.com/repos/getsops/sops/releases/latest \
        | grep '"tag_name"' | head -n 1 | cut -d '"' -f 4)
    curl -fsSLo /tmp/sops.deb --retry 3 --connect-timeout 10 \
        "https://github.com/getsops/sops/releases/download/${version}/sops_${version#v}_amd64.deb"
    sudo dpkg -i /tmp/sops.deb >/dev/null
    rm -f /tmp/sops.deb
}

install_age() {
    local version
    sudo apt-get update -qq
    sudo apt-get install -y curl tar -qq
    version=$(curl -fsSL --retry 3 --connect-timeout 10 https://api.github.com/repos/FiloSottile/age/releases/latest \
        | grep '"tag_name"' | head -n 1 | cut -d '"' -f 4)
    curl -fsSLo /tmp/age.tar.gz --retry 3 --connect-timeout 10 \
        "https://github.com/FiloSottile/age/releases/download/${version}/age-${version}-linux-amd64.tar.gz"
    tar -xzf /tmp/age.tar.gz -C /tmp
    sudo install -m 755 /tmp/age/age /usr/local/bin/age
    sudo install -m 755 /tmp/age/age-keygen /usr/local/bin/age-keygen
    rm -rf /tmp/age.tar.gz /tmp/age
}

install_named_tool() {
    case "$1" in
        git) install_git ;;
        ansible) install_ansible ;;
        kubectl) install_kubectl ;;
        helm) install_helm ;;
        cilium) install_cilium_cli ;;
        kubeseal) install_kubeseal ;;
        yq) install_yq ;;
        sops) install_sops ;;
        age) install_age ;;
        python3) ensure_python_yaml_runtime ;;
        *) tool_log_error "Unsupported tool install request: $1"; return 1 ;;
    esac
}

ensure_named_tools() {
    local tool check_cmd
    local failed=()

    ensure_local_bin_paths

    for tool in "$@"; do
        check_cmd=$(tool_check_cmd "$tool") || {
            failed+=("$tool")
            continue
        }

        if eval "$check_cmd" &>/dev/null; then
            tool_log_ok "$tool"
            continue
        fi

        tool_log_info "Installing $tool..."
        if install_named_tool "$tool" && eval "$check_cmd" &>/dev/null; then
            tool_log_ok "$tool"
        else
            tool_log_error "$tool – installation failed"
            failed+=("$tool")
        fi
    done

    if [[ ${#failed[@]} -gt 0 ]]; then
        tool_log_error "Missing tools after auto-prepare: ${failed[*]}"
        return 1
    fi
}