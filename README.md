# k8s-cluster-bootstrap

Public showcase of a VPS-based Kubernetes platform bootstrap repository for two environments: `dev` and `prod`.

The repository contains the automation and desired-state manifests used to prepare Linux hosts, create a `kubeadm` Kubernetes cluster, install the platform layer, configure external traffic, and hand ongoing reconciliation to Argo CD.

![Kubernetes deployment topology](assets/infrastructure.svg)

## Infrastructure Topology

Both environments use the same runtime shape:

```text
Cloudflare -> nginx LB VPS -> ingress-nginx NodePort -> Kubernetes Service -> Pod
```

| Area | Implementation |
| --- | --- |
| Public edge | Cloudflare DNS/proxy/TLS |
| Load balancer | standalone nginx VPS forwarding HTTP/HTTPS to worker NodePorts |
| Kubernetes | kubeadm cluster with one control-plane node and three worker nodes |
| Networking | Cilium CNI, ingress-nginx exposed as NodePort `30080`/`30443` |
| Storage | external MinIO VPS used as S3-compatible object storage for Loki |
| GitOps | Argo CD reconciles Kustomize overlays from Git |

| Environment | Public edge | Kubernetes nodes | Storage |
| --- | --- | --- | --- |
| `prod` | Cloudflare -> nginx LB `194.164.63.224` | control-plane `85.215.150.64`, workers `85.215.150.65`, `85.215.150.68`, `85.215.150.69` | MinIO `87.106.147.10` |
| `dev` | Cloudflare -> nginx LB `87.106.21.4` | control-plane `87.106.11.11`, workers `217.154.147.130`, `87.106.146.241`, `194.164.207.175` | MinIO `87.106.90.193` |

## Automation Flow

The operational path is built around repeatable Ansible and shell entrypoints.

| Layer | Automation |
| --- | --- |
| Local tooling | `scripts/setup-local.sh` prepares a Linux/WSL operator environment |
| Host preparation | Ansible prepares OS packages, firewall rules, containerd and Kubernetes packages |
| Storage preparation | `ansible/playbooks/04-prepare-minio.yml` prepares the external MinIO VPS |
| Cluster bootstrap | `scripts/bootstrap.sh` runs `ansible/site.yml` for kubeadm init, worker joins, Cilium, Argo CD and platform bootstrap |
| Load balancer | `scripts/setup-lb.sh` applies the nginx LB configuration for dev/prod inventories |
| GitOps handoff | Argo CD reconciles system, infrastructure, monitoring and application overlays |
| Operations | helper scripts wrap kubeconfig selection, teardown, LB teardown and application deploy/remove flows |
| CI guardrails | GitHub Actions validates shell scripts, YAML, Kustomize rendering and repository consistency without contacting live hosts |

Bootstrap phases are defined in `ansible/site.yml`: server preparation, container runtime, Kubernetes packages, firewall, MinIO, control-plane initialization, worker joins, Cilium, Argo CD, Sealed Secrets and initial platform manifests.

## Technology Stack

| Category | Technologies |
| --- | --- |
| Provisioning | Ansible, Bash, inventory-based dev/prod separation |
| Kubernetes bootstrap | kubeadm, kubelet, containerd |
| Networking | Cilium, ingress-nginx, nginx LB VPS, Cloudflare |
| GitOps | Argo CD, Kustomize overlays |
| Secrets | Sealed Secrets, sanitized public SealedSecret manifests |
| Certificates | cert-manager, ACME ClusterIssuer |
| Storage | local-path-provisioner, external MinIO S3-compatible storage |
| Database | CloudNativePG PostgreSQL |
| Observability | kube-prometheus-stack, Prometheus, Alertmanager, Grafana, Loki, Promtail, blackbox exporter |
| CI | GitHub Actions, ShellCheck, yamllint, kubectl Kustomize rendering, custom repository consistency checks |

## Platform Components

| Component | Source | Role |
| --- | --- | --- |
| Cilium | bootstrap playbooks | pod networking and CNI installation |
| ingress-nginx | `kubernetes/system/ingress-nginx.yaml` | public HTTP/HTTPS entrypoint through worker NodePorts |
| cert-manager | `kubernetes/system/cert-manager.yaml` | TLS certificate automation |
| Sealed Secrets | `kubernetes/system/sealed-secrets.yaml` | Git-safe secret delivery pattern |
| Argo CD | `ansible/playbooks/08-install-argocd.yml` | GitOps controller |
| CloudNativePG | `kubernetes/system/cloudnative-pg-operator.yaml` | PostgreSQL operator |
| local-path-provisioner | `kubernetes/system/local-path-provisioner.yaml` | local persistent volume provisioner |
| MinIO | `ansible/playbooks/04-prepare-minio.yml` | external object storage backend |

## Observability

Monitoring manifests live under `kubernetes/apps/monitoring/` and are reconciled by Argo CD.

| Component | Purpose |
| --- | --- |
| kube-prometheus-stack | Prometheus Operator, Prometheus, Alertmanager and Grafana |
| node-exporter | host-level Kubernetes node metrics |
| kube-state-metrics | Kubernetes object-state metrics |
| Loki | log storage using external MinIO object storage |
| Promtail | node log shipping to Loki |
| blackbox exporter | external HTTP endpoint probing |
| Grafana dashboards | infrastructure monitoring and Loki log exploration dashboards |

## Application Workload

The repository includes manifests and operational playbooks for `garmin-ingest`:

- FastAPI API deployment
- background worker deployment
- Redis
- CloudNativePG PostgreSQL cluster
- database migration Job
- ingress route
- PVC-backed state
- sealed database/auth credentials structure

## Repository Layout

```text
.
├── .github/workflows/          # static CI guardrails
├── ansible/                    # inventories, staged playbooks and templates
├── assets/                     # rendered diagrams and icon assets
├── diagrams/                   # editable draw.io diagram source
├── kubernetes/                 # GitOps desired state
│   ├── system/                 # base cluster components
│   ├── infrastructure/         # ingress, issuers and blackbox probes
│   └── apps/                   # monitoring and application manifests
├── scripts/                    # operator entrypoints and helper scripts
├── ansible/site.yml            # full cluster bootstrap flow
├── ansible/teardown.yml        # cluster teardown flow
└── requirements-dev.txt        # local validation dependencies
```

## Main Entry Points

| Command | Purpose |
| --- | --- |
| `./scripts/setup-local.sh` | prepare local Linux/WSL tooling |
| `./scripts/setup-lb.sh --inventory ansible/inventory/lb-dev/hosts.yml` | configure dev load balancer |
| `./scripts/setup-lb.sh --inventory ansible/inventory/lb-prod/hosts.yml` | configure prod load balancer |
| `./scripts/bootstrap.sh --inventory ansible/inventory/dev/hosts.yml` | bootstrap dev cluster |
| `./scripts/bootstrap.sh --inventory ansible/inventory/prod/hosts.yml` | bootstrap prod cluster |
| `./scripts/teardown.sh --inventory ansible/inventory/dev/hosts.yml` | tear down dev cluster |
| `./scripts/teardown.sh --inventory ansible/inventory/prod/hosts.yml` | tear down prod cluster |
| `./scripts/kubectl-env.sh --env dev ...` | run kubectl with the selected environment kubeconfig |
| `./scripts/with-kubeconfig.sh --env prod -- <command>` | run any command with the selected environment kubeconfig |
