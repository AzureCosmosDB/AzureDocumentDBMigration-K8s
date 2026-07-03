# Mongo Migration Platform — Deployment

This repository hosts the deployment tooling for the Mongo Migration Platform.
The compiled application ships as a GitHub release asset (`migration-package.zip`);
the scripts here download that asset, build the container images in your own
Azure Container Registry (no local Docker required), and run everything on AKS.

## Contents

| File | Purpose |
| ---- | ------- |
| `deploy.ps1` / `deploy.sh` | Provision the full AKS environment and deploy from a release. |
| `update.ps1` / `update.sh` | Pull the latest release and roll out an update to an existing deployment. |
| `MigrationEngine.Dockerfile` | Runtime-only image for the migration engine (copies published output). |
| `MigrationEngineWeb.Dockerfile` | Runtime-only image for the web app (also installs `kubectl`). |
| `k8s/` | Kubernetes manifest templates applied during deployment (see below). |

The Dockerfiles here are used directly by the deploy/update scripts as the
`--file` argument for `az acr build`; the extracted release package is the build
context. They are **not** bundled inside the release zip.

### `k8s/` manifests

The `deploy.ps1` / `deploy.sh` scripts apply these templates, substituting
`__TOKEN__` placeholders (namespace, service account, ACR login server,
PostgreSQL/storage settings) with the resolved deployment values at runtime:

| File | Purpose |
| ---- | ------- |
| `k8s/serviceaccount.yaml` | Workload-identity service account. |
| `k8s/rbac.yaml` | Role and RoleBinding for pod management. |
| `k8s/deployment.yaml` | `migration-engine-web` Deployment and Service. |

`update.ps1` / `update.sh` do not apply these manifests; they patch the running
deployment in place (`kubectl set image` / `set env`).

## Prerequisites

- Azure CLI (`az`), logged in (`az login`).
- `kubectl`.
- PowerShell 7+ (for the `.ps1` scripts) **or** bash + `curl` + `unzip` (for the `.sh` scripts).
- Sufficient Azure permissions to create the resource group and its resources.

## Deploy

Provisions the resource group, managed identity, ACR, PostgreSQL, storage, and
AKS, then builds and deploys the images.

PowerShell:

```powershell
./deploy.ps1 -GitHubRepo owner/repo -Subscription <sub-id> -ResourceGroup <rg>
```

Bash:

```bash
GITHUB_REPO=owner/repo \
SUBSCRIPTION=<sub-id> \
RESOURCE_GROUP=<rg> \
PG_ADMIN_PASSWORD='<strong-password>' \
  ./deploy.sh
```

The latest release is used by default. Pin a specific release with
`-ReleaseTag v1.0.0` (PowerShell) or `RELEASE_TAG=v1.0.0` (bash).

If `-PgAdminPassword` / `PG_ADMIN_PASSWORD` is not supplied, the PowerShell
script prompts for it securely; the bash script requires it to be set.

## Update

Downloads the latest release, rebuilds both images in ACR with a timestamped
tag, and rolls out the new images.

PowerShell:

```powershell
./update.ps1 -GitHubRepo owner/repo -ResourceGroup <rg>
```

Bash:

```bash
GITHUB_REPO=owner/repo RESOURCE_GROUP=<rg> ./update.sh
```

## Common options

| PowerShell | Bash env var | Default |
| ---------- | ------------ | ------- |
| `-GitHubRepo` | `GITHUB_REPO` | `AzureCosmosDB/AzureDocumentDBMigration-K8s` |
| `-ReleaseTag` | `RELEASE_TAG` | `latest` |
| `-Subscription` | `SUBSCRIPTION` | (current) |
| `-ResourceGroup` | `RESOURCE_GROUP` | `mongo-migration-engine-rg` |
| `-AksClusterName` | `AKS_CLUSTER_NAME` | `mongo-migration-engine-aks` |
| `-AcrName` | `ACR_NAME` | `mongomigrationengineacr` |
