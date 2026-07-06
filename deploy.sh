#!/bin/bash
set -euo pipefail

# =============================================================================
# Customer Deployment Script for Mongo Migration Platform (bash)
# Downloads the published package from a GitHub release, builds container images
# in ACR (no local Docker required), and provisions the full AKS environment.
# Supports idempotent execution (skips existing resources).
# =============================================================================

# --- Configuration (override via environment variables) ---
GITHUB_REPO="${GITHUB_REPO:-AzureCosmosDB/AzureDocumentDBMigration-K8s}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
# Specific release version to download; when set it takes precedence over
# RELEASE_TAG (e.g. "0.0.1" -> releases/download/0.0.1/<asset>).
VERSION="${VERSION:-}"
PACKAGE_ASSET="${PACKAGE_ASSET:-migration-package.zip}"

# Local package source (temporary override; skips GitHub download)
LOCAL_PACKAGE_PATH="${LOCAL_PACKAGE_PATH:-}"

SUBSCRIPTION="${SUBSCRIPTION:-}"

# Random lowercase-alphabetic suffix appended to resource names so each run
# gets unique names. Set SUFFIX="" to reuse a fixed environment.
_gen_suffix() {
    local chars="abcdefghijklmnopqrstuvwxyz" s=""
    for _ in 1 2 3 4 5; do s+="${chars:RANDOM%26:1}"; done
    printf '%s' "$s"
}
SUFFIX="${SUFFIX-$(_gen_suffix)}"

RESOURCE_GROUP="${RESOURCE_GROUP:-migrationrg-$SUFFIX}"
LOCATION="${LOCATION:-centralus}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-migrationaks-$SUFFIX}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4ds_v5}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-1}"
# Optional: resource ID of an existing subnet to launch AKS nodes into so pods
# can reach a MongoDB endpoint within that VNet. Empty = AKS-managed VNet.
# example: /subscriptions/<subscriptionId>/resourceGroups/<vnetResourceGroup>/providers/Microsoft.Network/virtualNetworks/<vnetName>/subnets/<subnetName>
VNET_SUBNET_ID="${VNET_SUBNET_ID:-}"
# Kubernetes service (ClusterIP) CIDR and its DNS IP. Must NOT overlap the node
# subnet / VNet / peered / on-prem ranges. Override if it conflicts.
SERVICE_CIDR="${SERVICE_CIDR:-10.100.0.0/16}"
DNS_SERVICE_IP="${DNS_SERVICE_IP:-10.100.0.10}"
ACR_NAME="${ACR_NAME:-migrationacr$SUFFIX}"
PG_SERVER_NAME="${PG_SERVER_NAME:-migrationpg-$SUFFIX}"
PG_ADMIN_LOGIN="${PG_ADMIN_LOGIN:-migadmin}"
PG_ADMIN_PASSWORD="${PG_ADMIN_PASSWORD:-}"
PG_DATABASE_NAME="${PG_DATABASE_NAME:-migrations}"
STORAGE_ACCOUNT_NAME="${STORAGE_ACCOUNT_NAME:-migrationstr$SUFFIX}"
IDENTITY_NAME="${IDENTITY_NAME:-migrationid-$SUFFIX}"
ENGINE_IMAGE_NAME="${ENGINE_IMAGE_NAME:-migration-engine}"
WEB_IMAGE_NAME="${WEB_IMAGE_NAME:-migration-engine-web}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
K8S_NAMESPACE="migrations"
K8S_SERVICE_ACCOUNT="migration-engine-web-sa"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reads a manifest template from the k8s/ folder, substitutes __TOKEN__
# placeholders, and pipes the result to 'kubectl apply -f -'.
apply_manifest() {
    local file="$SCRIPT_DIR/k8s/$1"
    if [ ! -f "$file" ]; then
        echo "ERROR: Kubernetes manifest not found: $file"
        exit 1
    fi
    sed -e "s|__NAMESPACE__|${K8S_NAMESPACE}|g" \
        -e "s|__SERVICE_ACCOUNT__|${K8S_SERVICE_ACCOUNT}|g" \
        -e "s|__IDENTITY_CLIENT_ID__|${IDENTITY_CLIENT_ID}|g" \
        -e "s|your-acr.azurecr.io/migration-engine-web:latest|${WEB_IMAGE}|g" \
        -e "s|your-acr.azurecr.io/migration-engine:latest|${ENGINE_IMAGE}|g" \
        -e "s|__PG_FQDN__|${PG_FQDN}|g" \
        -e "s|__PG_DATABASE_NAME__|${PG_DATABASE_NAME}|g" \
        -e "s|__IDENTITY_NAME__|${IDENTITY_NAME}|g" \
        -e "s|__STORAGE_ACCOUNT_NAME__|${STORAGE_ACCOUNT_NAME}|g" \
        "$file" | kubectl apply -f -
}

