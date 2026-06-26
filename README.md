# k8s-cluster-bootstrap

Bootstrap repository for two isolated Kubernetes environments:

- `prod` uses `ansible/inventory/prod/hosts.yml` and the `main` branch.
- `dev` uses `ansible/inventory/dev/hosts.yml` and the `dev` branch.

The inventory selects the target servers. The git branch selects which repository state Argo CD syncs and where generated SealedSecrets are committed. Those two inputs must match.

## Public Repository Scope

This public repository keeps the operational structure of the original project, including Ansible playbooks, Kubernetes manifests, scripts, inventories, domains, and infrastructure topology.

The following files are intentionally not included:

- local `.env.bootstrap.local`
- temporary password files
- SOPS source secret files
- kubeconfigs
- bootstrap/setup/teardown logs
- `RUNBOOK.md`
- `docs/`

SealedSecret manifests are kept for structure, but their encrypted payloads are replaced with `encryptedData: {}`.

## Entry Points

- `./scripts/setup-local.sh` prepares the WSL/Linux workstation.
- `./scripts/setup-lb.sh --inventory ansible/inventory/lb-dev/hosts.yml` manages the external load balancer for dev.
- `./scripts/setup-lb.sh --inventory ansible/inventory/lb-prod/hosts.yml` manages the external load balancer for prod.
- `./scripts/bootstrap.sh --inventory ansible/inventory/dev/hosts.yml` bootstraps the dev cluster.
- `./scripts/bootstrap.sh --inventory ansible/inventory/prod/hosts.yml` bootstraps the prod cluster.
- `./scripts/teardown.sh --inventory ansible/inventory/dev/hosts.yml` destroys the dev cluster.
- `./scripts/teardown.sh --inventory ansible/inventory/prod/hosts.yml` destroys the prod cluster.
- `./scripts/kubectl-env.sh --env dev ...` runs `kubectl` against the environment-specific kubeconfig.
- `./scripts/with-kubeconfig.sh --env prod -- <command>` runs any command with the right `KUBECONFIG`.
- `./scripts/fetch-kubeconfig.sh --env dev --host <automation-host>` copies kubeconfig from an automation host or runner.

## Repository Layout

```text
.
├── .github/workflows/          # repository validation
├── ansible/                    # provisioning, bootstrap, teardown, LB and app operations
│   ├── inventory/              # dev/prod and LB inventories
│   ├── playbooks/              # staged playbooks used by site.yml and standalone operations
│   └── templates/              # nginx LB template
├── kubernetes/                 # desired cluster state consumed by Argo CD
│   ├── apps/                   # monitoring and application manifests
│   ├── infrastructure/         # ingress, issuers and blackbox probes
│   └── system/                 # base cluster system components
├── scripts/                    # operator entrypoints and helper scripts
├── ansible/site.yml            # full cluster bootstrap flow
├── ansible/teardown.yml        # cluster teardown flow
└── requirements-dev.txt        # local validation dependencies
```

## Environment Model

| Environment | Branch | Cluster inventory | LB inventory |
| --- | --- | --- | --- |
| `prod` | `main` | `ansible/inventory/prod/hosts.yml` | `ansible/inventory/lb-prod/hosts.yml` |
| `dev` | `dev` | `ansible/inventory/dev/hosts.yml` | `ansible/inventory/lb-dev/hosts.yml` |

The branch and inventory guardrail is enforced before high-impact operations such as bootstrap, teardown and secret sealing.

## Bootstrap Flow

`ansible/site.yml` runs the full cluster bootstrap in phases:

1. preflight connectivity and OS checks
2. OS preparation
3. containerd installation
4. Kubernetes package installation
5. firewall configuration
6. MinIO storage preparation
7. kubeadm control-plane initialization
8. worker joins
9. Cilium installation
10. Argo CD installation
11. initial GitOps bootstrap
12. secret sealing
13. infrastructure and monitoring application bootstrap

Additional standalone playbooks deploy and remove the application manifests under `kubernetes/apps/garmin-ingest/`.

## Validation

The repository includes validation for:

- shell syntax and ShellCheck
- YAML linting
- Kustomize rendering
- repository consistency rules in `scripts/validate_repo.py`

The GitHub Actions workflow lives in `.github/workflows/validate-env-separation.yml`.
