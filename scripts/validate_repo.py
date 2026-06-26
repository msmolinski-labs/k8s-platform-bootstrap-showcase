#!/usr/bin/env python3

from __future__ import annotations

import sys
from functools import lru_cache
from pathlib import Path
from typing import Any

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
EXPECTED_BOOTSTRAP_MANIFESTS_PATH = "/tmp/k8s-cluster-bootstrap/bootstrap/{{ env_name }}"
OBSOLETE_BOOTSTRAP_FILES = (
    "kubernetes/bootstrap/system-app.yaml",
    "kubernetes/bootstrap/infrastructure-app.yaml",
    "kubernetes/bootstrap/monitoring-app.yaml",
)
EXPECTED_DOMAINS = {
    "infrastructure": {"dev": "argocd.dev-klexify.cloud", "prod": "argocd.klexify.io"},
    "monitoring": {"dev": "grafana.dev-klexify.cloud", "prod": "grafana.klexify.io"},
}
TEXT_CHECKS = (
    (
        "scripts/bootstrap.sh",
        "expected_branch_for_env",
        "bootstrap.sh is missing expected_branch_for_env guard",
    ),
    (
        "scripts/bootstrap.sh",
        "Inventory/branch mismatch detected.",
        "bootstrap.sh is missing branch mismatch guard",
    ),
    (
        "scripts/bootstrap.sh",
        'BOOTSTRAP_KUBECONFIG_MODE:-export',
        "bootstrap.sh must default to kubeconfig export mode",
    ),
    (
        "scripts/bootstrap.sh",
        'local export_path_default="${HOME}/.kube/${env_name}.yaml"',
        "bootstrap.sh must default to per-environment kubeconfig files",
    ),
    (
        "scripts/bootstrap.sh",
        "handle_post_bootstrap_kubeconfig",
        "bootstrap.sh must centralize kubeconfig handling",
    ),
    (
        "scripts/bootstrap.sh",
        'LOG_DIR="${REPO_ROOT}/logs"',
        "bootstrap.sh must write logs into logs/",
    ),
    (
        "scripts/setup-lb.sh",
        'LOG_DIR="${REPO_ROOT}/logs"',
        "setup-lb.sh must write logs into logs/",
    ),
    (
        "scripts/teardown.sh",
        'LOG_DIR="${REPO_ROOT}/logs"',
        "teardown.sh must write logs into logs/",
    ),
    (
        "scripts/teardown-lb.sh",
        'LOG_DIR="${REPO_ROOT}/logs"',
        "teardown-lb.sh must write logs into logs/",
    ),
    (
        ".gitignore",
        "logs/*.log",
        ".gitignore must ignore logs/*.log",
    ),
)


class ValidationError(Exception):
    """Raised by require() when a structural validation check fails."""


_collected_errors: list[str] = []