echo "=== Mongo Migration Platform - Customer Deployment ==="
echo "GitHub Repo:       $GITHUB_REPO"
echo "Release Tag:       $RELEASE_TAG"
if [ -n "$VERSION" ]; then echo "Version:           $VERSION"; fi
echo "Name Suffix:       $SUFFIX"
echo "Resource Group:    $RESOURCE_GROUP"
echo "Location:          $LOCATION"
echo "AKS Cluster:       $AKS_CLUSTER_NAME"
if [ -n "$VNET_SUBNET_ID" ]; then echo "VNet Subnet:       $VNET_SUBNET_ID"; fi
echo "Service CIDR:      $SERVICE_CIDR (DNS $DNS_SERVICE_IP)"
echo "ACR:               $ACR_NAME"
echo "PostgreSQL Server: $PG_SERVER_NAME"
echo "Storage Account:   $STORAGE_ACCOUNT_NAME"
echo "Managed Identity:  $IDENTITY_NAME"
echo ""

# --- Validate PG password ---
if [ -z "${PG_ADMIN_PASSWORD}" ]; then
    echo "ERROR: PG_ADMIN_PASSWORD is required (no default)."
    echo "ERROR: Example: export PG_ADMIN_PASSWORD='use-a-strong-password'"
    exit 1
fi

# --- Set subscription if specified ---
if [ -n "${SUBSCRIPTION}" ]; then
    az account set --subscription "$SUBSCRIPTION"
fi

# =============================================================================
# 0. Download and extract package from GitHub release
# =============================================================================
echo "--- [0/9] Download package from GitHub release ---"
PACKAGE_ROOT="$(mktemp -d)"
ZIP_PATH="$(mktemp).zip"
trap 'rm -rf "$PACKAGE_ROOT" "$ZIP_PATH"' EXIT

if [ -n "${LOCAL_PACKAGE_PATH}" ]; then
    if [ ! -f "$LOCAL_PACKAGE_PATH" ]; then
        echo "ERROR: LOCAL_PACKAGE_PATH '$LOCAL_PACKAGE_PATH' does not exist."
        exit 1
    fi
    echo "  Using local package '$LOCAL_PACKAGE_PATH' (skipping GitHub download)."
    echo "  Extracting package..."
    unzip -q -o "$LOCAL_PACKAGE_PATH" -d "$PACKAGE_ROOT"
else
    if [ "$GITHUB_REPO" = "<owner>/<repo>" ]; then
        echo "ERROR: Set GITHUB_REPO='<owner>/<repo>' pointing to the release repository."
        exit 1
    fi

    RELEASE_REF="${VERSION:-$RELEASE_TAG}"
    echo "  Using release reference: $RELEASE_REF"
    if [ "$RELEASE_REF" = "latest" ]; then
        DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/latest/download/$PACKAGE_ASSET"
    else
        DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_REF/$PACKAGE_ASSET"
    fi

    echo "  Downloading $DOWNLOAD_URL ..."
    curl -fsSL "$DOWNLOAD_URL" -o "$ZIP_PATH"
    echo "  Extracting package..."
    unzip -q -o "$ZIP_PATH" -d "$PACKAGE_ROOT"
