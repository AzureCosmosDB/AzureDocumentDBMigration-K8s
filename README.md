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

## Deploy parameters

All parameters for `deploy.ps1` / `deploy.sh`:

| PowerShell | Bash env var | Default | Description |
| ---------- | ------------ | ------- | ----------- |
| `-GitHubRepo` | `GITHUB_REPO` | `AzureCosmosDB/AzureDocumentDBMigration-K8s` | GitHub repository (`owner/repo`) hosting the release. |
| `-ReleaseTag` | `RELEASE_TAG` | `latest` | Release tag to deploy; use `latest` or a specific tag (e.g. `v1.0.0`). |
| `-PackageAsset` | `PACKAGE_ASSET` | `migration-package.zip` | Name of the release asset to download. |
| `-LocalPackagePath` | _(PowerShell only)_ | `""` | Path to a local package zip; when set, skips the GitHub download. |
| `-Subscription` | `SUBSCRIPTION` | (current) | Azure subscription ID to target. |
| `-ResourceGroup` | `RESOURCE_GROUP` | `mongo-migration-engine-rg` | Resource group to create/use. |
| `-Location` | `LOCATION` | `centralus` | Azure region for all resources. |
| `-AksClusterName` | `AKS_CLUSTER_NAME` | `mongo-migration-engine-aks` | Name of the AKS cluster. |
| `-AksNodeVmSize` | `AKS_NODE_VM_SIZE` | `Standard_D4ds_v5` | VM size for AKS nodes. |
| `-AksNodeCount` | `AKS_NODE_COUNT` | `1` | Number of AKS nodes. |
| `-VnetSubnetId` | `VNET_SUBNET_ID` | `""` | Resource ID of an existing subnet to deploy AKS nodes into (Azure CNI), so pods can reach a MongoDB endpoint within that VNet. Format: `/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualNetworks/<vnet>/subnets/<subnet>`. Empty = AKS creates its own VNet. |
| `-ServiceCidr` | `SERVICE_CIDR` | `10.100.0.0/16` | Kubernetes service (ClusterIP) CIDR. Must **not** overlap the node subnet / VNet / peered / on-prem ranges. |
| `-DnsServiceIp` | `DNS_SERVICE_IP` | `10.100.0.10` | Cluster DNS service IP; must fall within `ServiceCidr`. |
| `-AcrName` | `ACR_NAME` | `mongomigrationengineacr` | Azure Container Registry name (globally unique). |
| `-PgServerName` | `PG_SERVER_NAME` | `mongo-migration-engine-pg` | PostgreSQL flexible server name. |
| `-PgAdminLogin` | `PG_ADMIN_LOGIN` | `migadmin` | PostgreSQL admin username. |
| `-PgAdminPassword` | `PG_ADMIN_PASSWORD` | (prompted / required) | PostgreSQL admin password. PowerShell prompts securely if omitted; bash requires it. |
| `-PgDatabaseName` | `PG_DATABASE_NAME` | `migrations` | PostgreSQL database name. |
| `-StorageAccountName` | `STORAGE_ACCOUNT_NAME` | `mongomigenginestore` | Storage account name (globally unique). |
| `-IdentityName` | `IDENTITY_NAME` | `mongo-engine-workload-id` | Managed (workload) identity name. |

> **Networking note:** If `-VnetSubnetId` / `VNET_SUBNET_ID` is left empty, AKS
> creates its own VNet and subnet. In that case the cluster may **not** be able
> to reach your source/target MongoDB cluster (depending on its network
> configuration) — e.g. a MongoDB behind a private endpoint, VNet-injected, or
> restricted by a firewall/allowed-IP list. To guarantee connectivity, deploy
> AKS into an existing subnet (via `-VnetSubnetId`) that has network reachability
> to the MongoDB endpoint (same VNet, or a peered VNet with the required
> NSG/route and private DNS/firewall rules).
>
> When deploying into an existing subnet, the Kubernetes service CIDR
> (`-ServiceCidr`, default `10.100.0.0/16`) must **not** overlap the subnet or
> any address range the cluster reaches. If it conflicts, deployment fails with
> `ServiceCidrOverlapExistingSubnetsCidr`; set `-ServiceCidr` / `-DnsServiceIp`
> to a free range (the DNS IP must be inside the service CIDR).

## Update parameters

All parameters for `update.ps1` / `update.sh`:

| PowerShell | Bash env var | Default | Description |
| ---------- | ------------ | ------- | ----------- |
| `-GitHubRepo` | `GITHUB_REPO` | `AzureCosmosDB/AzureDocumentDBMigration-K8s` | GitHub repository (`owner/repo`) hosting the release. |
| `-ReleaseTag` | `RELEASE_TAG` | `latest` | Release tag to roll out; use `latest` or a specific tag (e.g. `v1.0.0`). |
| `-PackageAsset` | `PACKAGE_ASSET` | `migration-package.zip` | Name of the release asset to download. |
| `-Subscription` | `SUBSCRIPTION` | (current) | Azure subscription ID to target. |
| `-ResourceGroup` | `RESOURCE_GROUP` | `mongo-migration-engine-rg` | Resource group of the existing deployment. |
| `-AksClusterName` | `AKS_CLUSTER_NAME` | `mongo-migration-engine-aks` | Name of the existing AKS cluster. |
| `-AcrName` | `ACR_NAME` | `mongomigrationengineacr` | Azure Container Registry to build images in. |
| `-K8sNamespace` | `K8S_NAMESPACE` | `migrations` | Kubernetes namespace of the deployment. |
| `-WebDeploymentName` | `WEB_DEPLOYMENT_NAME` | `migration-engine-web` | Name of the web Deployment to patch. |
| `-WebContainerName` | `WEB_CONTAINER_NAME` | `migration-engine-web` | Container name within the Deployment. |
| `-EngineImageName` | `ENGINE_IMAGE_NAME` | `migration-engine` | Image repository name for the engine. |
| `-WebImageName` | `WEB_IMAGE_NAME` | `migration-engine-web` | Image repository name for the web app. |
| `-ImageTag` | `IMAGE_TAG` | (timestamp `yyyyMMdd-HHmmss`) | Tag applied to the rebuilt images. |
| `-RolloutTimeout` | `ROLLOUT_TIMEOUT` | `300s` | Timeout for `kubectl rollout status`. |