def check(condition: bool, message: str) -> None:
    """Soft check: records the error and continues execution."""
    if not condition:
        _collected_errors.append(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


@lru_cache(maxsize=None)
def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing file: {path}") from exc
    except OSError as exc:
        raise SystemExit(f"Unable to read file {path}: {exc}") from exc


@lru_cache(maxsize=None)
def load_yaml(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return yaml.safe_load(handle) or {}
    except FileNotFoundError as exc:
        raise SystemExit(f"Missing YAML file: {path}") from exc
    except yaml.YAMLError as exc:
        raise SystemExit(f"Invalid YAML in {path}: {exc}") from exc
    except OSError as exc:
        raise SystemExit(f"Unable to read YAML file {path}: {exc}") from exc


def load_yaml_string(content: str, source: str) -> Any:
    try:
        return yaml.safe_load(content) or {}
    except yaml.YAMLError as exc:
        raise SystemExit(f"Invalid YAML in {source}: {exc}") from exc


def ensure_mapping(data: Any, path: Path, description: str) -> dict[str, Any]:
    require(isinstance(data, dict), f"Expected {description} in {path}, got {type(data).__name__}")
    return data


def ensure_sequence(data: Any, path: Path, description: str) -> list[Any]:
    require(isinstance(data, list), f"Expected {description} in {path}, got {type(data).__name__}")
    return data


def nested_get(mapping: dict[str, Any], *keys: str) -> Any:
    current: Any = mapping
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def inventory_children(inventory: dict[str, Any], path: Path) -> dict[str, Any]:
    all_group = ensure_mapping(inventory.get("all") or {}, path, "an all: mapping")
    children = all_group.get("children") or {}
    return ensure_mapping(children, path, "all.children mapping")


def collect_hosts_from_children(children: dict[str, Any], path: Path) -> dict[str, str]:
    hosts: dict[str, str] = {}
    for group_name, raw_group in children.items():
        group = ensure_mapping(raw_group or {}, path, f"group definition for {group_name}")

        group_hosts = group.get("hosts") or {}
        require(isinstance(group_hosts, dict), f"Expected hosts mapping for group {group_name} in {path}")
        for host_name, host_vars in group_hosts.items():
            host_mapping = ensure_mapping(host_vars or {}, path, f"host vars for {host_name}")
            ip_address = host_mapping.get("ansible_host")
            if isinstance(ip_address, str) and ip_address:
                hosts[host_name] = ip_address

        nested_children = group.get("children") or {}
        require(isinstance(nested_children, dict), f"Expected nested children mapping for group {group_name} in {path}")
        hosts.update(collect_hosts_from_children(nested_children, path))

    return hosts


def collect_inventory_hosts(inventory: dict[str, Any], path: Path) -> dict[str, str]:
    return collect_hosts_from_children(inventory_children(inventory, path), path)


def find_group(children: dict[str, Any], group_name: str, path: Path) -> dict[str, Any] | None:
    if group_name in children:
        return ensure_mapping(children[group_name] or {}, path, f"group definition for {group_name}")

    for nested_group_name, raw_group in children.items():
        group = ensure_mapping(raw_group or {}, path, f"group definition for {nested_group_name}")
        nested_children = group.get("children") or {}
        require(isinstance(nested_children, dict), f"Expected nested children mapping for group {nested_group_name} in {path}")
        found = find_group(nested_children, group_name, path)
        if found is not None:
            return found

    return None


def collect_group_hosts(inventory: dict[str, Any], path: Path, group_name: str) -> dict[str, str]:
    group = find_group(inventory_children(inventory, path), group_name, path)
    if group is None:
        return {}

    group_hosts = group.get("hosts") or {}
    require(isinstance(group_hosts, dict), f"Expected hosts mapping for group {group_name} in {path}")
    hosts: dict[str, str] = {}
    for host_name, host_vars in group_hosts.items():
        host_mapping = ensure_mapping(host_vars or {}, path, f"host vars for {host_name}")
        ip_address = host_mapping.get("ansible_host")
        if isinstance(ip_address, str) and ip_address:
            hosts[host_name] = ip_address
    return hosts


def load_playbook(path: Path) -> list[dict[str, Any]]:
    playbook = ensure_sequence(load_yaml(path), path, "playbook list")
    validated: list[dict[str, Any]] = []
    for index, play in enumerate(playbook, start=1):
        validated.append(ensure_mapping(play, path, f"play #{index}"))
    return validated


def collect_nested_tasks(raw_tasks: list[Any], path: Path, container_name: str) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    for index, task in enumerate(raw_tasks, start=1):
        validated_task = ensure_mapping(task, path, f"{container_name} task #{index}")
        tasks.append(validated_task)

        for nested_key in ("block", "rescue", "always"):
            nested_tasks = validated_task.get(nested_key) or []
            require(isinstance(nested_tasks, list), f"Expected {nested_key} task list in {path}")
            tasks.extend(collect_nested_tasks(nested_tasks, path, nested_key))

    return tasks


def iter_tasks(path: Path) -> list[dict[str, Any]]:
    tasks: list[dict[str, Any]] = []
    for play in load_playbook(path):
        raw_tasks = play.get("tasks") or []
        require(isinstance(raw_tasks, list), f"Expected tasks list in {path}")
        tasks.extend(collect_nested_tasks(raw_tasks, path, "play"))
    return tasks


def task_name_matches(actual_name: Any, expected_name: str) -> bool:
    if actual_name == expected_name:
        return True

    if not isinstance(actual_name, str):
        return False

    prefix_end = actual_name.find("] ")
    if actual_name.startswith("[") and prefix_end != -1:
        return actual_name[prefix_end + 2 :] == expected_name

    return False


def find_task(path: Path, task_name: str) -> dict[str, Any]:
    matches = [task for task in iter_tasks(path) if task_name_matches(task.get("name"), task_name)]
    require(matches, f"Missing task {task_name!r} in {path}")
    require(len(matches) == 1, f"Expected exactly one task named {task_name!r} in {path}, found {len(matches)}")
    return matches[0]


def require_text_checks() -> None:
    for relative_path, needle, message in TEXT_CHECKS:
        content = read_text(REPO_ROOT / relative_path)
        check(needle in content, message)


def validate_inventory_separation() -> None:
    inventory_paths = {
        "dev": REPO_ROOT / "ansible/inventory/dev/hosts.yml",
        "prod": REPO_ROOT / "ansible/inventory/prod/hosts.yml",
        "lb-dev": REPO_ROOT / "ansible/inventory/lb-dev/hosts.yml",
        "lb-prod": REPO_ROOT / "ansible/inventory/lb-prod/hosts.yml",
    }
    inventories = {name: ensure_mapping(load_yaml(path), path, "inventory mapping") for name, path in inventory_paths.items()}

    cluster_hosts = {
        name: collect_inventory_hosts(inventories[name], inventory_paths[name])
        for name in ("dev", "prod")
    }
    lb_hosts = {
        name: collect_inventory_hosts(inventories[name], inventory_paths[name])
        for name in ("lb-dev", "lb-prod")
    }
    lb_only_hosts = {
        name: collect_group_hosts(inventories[name], inventory_paths[name], "load_balancers")
        for name in ("lb-dev", "lb-prod")
    }

    dev_ips = set(cluster_hosts["dev"].values())
    prod_ips = set(cluster_hosts["prod"].values())
    require(not dev_ips & prod_ips, f"dev/prod inventories overlap on IPs: {sorted(dev_ips & prod_ips)}")

    require(lb_only_hosts["lb-dev"], "No load_balancers host found in lb-dev inventory")
    require(lb_only_hosts["lb-prod"], "No load_balancers host found in lb-prod inventory")

    lb_dev_ips = set(lb_hosts["lb-dev"].values())
    lb_prod_ips = set(lb_hosts["lb-prod"].values())
    require(not lb_dev_ips & prod_ips, f"lb-dev inventory contains prod IPs: {sorted(lb_dev_ips & prod_ips)}")
    require(not lb_prod_ips & dev_ips, f"lb-prod inventory contains dev IPs: {sorted(lb_prod_ips & dev_ips)}")

    lb_dev_only_ips = set(lb_only_hosts["lb-dev"].values())
    lb_prod_only_ips = set(lb_only_hosts["lb-prod"].values())
    require(
        not lb_dev_only_ips & lb_prod_only_ips,
        f"LB-only hosts overlap across environments: {sorted(lb_dev_only_ips & lb_prod_only_ips)}",
    )


def validate_inventory_vars() -> None:
    for env_name in ("dev", "prod"):
        path = REPO_ROOT / f"ansible/inventory/{env_name}/group_vars/all/vars.yml"
        vars_data = ensure_mapping(load_yaml(path), path, "group_vars mapping")
        require(
            vars_data.get("bootstrap_manifests_path") == EXPECTED_BOOTSTRAP_MANIFESTS_PATH,
            f"{env_name} inventory has invalid bootstrap_manifests_path",
        )


def validate_seal_playbook() -> None:
    path = REPO_ROOT / "ansible/playbooks/10-seal-secrets.yml"
    playbook = load_playbook(path)
    require(playbook, f"Playbook is empty: {path}")

    vars_mapping = ensure_mapping(playbook[0].get("vars") or {}, path, "vars mapping")
    require(
        vars_mapping.get("expected_git_branch") == "{{ 'main' if env_name_resolved == 'prod' else env_name_resolved }}",
        "10-seal-secrets.yml is missing expected_git_branch guard",
    )
    find_task(path, "[PRE-CHECK] Fail on inventory/branch mismatch")


def validate_bootstrap_playbooks() -> None:
    gitops_path = REPO_ROOT / "ansible/playbooks/09-bootstrap-gitops.yml"
    branch_task = find_task(gitops_path, "Set git branch per environment")
    require(
        nested_get(branch_task, "set_fact", "git_branch") == "{{ 'main' if env_name == 'prod' else env_name }}",
        "09-bootstrap-gitops.yml must derive git_branch from env_name",
    )

    temp_dir_task = find_task(gitops_path, "Ensure local bootstrap manifest temp directory exists")
    require(
        nested_get(temp_dir_task, "file", "path") == "{{ bootstrap_manifests_path }}",
        "09-bootstrap-gitops.yml must create the bootstrap temp directory",
    )

    system_app_task = find_task(gitops_path, "Generate system-app.yaml for {{ env_name }} (branch {{ git_branch }})")
    system_app_content = nested_get(system_app_task, "copy", "content")
    require(isinstance(system_app_content, str), f"Expected copy.content string in {gitops_path}")
    require(
        "targetRevision: {{ git_branch }}" in system_app_content,
        "09-bootstrap-gitops.yml must render targetRevision from git_branch",
    )

    monitoring_path = REPO_ROOT / "ansible/playbooks/11-apply-monitoring.yml"
    branch_task = find_task(monitoring_path, "Set git branch per environment")
    require(
        nested_get(branch_task, "set_fact", "git_branch") == "{{ 'main' if env_name == 'prod' else env_name }}",
        "11-apply-monitoring.yml must derive git_branch from env_name",
    )

    temp_dir_task = find_task(monitoring_path, "Ensure local bootstrap manifest temp directory exists")
    require(
        nested_get(temp_dir_task, "file", "path") == "{{ bootstrap_manifests_path }}",
        "11-apply-monitoring.yml must create the bootstrap temp directory",
    )

    infrastructure_app_task = find_task(monitoring_path, "Generate infrastructure-app.yaml for {{ env_name }}")
    infrastructure_content = nested_get(infrastructure_app_task, "copy", "content")
    require(isinstance(infrastructure_content, str), f"Expected copy.content string in {monitoring_path}")
    require(
        "targetRevision: {{ git_branch }}" in infrastructure_content,
        "11-apply-monitoring.yml must render targetRevision from git_branch",
    )
    require(
        "path: kubernetes/infrastructure/overlays/{{ env_name }}" in infrastructure_content,
        "11-apply-monitoring.yml must render infrastructure overlay from env_name",
    )

    monitoring_app_task = find_task(monitoring_path, "Generate monitoring-app.yaml for {{ env_name }}")
    monitoring_content = nested_get(monitoring_app_task, "copy", "content")
    require(isinstance(monitoring_content, str), f"Expected copy.content string in {monitoring_path}")
    require(
        "targetRevision: {{ git_branch }}" in monitoring_content,
        "11-apply-monitoring.yml must render targetRevision from git_branch",
    )
    require(
        "path: kubernetes/apps/monitoring/overlays/{{ env_name }}" in monitoring_content,
        "11-apply-monitoring.yml must render monitoring overlay from env_name",
    )


def validate_load_balancer_playbook() -> None:
    path = REPO_ROOT / "ansible/playbooks/12-setup-load-balancer.yml"
    http_ipv6_task = find_task(path, "Allow HTTP from Cloudflare IPv6 ranges (proxied)")
    https_ipv6_task = find_task(path, "Allow HTTPS from Cloudflare IPv6 ranges (proxied)")

    require(
        nested_get(http_ipv6_task, "ufw", "port") == "80",
        "12-setup-load-balancer.yml must allow Cloudflare IPv6 on port 80 when proxied",
    )
    require(
        nested_get(https_ipv6_task, "ufw", "port") == "443",
        "12-setup-load-balancer.yml must allow Cloudflare IPv6 on port 443 when proxied",
    )

    for task in (http_ipv6_task, https_ipv6_task):
        loop_values = task.get("loop") or []
        require(isinstance(loop_values, list), f"Expected loop list in {path}")
        require("2a06:98c0::/29" in loop_values, "12-setup-load-balancer.yml must include Cloudflare IPv6 ranges")


def validate_obsolete_bootstrap_files() -> None:
    for relative_path in OBSOLETE_BOOTSTRAP_FILES:
        check(not (REPO_ROOT / relative_path).exists(), f"Obsolete bootstrap snapshot still present: {relative_path}")


def validate_infrastructure_domain_patch(path: Path, expected_domain: str) -> None:
    patch = ensure_mapping(load_yaml(path), path, "Ingress patch")
    tls_entries = nested_get(patch, "spec", "tls") or []
    rules = nested_get(patch, "spec", "rules") or []
    require(isinstance(tls_entries, list) and tls_entries, f"Expected spec.tls list in {path}")
    require(isinstance(rules, list) and rules, f"Expected spec.rules list in {path}")

    tls_host_found = False
    for index, entry in enumerate(tls_entries, start=1):
        tls_hosts = ensure_mapping(entry, path, f"tls entry #{index}").get("hosts") or []
        require(isinstance(tls_hosts, list), f"Expected tls hosts list in {path}")
        if expected_domain in tls_hosts:
            tls_host_found = True
            break

    rule_host_found = False
    for index, rule in enumerate(rules, start=1):
        rule_host = ensure_mapping(rule, path, f"rule #{index}").get("host")
        if rule_host == expected_domain:
            rule_host_found = True
            break

    require(tls_host_found, f"Expected domain {expected_domain} not found in TLS hosts for {path}")
    require(rule_host_found, f"Expected domain {expected_domain} not found in rules for {path}")


def validate_monitoring_domain_patch(path: Path, expected_domain: str) -> None:
    patch = ensure_mapping(load_yaml(path), path, "Application patch")
    helm_values = nested_get(patch, "spec", "source", "helm", "values")
    require(isinstance(helm_values, str), f"Expected spec.source.helm.values string in {path}")

    values_mapping = ensure_mapping(load_yaml_string(helm_values, f"Helm values in {path}"), path, "Grafana Helm values")
    ingress = ensure_mapping(nested_get(values_mapping, "grafana", "ingress") or {}, path, "Grafana ingress values")
    hosts = ingress.get("hosts") or []
    tls_entries = ingress.get("tls") or []
    require(isinstance(hosts, list), f"Expected ingress hosts list in {path}")
    require(isinstance(tls_entries, list) and tls_entries, f"Expected ingress tls list in {path}")
    require(expected_domain in hosts, f"Expected domain {expected_domain} not found in Grafana hosts for {path}")

    tls_host_found = False
    for index, entry in enumerate(tls_entries, start=1):
        tls_hosts = ensure_mapping(entry, path, f"Grafana TLS entry #{index}").get("hosts") or []
        require(isinstance(tls_hosts, list), f"Expected Grafana TLS hosts list in {path}")
        if expected_domain in tls_hosts:
            tls_host_found = True
            break

    require(tls_host_found, f"Expected domain {expected_domain} not found in Grafana TLS hosts for {path}")


def validate_domain_expectations() -> None:
    for env_name in ("dev", "prod"):
        validate_infrastructure_domain_patch(
            REPO_ROOT / f"kubernetes/infrastructure/overlays/{env_name}/patch-domain.yaml",
            EXPECTED_DOMAINS["infrastructure"][env_name],
        )
        validate_monitoring_domain_patch(
            REPO_ROOT / f"kubernetes/apps/monitoring/overlays/{env_name}/patch-domain.yaml",
            EXPECTED_DOMAINS["monitoring"][env_name],
        )


def validate_kustomization_overlays() -> None:
    overlay_dirs = (
        "kubernetes/infrastructure/overlays/dev",
        "kubernetes/infrastructure/overlays/prod",
        "kubernetes/apps/monitoring/overlays/dev",
        "kubernetes/apps/monitoring/overlays/prod",
    )
    for overlay_dir in overlay_dirs:
        path = REPO_ROOT / overlay_dir / "kustomization.yaml"
        data = ensure_mapping(load_yaml(path), path, "Kustomization mapping")
        patches = data.get("patches") or []
        require(isinstance(patches, list), f"Expected patches list in {path}")
        patch_paths = {
            ensure_mapping(p, path, "patch entry").get("path")
            for p in patches
        }
        check(
            "patch-domain.yaml" in patch_paths,
            f"{path} must reference patch-domain.yaml in patches",
        )


def main() -> None:
    validators = [
        validate_inventory_separation,
        require_text_checks,
        validate_inventory_vars,
        validate_seal_playbook,
        validate_bootstrap_playbooks,
        validate_load_balancer_playbook,
        validate_obsolete_bootstrap_files,
        validate_domain_expectations,
        validate_kustomization_overlays,
    ]

    hard_errors: list[str] = []
    for validator in validators:
        try:
            validator()
        except ValidationError as exc:
            hard_errors.append(str(exc))

    all_errors = hard_errors + _collected_errors
    if all_errors:
        print(f"Validation failed with {len(all_errors)} error(s):", file=sys.stderr)
        for error in all_errors:
            print(f"  - {error}", file=sys.stderr)
        raise SystemExit(1)

    print("Repository consistency validation passed.")


if __name__ == "__main__":
    main()