fi

for required in "MigrationEngine" "MigrationEngineWeb"; do
    if [ ! -e "$PACKAGE_ROOT/$required" ]; then
        echo "ERROR: Package is missing required entry '$required'. Asset '$PACKAGE_ASSET' may be malformed."
        exit 1
    fi
done
if [ -f "$PACKAGE_ROOT/version.json" ]; then
    echo "  Package version: $(cat "$PACKAGE_ROOT/version.json" | tr -d '\n')"
fi
echo "  Package downloaded and extracted to '$PACKAGE_ROOT'."

# =============================================================================
# 1. Resource Group
# =============================================================================
echo "--- [1/9] Resource Group ---"
if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
    echo "Resource group '$RESOURCE_GROUP' already exists, skipping."
else
    az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    echo "Created resource group '$RESOURCE_GROUP'."
fi

# =============================================================================
# 2. Managed Identity (User-Assigned)
# =============================================================================
echo "--- [2/9] Managed Identity ---"
if az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" &>/dev/null; then
    echo "Managed identity '$IDENTITY_NAME' already exists, skipping."
else
    az identity create --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --location "$LOCATION" --output none
    echo "Created managed identity '$IDENTITY_NAME'."
fi

IDENTITY_CLIENT_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show --resource-group "$RESOURCE_GROUP" --name "$IDENTITY_NAME" --query principalId -o tsv)
echo "  Client ID: $IDENTITY_CLIENT_ID"

# =============================================================================
# 3. Azure Container Registry
# =============================================================================
echo "--- [3/9] Azure Container Registry ---"
if az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" &>/dev/null; then
    echo "ACR '$ACR_NAME' already exists, skipping."
else
    az acr create --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --sku Standard --output none
    echo "Created ACR '$ACR_NAME'."
fi

ACR_LOGIN_SERVER=$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)
ENGINE_IMAGE="${ACR_LOGIN_SERVER}/${ENGINE_IMAGE_NAME}:${IMAGE_TAG}"
WEB_IMAGE="${ACR_LOGIN_SERVER}/${WEB_IMAGE_NAME}:${IMAGE_TAG}"
echo "  Login Server: $ACR_LOGIN_SERVER"

# =============================================================================
# 4. PostgreSQL Flexible Server
# =============================================================================
echo "--- [4/9] PostgreSQL Flexible Server ---"
if az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$PG_SERVER_NAME" &>/dev/null; then
    echo "PostgreSQL server '$PG_SERVER_NAME' already exists, skipping."
else
    az postgres flexible-server create --resource-group "$RESOURCE_GROUP" --name "$PG_SERVER_NAME" --location "$LOCATION" --admin-user "$PG_ADMIN_LOGIN" --admin-password "$PG_ADMIN_PASSWORD" --sku-name Standard_B2s --tier Burstable --storage-size 32 --version 16 --yes --output none
    echo "Created PostgreSQL server '$PG_SERVER_NAME'."
fi

PG_FQDN=$(az postgres flexible-server show --resource-group "$RESOURCE_GROUP" --name "$PG_SERVER_NAME" --query fullyQualifiedDomainName -o tsv)
echo "  FQDN: $PG_FQDN"

# Create database if not exists
if az postgres flexible-server db show --resource-group "$RESOURCE_GROUP" --server-name "$PG_SERVER_NAME" --name "$PG_DATABASE_NAME" &>/dev/null; then
    echo "  Database '$PG_DATABASE_NAME' already exists."
else
    az postgres flexible-server db create --resource-group "$RESOURCE_GROUP" --server-name "$PG_SERVER_NAME" --name "$PG_DATABASE_NAME" --output none
    echo "  Created database '$PG_DATABASE_NAME'."
fi

