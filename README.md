# k3s-cluster

[![CI](https://github.com/jbee43/k3s-cluster/actions/workflows/ci.yml/badge.svg)](https://github.com/jbee43/k3s-cluster/actions/workflows/ci.yml)

## TLDR

GitOps setup for a k3s on-prem cluster managed entirely by Argo CD using the **app-of-apps** pattern

Most apps pull charts directly from upstream Helm repos via Argo CD multi-source (pinned versions), deployed in dependency order via sync waves

Storage backed by a NAS with two tiers (SSD and HDD) over NFS, plus Longhorn for local HA

Secrets are never committed, they are referenced by name and synced via External Secrets Operator

### Managed applications

| Wave | Category       | Apps                                                                                             |
| ---- | -------------- | ------------------------------------------------------------------------------------------------ |
| -4   | Storage        | NFS provisioner (SSD), NFS provisioner (HDD)                                                     |
| -3   | Infrastructure | cert-manager, MetalLB                                                                            |
| -2   | Networking     | Traefik, External Secrets                                                                        |
| -1   | Storage        | Longhorn                                                                                         |
| 0    | GitOps         | Argo CD (self-managed)                                                                           |
| 1    | Operators      | CNPG operator, ECK operator                                                                      |
| 2    | Data           | CNPG cluster (+ Barman backups), ECK stack (ES + Kibana + Filebeat), RabbitMQ (Cluster Operator) |
| 3    | Monitoring     | Grafana, kube-state-metrics, Zabbix (server + agents)                                            |
| 4    | Applications   | pgAdmin4, Pi-hole, ownCloud (oCIS)                                                               |

---

## How to use

### Prerequisites

- A running k3s cluster with `kubectl` configured
- Helm v3 installed
- NFS exports configured on the NAS:
  - **SSD tier**: e.g. `192.168.1.100:/volume1/k3s-ssd`
  - **HDD tier**: e.g. `192.168.1.100:/volume2/k3s-hdd`
  - **Longhorn backups**: e.g. `192.168.1.100:/volume1/longhorn-backups`
- An S3-compatible object store on the NAS for CNPG Barman backups (e.g. MinIO)
- A Git repository accessible by the cluster (this repo pushed to a remote)

### 1. Configure your environment

All environment-specific values are centralized in the `env` block of [apps/values.yaml](apps/values.yaml)

Edit this single section:

```yaml
env:
  domain: k3s.local # Base domain for all ingress hostnames
  letsencryptEmail: admin@example.com # cert-manager ACME registration
  nas:
    ip: "192.168.1.100" # NAS IP address
    ssdPath: /volume1/k3s-ssd # NFS export for fast SSD storage
    hddPath: /volume2/k3s-hdd # NFS export for cold HDD storage
    longhornBackupPath: /volume1/longhorn-backups
  metallb:
    addressRange: 192.168.1.200-192.168.1.250 # LAN IP pool for LoadBalancer services
  backup:
    endpointURL: http://192.168.1.100:9000 # S3-compatible endpoint (MinIO)
    bucket: cnpg-backups # Backup bucket name
  pihole:
    dnsIP: "192.168.1.253" # Dedicated MetalLB IP for DNS
```

Also set `spec.source.repoURL` to your Git repository URL at the top of the same file

Each app entry references these values via Go template syntax (e.g. `{{ .Values.env.domain }}`)

The Application template evaluates them at render time via Helm's `tpl` function and passes them as `helm.valuesObject` overrides

Individual chart `values.yaml` files contain sensible defaults and should not need editing

### 2. Create required secrets

All secrets are referenced by name (never stored in values)

Before first deploy, use the helper script or create them manually:

```bash
# Interactive — creates all secrets, prompts for each value
pwsh ./scripts/create-secrets.ps1

# Create a specific secret
pwsh ./scripts/create-secrets.ps1 -Secret grafana

# List all required secrets
pwsh ./scripts/create-secrets.ps1 -List
```

Required secrets per namespace:

| Namespace  | Secret Name                  | Keys                                 |
| ---------- | ---------------------------- | ------------------------------------ |
| monitoring | `grafana-admin-credentials`  | `username`, `password`               |
| zabbix     | `zabbix-db-credentials`      | `username`, `password`               |
| pgadmin    | `pgadmin-credentials`        | `password`                           |
| pihole     | `pihole-admin-password`      | `password`                           |
| cnpg       | `cnpg-backup-creds`          | `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY` |
| owncloud   | `owncloud-admin-credentials` | `username`, `password`               |

> **RabbitMQ is the exception**: the Cluster Operator generates `rabbitmq-default-user` (keys: `username`, `password`) and `rabbitmq-erlang-cookie` automatically in the `rabbitmq` namespace. Retrieve the management UI password with:
>
> ```bash
> kubectl get secret rabbitmq-default-user -n rabbitmq -o jsonpath='{.data.password}' | base64 -d
> ```

### 3. Set up k3s nodes (optional)

Use the helper script to install k3s on Linux nodes via SSH:

```bash
# First server node (initializes cluster)
pwsh ./scripts/setup-k3s.ps1 -Node 192.168.1.10 -User admin -Role server \
    -DisableTraefik -DisableServiceLB -DisableLocalPath

# Additional server nodes (prompts for token securely)
pwsh ./scripts/setup-k3s.ps1 -Node 192.168.1.11 -User admin -Role server \
    -JoinURL "https://192.168.1.10:6443" -Token (Read-Host -AsSecureString) \
    -DisableTraefik -DisableServiceLB -DisableLocalPath

# Agent (worker) nodes
pwsh ./scripts/setup-k3s.ps1 -Node 192.168.1.20 -User admin -Role agent \
    -JoinURL "https://192.168.1.10:6443" -Token (Read-Host -AsSecureString)
```

Traefik, ServiceLB, and local-path-provisioner are disabled because this setup deploys its own Traefik, MetalLB, and NFS/Longhorn storage.

### 4. Bootstrap Argo CD

```bash
# Install Argo CD and apply the root app-of-apps
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
    --namespace argocd --create-namespace \
    --values platform/argocd/values.yaml \
    --wait --timeout 5m
```

See `scripts/bootstrap-argocd.ps1` for the full bootstrap including the root Application CR.

### 5. Access Argo CD

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080`, login with `admin` and the initial password:

```bash
kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d
```

---

## Repository structure

```text
k3s-cluster/
├── apps/                          # Root app-of-apps Helm chart
│   ├── Chart.yaml
│   ├── values.yaml                # Centralized env config + app registry
│   └── templates/
│       └── application.yaml       # Templated Argo CD Application CRs
├── scripts/
│   ├── bootstrap-argocd.ps1       # One-time Argo CD bootstrap
│   ├── create-secrets.ps1         # Interactive secret provisioning
│   ├── helm-preview.ps1           # Render templates/values for debugging
│   ├── list-versions.ps1          # Show pinned/latest chart versions
│   └── setup-k3s.ps1              # k3s node installation via SSH
├── .github/
│   └── workflows/
│       └── ci.yml                 # CI pipeline (lint, validate, security, render)
├── platform/                      # Per-app values and umbrella charts
│   ├── argocd/                    # Argo CD (values only)
│   ├── cert-manager/              # TLS automation (umbrella + ClusterIssuers)
│   ├── cnpg-cluster/              # PostgreSQL HA cluster + Barman backups
│   ├── cnpg-operator/             # CloudNativePG operator
│   ├── eck-operator/              # Elastic Cloud on Kubernetes operator
│   ├── eck-stack/                 # Elasticsearch + Kibana + Filebeat
│   ├── external-secrets/          # Secret sync from external providers
│   ├── grafana/                   # Observability dashboards
│   ├── kube-state-metrics/        # Kubernetes metrics exporter
│   ├── longhorn/                  # Distributed block storage
│   ├── metallb/                   # Bare metal LB (umbrella + L2 CRs)
│   ├── nfs-provisioner-hdd/       # NAS cold storage (HDD tier)
│   ├── nfs-provisioner-ssd/       # NAS fast storage (SSD tier)
│   ├── owncloud/                  # ownCloud oCIS file sync and share
│   ├── pgadmin4/                  # PostgreSQL management UI
│   ├── pihole/                    # DNS sinkhole / ad blocker
│   ├── rabbitmq/                  # Message broker (Cluster Operator + RabbitmqCluster CR)
│   ├── traefik/                   # Ingress controller
│   └── zabbix/                    # Infrastructure monitoring
├── .editorconfig
├── .gitattributes
├── .gitignore
├── .yamllint.yml
└── README.md
```

## Architecture decisions

- **OCI-first chart sourcing**: most apps use OCI registries (ghcr.io, quay.io) via Argo CD multi-source, with values files in `platform/*/values.yaml`. Charts without OCI support fall back to HTTP repos. cert-manager and metallb use umbrella charts (custom template CRs); rabbitmq is an umbrella that vendors the official Cluster Operator manifest plus a `RabbitmqCluster` CR (no first-party Helm chart upstream, so we never depend on bitnami)
- **Centralized env config**: all environment-specific values live in `apps/values.yaml` under `env:`, passed to each chart via `tpl` + `helm.valuesObject`, so no scattered placeholders across files
- **Sync waves** enforce deployment order so operators are ready before their CRs, storage before workloads, etc.
- **Two NFS tiers** enable cost-effective storage: SSD for databases/active data, HDD for archives/backups
- **Longhorn** complements NFS for workloads that benefit from local replicated block storage
- **External Secrets Operator** decouples secret management from GitOps: secrets never touch the repo

## Upgrading charts

```bash
# Check for available updates
pwsh ./scripts/list-versions.ps1 -Latest

# Show currently pinned versions
pwsh ./scripts/list-versions.ps1
```

For direct-chart apps (most apps), update `chartVersion` in [apps/values.yaml](apps/values.yaml) and push.

For umbrella charts (cert-manager, metallb), also update the dependency version in the respective `Chart.yaml`:

```bash
helm dependency update platform/cert-manager/
helm dependency update platform/metallb/
```

Each `platform/*/values.yaml` includes a `# Chart ref:` comment linking to the upstream chart's full default values

## References

- [Argo CD App of Apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/)
- [CloudNativePG](https://cloudnative-pg.io/documentation/)
- [ECK Quickstart](https://www.elastic.co/guide/en/cloud-on-k8s/current/k8s-quickstart.html)
- [Longhorn](https://longhorn.io/docs/)
- [MetalLB](https://metallb.universe.tf/)
- [ownCloud oCIS](https://doc.owncloud.com/ocis/next/)
- [Traefik](https://doc.traefik.io/traefik/)
- [Zabbix Helm](https://github.com/zabbix-community/helm-zabbix)
