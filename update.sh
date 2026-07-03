#!/bin/bash
set -euo pipefail

# =============================================================================
# Customer Update Script for Mongo Migration Platform (bash)
# Downloads the latest published package from a GitHub release, rebuilds the
# container images in ACR (no local Docker required), and rolls out the update.
# =============================================================================

# --- Configuration (override via environment variables) ---
GITHUB_REPO="${GITHUB_REPO:-AzureCosmosDB/AzureDocumentDBMigration-K8s}"
RELEASE_TAG="${RELEASE_TAG:-latest}"
PACKAGE_ASSET="${PACKAGE_ASSET:-migration-package.zip}"

SUBSCRIPTION="${SUBSCRIPTION:-}"
RESOURCE_GROUP="${RESOURCE_GROUP:-mongo-migration-engine-rg}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-mongo-migration-engine-aks}"
ACR_NAME="${ACR_NAME:-mongomigrationengineacr}"
K8S_NAMESPACE="${K8S_NAMESPACE:-migrations}"
WEB_DEPLOYMENT_NAME="${WEB_DEPLOYMENT_NAME:-migration-engine-web}"
WEB_CONTAINER_NAME="${WEB_CONTAINER_NAME:-migration-engine-web}"
ENGINE_IMAGE_NAME="${ENGINE_IMAGE_NAME:-migration-engine}"
WEB_IMAGE_NAME="${WEB_IMAGE_NAME:-migration-engine-web}"
IMAGE_TAG="${IMAGE_TAG:-}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300s}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "$IMAGE_TAG" ]; then
    IMAGE_TAG=$(date +%Y%m%d-%H%M%S)
fi

echo "=== Mongo Migration Platform - Customer Update ==="
echo "GitHub Repo:      $GITHUB_REPO"
echo "Release Tag:      $RELEASE_TAG"
echo "Resource Group:   $RESOURCE_GROUP"
echo "AKS Cluster:      $AKS_CLUSTER_NAME"
echo "ACR:              $ACR_NAME"
echo "Namespace:        $K8S_NAMESPACE"
echo "Deployment:       $WEB_DEPLOYMENT_NAME"
echo "Image Tag:        $IMAGE_TAG"
echo ""

if ! command -v az >/dev/null 2>&1; then echo "ERROR: Azure CLI (az) is required."; exit 1; fi
if ! command -v kubectl >/dev/null 2>&1; then echo "ERROR: kubectl is required."; exit 1; fi

if [ "$GITHUB_REPO" = "<owner>/<repo>" ]; then
    echo "ERROR: Set GITHUB_REPO='<owner>/<repo>' pointing to the release repository."
    exit 1
fi

if [ -n "${SUBSCRIPTION}" ]; then
    az account set --subscription "$SUBSCRIPTION"
fi

echo "--- [1/6] Download package from GitHub release ---"
if [ "$RELEASE_TAG" = "latest" ]; then
    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/latest/download/$PACKAGE_ASSET"
else
    DOWNLOAD_URL="https://github.com/$GITHUB_REPO/releases/download/$RELEASE_TAG/$PACKAGE_ASSET"
fi
PACKAGE_ROOT="$(mktemp -d)"
ZIP_PATH="$(mktemp).zip"
trap 'rm -rf "$PACKAGE_ROOT" "$ZIP_PATH"' EXIT
echo "  Downloading $DOWNLOAD_URL ..."
curl -fsSL "$DOWNLOAD_URL" -o "$ZIP_PATH"
unzip -q -o "$ZIP_PATH" -d "$PACKAGE_ROOT"
for required in "MigrationEngine" "MigrationEngineWeb"; do
    if [ ! -e "$PACKAGE_ROOT/$required" ]; then
        echo "ERROR: Package is missing required entry '$required'. Asset '$PACKAGE_ASSET' may be malformed."
        exit 1
    fi
done
if [ -f "$PACKAGE_ROOT/version.json" ]; then
    echo "  Package version: $(cat "$PACKAGE_ROOT/version.json" | tr -d '\n')"
fi
echo "  Package downloaded and extracted."

echo "--- [2/6] Resolve ACR login server ---"
ACR_LOGIN_SERVER=$(az acr show --resource-group "$RESOURCE_GROUP" --name "$ACR_NAME" --query loginServer -o tsv)
if [ -z "$ACR_LOGIN_SERVER" ]; then
    echo "ERROR: Failed to resolve login server for ACR '$ACR_NAME'."
    exit 1
fi
ENGINE_IMAGE="${ACR_LOGIN_SERVER}/${ENGINE_IMAGE_NAME}:${IMAGE_TAG}"
WEB_IMAGE="${ACR_LOGIN_SERVER}/${WEB_IMAGE_NAME}:${IMAGE_TAG}"
echo "  Login Server: $ACR_LOGIN_SERVER"

echo "--- [3/6] Get AKS credentials ---"
az aks get-credentials --resource-group "$RESOURCE_GROUP" --name "$AKS_CLUSTER_NAME" --overwrite-existing --output none
echo "  kubectl configured for '$AKS_CLUSTER_NAME'."

echo "--- [4/6] Build web image in ACR (this may take a few minutes) ---"
az acr build --registry "$ACR_NAME" --image "${WEB_IMAGE_NAME}:${IMAGE_TAG}" --file "$SCRIPT_DIR/MigrationEngineWeb.Dockerfile" "$PACKAGE_ROOT"
echo "  Built and pushed $WEB_IMAGE"

echo "--- [5/6] Build engine image in ACR (this may take a few minutes) ---"
az acr build --registry "$ACR_NAME" --image "${ENGINE_IMAGE_NAME}:${IMAGE_TAG}" --file "$SCRIPT_DIR/MigrationEngine.Dockerfile" "$PACKAGE_ROOT"
echo "  Built and pushed $ENGINE_IMAGE"

echo "--- [6/6] Update deployment and roll out ---"
kubectl set image deployment/"$WEB_DEPLOYMENT_NAME" -n "$K8S_NAMESPACE" "$WEB_CONTAINER_NAME"="$WEB_IMAGE"
kubectl set env deployment/"$WEB_DEPLOYMENT_NAME" -n "$K8S_NAMESPACE" Kubernetes__MigrationEngineImage="$ENGINE_IMAGE"
kubectl rollout status deployment/"$WEB_DEPLOYMENT_NAME" -n "$K8S_NAMESPACE" --timeout="$ROLLOUT_TIMEOUT"

echo ""
echo "=== Update Complete ==="
echo "  Web Image:    $WEB_IMAGE"
echo "  Engine Image: $ENGINE_IMAGE"
echo "  Deployment:   $K8S_NAMESPACE/$WEB_DEPLOYMENT_NAME"