# Allow Azure services to access PG
az postgres flexible-server firewall-rule create --resource-group "$RESOURCE_GROUP" --server-name "$PG_SERVER_NAME" --name "AllowAzureServices" --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none
echo "  Firewall rule for Azure services configured."

# Enable Microsoft Entra authentication on PG
az postgres flexible-server update --resource-group "$RESOURCE_GROUP" --name "$PG_SERVER_NAME" --microsoft-entra-auth Enabled --output none
echo "  Microsoft Entra authentication enabled."

# Add managed identity as PG Entra admin (idempotent)
if az postgres flexible-server microsoft-entra-admin show --resource-group "$RESOURCE_GROUP" --server-name "$PG_SERVER_NAME" --object-id "$IDENTITY_PRINCIPAL_ID" &>/dev/null; then
    echo "  Managed identity is already a PG Entra admin, skipping."
else
    az postgres flexible-server microsoft-entra-admin create --resource-group "$RESOURCE_GROUP" --server-name "$PG_SERVER_NAME" --display-name "$IDENTITY_NAME" --object-id "$IDENTITY_PRINCIPAL_ID" --type ServicePrincipal --output none
    echo "  Managed identity configured as PG Entra admin."
fi

# =============================================================================
# 5. Storage Account
# =============================================================================
echo "--- [5/9] Storage Account ---"
if az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT_NAME" &>/dev/null; then
    echo "Storage account '$STORAGE_ACCOUNT_NAME' already exists, skipping."
else
    az storage account create --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT_NAME" --location "$LOCATION" --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --output none
    echo "Created storage account '$STORAGE_ACCOUNT_NAME'."
fi

STORAGE_ACCOUNT_ID=$(az storage account show --resource-group "$RESOURCE_GROUP" --name "$STORAGE_ACCOUNT_NAME" --query id -o tsv)

# Create blob container for logs
az storage container create --account-name "$STORAGE_ACCOUNT_NAME" --name "migration-logs" --auth-mode login --output none 2>/dev/null || true
echo "  Container 'migration-logs' configured."

# Assign Storage Blob Data Contributor to MI
az role assignment create --assignee-object-id "$IDENTITY_PRINCIPAL_ID" --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope "$STORAGE_ACCOUNT_ID" --output none 2>/dev/null || true
echo "  Role assigned."

# =============================================================================
# 6. AKS Cluster (with OIDC + Workload Identity)
# =============================================================================
echo "--- [6/9] AKS Cluster ---"
if az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" &>/dev/null; then
    echo "AKS cluster '$AKS_CLUSTER_NAME' already exists, ensuring OIDC/workload identity..."
    az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --enable-oidc-issuer --enable-workload-identity --output none 2>/dev/null || true
else
    VNET_ARG=""
    if [ -n "$VNET_SUBNET_ID" ]; then VNET_ARG="--vnet-subnet-id $VNET_SUBNET_ID"; fi
    az aks create --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --location "$LOCATION" --node-count "$AKS_NODE_COUNT" --node-vm-size "$AKS_NODE_VM_SIZE" --enable-oidc-issuer --enable-workload-identity --enable-managed-identity --enable-cluster-autoscaler --min-count 1 --max-count 10 --attach-acr "$ACR_NAME" --network-plugin azure --service-cidr "$SERVICE_CIDR" --dns-service-ip "$DNS_SERVICE_IP" $VNET_ARG --generate-ssh-keys --output none
    echo "Created AKS cluster '$AKS_CLUSTER_NAME'."
fi

OIDC_ISSUER=$(az aks show --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --query oidcIssuerProfile.issuerUrl -o tsv)
echo "  OIDC Issuer: $OIDC_ISSUER"

# Attach ACR (idempotent)
az aks update --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --attach-acr "$ACR_NAME" --output none 2>/dev/null || true

# Get credentials
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing --output none
echo "  kubectl configured for '$AKS_CLUSTER_NAME'."

# =============================================================================
# 7. Federated Credential (links K8s SA to Azure MI)
# =============================================================================
echo "--- [7/9] Federated Credential ---"
FED_CRED_NAME="migration-federated-cred"
if az identity federated-credential show --resource-group "$RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" --name "$FED_CRED_NAME" &>/dev/null; then
    echo "Federated credential '$FED_CRED_NAME' already exists, skipping."
else
    az identity federated-credential create --resource-group "$RESOURCE_GROUP" --identity-name "$IDENTITY_NAME" --name "$FED_CRED_NAME" --issuer "$OIDC_ISSUER" --subject "system:serviceaccount:${K8S_NAMESPACE}:${K8S_SERVICE_ACCOUNT}" --audiences "api://AzureADTokenExchange" --output none
    echo "Created federated credential linking K8s SA '$K8S_NAMESPACE/$K8S_SERVICE_ACCOUNT' to MI."
fi

# =============================================================================
# 8. Kubernetes Resources (namespace, SA, RBAC, deployment)
# =============================================================================
echo "--- [8/9] Kubernetes Resources ---"

# Create namespace
kubectl create namespace "$K8S_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create service account with workload identity
apply_manifest "serviceaccount.yaml"

# Apply RBAC (from the k8s/ folder bundled next to this script)
apply_manifest "rbac.yaml"

# Apply deployment and service
apply_manifest "deployment.yaml"

echo "  Kubernetes resources applied."

# =============================================================================
# 9. Build container images from the package using ACR Tasks (no local Docker)
# =============================================================================
echo "--- [9/9] Build container images (ACR Tasks) ---"

echo "  Building migration-engine-web in ACR (this may take a few minutes)..."
az acr build --registry "$ACR_NAME" --image "${WEB_IMAGE_NAME}:${IMAGE_TAG}" --file "$SCRIPT_DIR/MigrationEngineWeb.Dockerfile" "$PACKAGE_ROOT"
echo "  migration-engine-web built and pushed."

echo "  Building migration-engine in ACR (this may take a few minutes)..."
az acr build --registry "$ACR_NAME" --image "${ENGINE_IMAGE_NAME}:${IMAGE_TAG}" --file "$SCRIPT_DIR/MigrationEngine.Dockerfile" "$PACKAGE_ROOT"
echo "  migration-engine built and pushed."

# Restart deployment to pick up latest images
kubectl rollout restart deployment/migration-engine-web -n "$K8S_NAMESPACE"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Deployment Complete ==="
echo "  Resource Group:    $RESOURCE_GROUP"
echo "  AKS Cluster:       $AKS_CLUSTER_NAME"
echo "  ACR:               $ACR_LOGIN_SERVER"
echo "  PostgreSQL:        $PG_FQDN"
echo "  Storage Account:   $STORAGE_ACCOUNT_NAME"
echo "  Managed Identity:  $IDENTITY_NAME (Client ID: $IDENTITY_CLIENT_ID)"
echo ""
echo "Waiting for External IP..."
EXTERNAL_IP=""
MAX_ATTEMPTS=30
ATTEMPT=0
while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
    ATTEMPT=$((ATTEMPT + 1))
    EXTERNAL_IP=$(kubectl get svc migration-engine-web -n "$K8S_NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$EXTERNAL_IP" ]; then
        break
    fi
    echo "  Attempt $ATTEMPT/$MAX_ATTEMPTS - External IP not yet assigned, waiting 10s..."
    sleep 10
done

if [ -n "$EXTERNAL_IP" ]; then
    echo "External IP: $EXTERNAL_IP"
    echo "Access the web UI at: http://$EXTERNAL_IP"
else
    echo "External IP not assigned after $MAX_ATTEMPTS attempts."
    echo "Check manually: kubectl get svc migration-engine-web -n $K8S_NAMESPACE"
fi
echo ""
echo "Or via port-forward:"
echo "  kubectl port-forward svc/migration-engine-web 8080:80 -n $K8S_NAMESPACE"
echo "  Open http://localhost:8080"
