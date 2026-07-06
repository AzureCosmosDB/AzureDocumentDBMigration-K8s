#Requires -Version 7.0
param(
    # --- GitHub release source ---
    [string]$GitHubRepo = "AzureCosmosDB/AzureDocumentDBMigration-K8s",
    [string]$ReleaseTag = "latest",
    [string]$PackageAsset = "migration-package.zip",

    # --- Local package source (temporary override; skips GitHub download) ---
    [string]$LocalPackagePath = "",


    # --- Azure target ---
    [string]$Subscription = "",
    # Random lowercase-alphabetic suffix appended to resource names so each run
    # gets unique names. Pass -Suffix "" to reuse a fixed environment.
    [string]$Suffix = (-join ((97..122) | Get-Random -Count 5 | ForEach-Object { [char]$_ })),
    [string]$ResourceGroup = "migrationrg-$Suffix",
    [string]$Location = "centralus",
    [string]$AksClusterName = "migrationaks-$Suffix",
    [string]$AksNodeVmSize = "Standard_D4ds_v5",
    [int]$AksNodeCount = 1,
    # Optional: resource ID of an existing subnet to launch AKS nodes into so
    # pods can reach a MongoDB endpoint within that VNet. Empty = AKS-managed VNet.
    # example: /subscriptions/<subscriptionId>/resourceGroups/<vnetResourceGroup>/providers/Microsoft.Network/virtualNetworks/<vnetName>/subnets/<subnetName>
    [string]$VnetSubnetId = "",
    # Kubernetes service (ClusterIP) CIDR and its DNS IP. Must NOT overlap the
    # node subnet / VNet / peered / on-prem ranges. Override if it conflicts.
    [string]$ServiceCidr = "10.100.0.0/16",
    [string]$DnsServiceIp = "10.100.0.10",
    [string]$AcrName = "migrationacr$Suffix",
    [string]$PgServerName = "migrationpg-$Suffix",
    [string]$PgAdminLogin = "migadmin",
    [string]$PgAdminPassword = "",
    [string]$PgDatabaseName = "migrations",
    [string]$StorageAccountName = "migrationstr$Suffix",
    [string]$IdentityName = "migrationid-$Suffix"
)
$ErrorActionPreference = "Stop"

# =============================================================================
# Customer Deployment Script for Mongo Migration Platform (PowerShell)
# Downloads the published package from a GitHub release, builds container images
# in ACR (no local Docker required), and provisions the full AKS environment.
# Supports idempotent execution (skips existing resources).
# =============================================================================

# --- Logging helper ---
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "INFO"    { Write-Host "[$timestamp] [INFO]    $Message" -ForegroundColor White }
        "SUCCESS" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green }
        "WARN"    { Write-Host "[$timestamp] [WARN]    $Message" -ForegroundColor DarkYellow }
        "ERROR"   { Write-Host "[$timestamp] [ERROR]   $Message" -ForegroundColor Red }
        "CMD"     { Write-Host "[$timestamp] [CMD]     $Message" -ForegroundColor DarkGray }
        "STEP"    { Write-Host "[$timestamp] [STEP]    $Message" -ForegroundColor Yellow }
    }
}

function Invoke-AzCmd {
    param([string]$Command, [switch]$AllowFailure)
    Write-Log "az $Command" -Level CMD
    $result = Invoke-Expression "az $Command"
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) {
        Write-Log "Command failed with exit code $LASTEXITCODE" -Level ERROR
        Write-Log "$result" -Level ERROR
        throw "az command failed: az $Command"
    }
    return $result
}

function Invoke-K8sManifest {
    # Reads a manifest template from the k8s/ folder, substitutes __TOKEN__
    # placeholders, and pipes the result to 'kubectl apply -f -'.
    param([string]$FileName, [hashtable]$Tokens)
    $path = Join-Path $SCRIPT_DIR (Join-Path "k8s" $FileName)
    if (-not (Test-Path $path)) { throw "Kubernetes manifest not found: $path" }
    $content = Get-Content -Path $path -Raw
    foreach ($key in $Tokens.Keys) {
        $content = $content.Replace($key, [string]$Tokens[$key])
    }
    $content | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) { throw "kubectl apply failed for manifest '$FileName'." }
}

# Require PG admin password from a secure input if not explicitly provided
if ([string]::IsNullOrWhiteSpace($PgAdminPassword)) {
    $securePgPassword = Read-Host -Prompt "Enter PostgreSQL admin password for '$PgAdminLogin'" -AsSecureString
    $PgAdminPassword = ConvertFrom-SecureString $securePgPassword -AsPlainText
    if ([string]::IsNullOrWhiteSpace($PgAdminPassword)) {
        throw "PostgreSQL admin password cannot be empty."
    }
}

# Set Azure subscription if specified
if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
    Write-Log "Setting Azure subscription to '$Subscription'..." -Level STEP
    Invoke-AzCmd "account set --subscription $Subscription"
}

# --- Configuration ---
$RESOURCE_GROUP = $ResourceGroup
$LOCATION = $Location
$AKS_CLUSTER_NAME = $AksClusterName
$AKS_NODE_VM_SIZE = $AksNodeVmSize
$AKS_NODE_COUNT = $AksNodeCount
$VNET_SUBNET_ID = $VnetSubnetId
$SERVICE_CIDR = $ServiceCidr
$DNS_SERVICE_IP = $DnsServiceIp
$ACR_NAME = $AcrName
$PG_SERVER_NAME = $PgServerName
$PG_ADMIN_LOGIN = $PgAdminLogin
$PG_ADMIN_PASSWORD = $PgAdminPassword
$PG_DATABASE_NAME = $PgDatabaseName
$STORAGE_ACCOUNT_NAME = $StorageAccountName
$IDENTITY_NAME = $IdentityName
$K8S_NAMESPACE = "migrations"
$K8S_SERVICE_ACCOUNT = "migration-engine-web-sa"
$SCRIPT_DIR = $PSScriptRoot
$ENGINE_IMAGE_NAME = "migration-engine"
$WEB_IMAGE_NAME = "migration-engine-web"
$IMAGE_TAG = "latest"

Write-Host "=== Mongo Migration Platform - Customer Deployment ===" -ForegroundColor Cyan
Write-Log "Configuration:" -Level STEP
Write-Log "  GitHub Repo:       $GitHubRepo"
Write-Log "  Release Tag:       $ReleaseTag"
Write-Log "  Name Suffix:       $Suffix"
Write-Log "  Resource Group:    $RESOURCE_GROUP"
Write-Log "  Location:          $LOCATION"
Write-Log "  AKS Cluster:       $AKS_CLUSTER_NAME"
if (-not [string]::IsNullOrWhiteSpace($VNET_SUBNET_ID)) { Write-Log "  VNet Subnet:       $VNET_SUBNET_ID" }
Write-Log "  Service CIDR:      $SERVICE_CIDR (DNS $DNS_SERVICE_IP)"
Write-Log "  ACR:               $ACR_NAME"
Write-Log "  PostgreSQL Server: $PG_SERVER_NAME"
Write-Log "  Storage Account:   $STORAGE_ACCOUNT_NAME"
Write-Log "  Managed Identity:  $IDENTITY_NAME"
Write-Host ""

# =============================================================================
# 0. Download and extract package from GitHub release
# =============================================================================
Write-Log "[0/9] Download package from GitHub release" -Level STEP
$packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "migration-package-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

if (-not [string]::IsNullOrWhiteSpace($LocalPackagePath)) {
    if (-not (Test-Path $LocalPackagePath)) {
        throw "LocalPackagePath '$LocalPackagePath' does not exist."
    }
    Write-Log "  Using local package '$LocalPackagePath' (skipping GitHub download)." -Level WARN
    Write-Log "  Extracting package..."
    Expand-Archive -Path $LocalPackagePath -DestinationPath $packageRoot -Force
} else {
    if ($GitHubRepo -eq "<owner>/<repo>") {
        throw "Please provide -GitHubRepo '<owner>/<repo>' pointing to the release repository."
    }

    if ($ReleaseTag -eq "latest") {
        $downloadUrl = "https://github.com/$GitHubRepo/releases/latest/download/$PackageAsset"
    } else {
        $downloadUrl = "https://github.com/$GitHubRepo/releases/download/$ReleaseTag/$PackageAsset"
    }

    $zipPath = Join-Path ([System.IO.Path]::GetTempPath()) "$([System.Guid]::NewGuid().ToString('N'))-$PackageAsset"
    Write-Log "  Downloading $downloadUrl ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Write-Log "  Extracting package..."
    Expand-Archive -Path $zipPath -DestinationPath $packageRoot -Force
    Remove-Item $zipPath -Force
}

# Validate expected contents
foreach ($required in @("MigrationEngine", "MigrationEngineWeb")) {
    if (-not (Test-Path (Join-Path $packageRoot $required))) {
        throw "Package is missing required entry '$required'. The release asset '$PackageAsset' may be malformed."
    }
}
$versionFile = Join-Path $packageRoot "version.json"
if (Test-Path $versionFile) {
    $pkgVersion = (Get-Content $versionFile -Raw | ConvertFrom-Json)
    Write-Log "  Package version: $($pkgVersion.version) (commit $($pkgVersion.gitCommit), built $($pkgVersion.builtAtUtc))" -Level SUCCESS
}
Write-Log "  Package downloaded and extracted to '$packageRoot'." -Level SUCCESS

# =============================================================================
# 1. Resource Group
# =============================================================================
Write-Log "[1/9] Resource Group" -Level STEP
$rgExists = az group show --name $RESOURCE_GROUP 2>$null
if ($rgExists) {
    Write-Log "Resource group '$RESOURCE_GROUP' already exists, skipping." -Level WARN
} else {
    Write-Log "Creating resource group '$RESOURCE_GROUP' in '$LOCATION'..."
    Invoke-AzCmd "group create --name $RESOURCE_GROUP --location $LOCATION --output none"
    Write-Log "Created resource group '$RESOURCE_GROUP'." -Level SUCCESS
}

# =============================================================================
# 2. Managed Identity (User-Assigned)
# =============================================================================
Write-Log "[2/9] Managed Identity" -Level STEP
$miExists = az identity show --resource-group $RESOURCE_GROUP --name $IDENTITY_NAME 2>$null
if ($miExists) {
    Write-Log "Managed identity '$IDENTITY_NAME' already exists, skipping." -Level WARN
} else {
    Write-Log "Creating managed identity '$IDENTITY_NAME'..."
    Invoke-AzCmd "identity create --resource-group $RESOURCE_GROUP --name $IDENTITY_NAME --location $LOCATION --output none"
    Write-Log "Created managed identity '$IDENTITY_NAME'." -Level SUCCESS
}

$IDENTITY_CLIENT_ID = az identity show --resource-group $RESOURCE_GROUP --name $IDENTITY_NAME --query clientId -o tsv
$IDENTITY_PRINCIPAL_ID = az identity show --resource-group $RESOURCE_GROUP --name $IDENTITY_NAME --query principalId -o tsv
Write-Log "  Client ID:    $IDENTITY_CLIENT_ID"
Write-Log "  Principal ID: $IDENTITY_PRINCIPAL_ID"

# =============================================================================
# 3. Azure Container Registry
# =============================================================================
Write-Log "[3/9] Azure Container Registry" -Level STEP
$acrExists = az acr show --resource-group $RESOURCE_GROUP --name $ACR_NAME 2>$null
if ($acrExists) {
    Write-Log "ACR '$ACR_NAME' already exists, skipping." -Level WARN
} else {
    Write-Log "Creating ACR '$ACR_NAME'..."
    Invoke-AzCmd "acr create --resource-group $RESOURCE_GROUP --name $ACR_NAME --sku Standard --output none"
    Write-Log "Created ACR '$ACR_NAME'." -Level SUCCESS
}

$ACR_LOGIN_SERVER = az acr show --resource-group $RESOURCE_GROUP --name $ACR_NAME --query loginServer -o tsv
$WEB_IMAGE = "$ACR_LOGIN_SERVER/${WEB_IMAGE_NAME}:${IMAGE_TAG}"
$ENGINE_IMAGE = "$ACR_LOGIN_SERVER/${ENGINE_IMAGE_NAME}:${IMAGE_TAG}"
Write-Log "  Login Server: $ACR_LOGIN_SERVER"

# =============================================================================
# 4. PostgreSQL Flexible Server
# =============================================================================
Write-Log "[4/9] PostgreSQL Flexible Server" -Level STEP
$pgExists = az postgres flexible-server show --resource-group $RESOURCE_GROUP --name $PG_SERVER_NAME 2>$null
if ($pgExists) {
    Write-Log "PostgreSQL server '$PG_SERVER_NAME' already exists, skipping." -Level WARN
} else {
    Write-Log "Creating PostgreSQL server '$PG_SERVER_NAME' (this may take a few minutes)..."
    Invoke-AzCmd "postgres flexible-server create --resource-group $RESOURCE_GROUP --name $PG_SERVER_NAME --location $LOCATION --admin-user $PG_ADMIN_LOGIN --admin-password $PG_ADMIN_PASSWORD --sku-name Standard_B2s --tier Burstable --storage-size 32 --version 16 --yes --output none"
    Write-Log "Created PostgreSQL server '$PG_SERVER_NAME'." -Level SUCCESS
}

$PG_FQDN = az postgres flexible-server show --resource-group $RESOURCE_GROUP --name $PG_SERVER_NAME --query fullyQualifiedDomainName -o tsv
Write-Log "  FQDN: $PG_FQDN"

# Create database if not exists
$dbExists = az postgres flexible-server db show --resource-group $RESOURCE_GROUP --server-name $PG_SERVER_NAME --name $PG_DATABASE_NAME 2>$null
if ($dbExists) {
    Write-Log "  Database '$PG_DATABASE_NAME' already exists." -Level WARN
} else {
    Write-Log "  Creating database '$PG_DATABASE_NAME'..."
    Invoke-AzCmd "postgres flexible-server db create --resource-group $RESOURCE_GROUP --server-name $PG_SERVER_NAME --name $PG_DATABASE_NAME --output none"
    Write-Log "  Created database '$PG_DATABASE_NAME'." -Level SUCCESS
}

# Allow Azure services to access PG
Write-Log "  Configuring firewall rule for Azure services..."
Invoke-AzCmd "postgres flexible-server firewall-rule create --resource-group $RESOURCE_GROUP --server-name $PG_SERVER_NAME --name AllowAzureServices --start-ip-address 0.0.0.0 --end-ip-address 0.0.0.0 --output none"
Write-Log "  Firewall rule configured." -Level SUCCESS

# Enable Microsoft Entra authentication on PG
Write-Log "  Enabling Microsoft Entra authentication..."
Invoke-AzCmd "postgres flexible-server update --resource-group $RESOURCE_GROUP --name $PG_SERVER_NAME --microsoft-entra-auth Enabled --output none"
Write-Log "  Microsoft Entra authentication enabled." -Level SUCCESS

# Add managed identity as PG Entra admin (idempotent)
Write-Log "  Adding managed identity as PG Entra admin..."
$entraAdminExists = az postgres flexible-server microsoft-entra-admin show --resource-group $RESOURCE_GROUP --server-name $PG_SERVER_NAME --object-id $IDENTITY_PRINCIPAL_ID 2>$null
if ($entraAdminExists) {
    Write-Log "  Managed identity is already a PG Entra admin, skipping." -Level WARN
} else {
    Invoke-AzCmd "postgres flexible-server microsoft-entra-admin create --resource-group $RESOURCE_GROUP --server-name $PG_SERVER_NAME --display-name $IDENTITY_NAME --object-id $IDENTITY_PRINCIPAL_ID --type ServicePrincipal --output none"
    Write-Log "  Managed identity configured as PG Entra admin." -Level SUCCESS
}

# =============================================================================
# 5. Storage Account
# =============================================================================
Write-Log "[5/9] Storage Account" -Level STEP
$storExists = az storage account show --resource-group $RESOURCE_GROUP --name $STORAGE_ACCOUNT_NAME 2>$null
if ($storExists) {
    Write-Log "Storage account '$STORAGE_ACCOUNT_NAME' already exists, skipping." -Level WARN
} else {
    Write-Log "Creating storage account '$STORAGE_ACCOUNT_NAME'..."
    Invoke-AzCmd "storage account create --resource-group $RESOURCE_GROUP --name $STORAGE_ACCOUNT_NAME --location $LOCATION --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --allow-blob-public-access false --output none"
    Write-Log "Created storage account '$STORAGE_ACCOUNT_NAME'." -Level SUCCESS
}

$STORAGE_ACCOUNT_ID = az storage account show --resource-group $RESOURCE_GROUP --name $STORAGE_ACCOUNT_NAME --query id -o tsv
Write-Log "  Storage Account ID: $STORAGE_ACCOUNT_ID"

# Create blob container for logs
Write-Log "  Creating blob container 'migration-logs'..."
az storage container create --account-name $STORAGE_ACCOUNT_NAME --name "migration-logs" --auth-mode login --output none 2>$null
Write-Log "  Container 'migration-logs' configured." -Level SUCCESS

# Assign Storage Blob Data Contributor to MI
Write-Log "  Assigning Storage Blob Data Contributor role to MI..."
az role assignment create --assignee-object-id $IDENTITY_PRINCIPAL_ID --assignee-principal-type ServicePrincipal --role "Storage Blob Data Contributor" --scope $STORAGE_ACCOUNT_ID --output none 2>$null
Write-Log "  Role assigned." -Level SUCCESS

# =============================================================================
# 6. AKS Cluster (with OIDC + Workload Identity)
# =============================================================================
Write-Log "[6/9] AKS Cluster" -Level STEP
$aksExists = az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME 2>$null
if ($aksExists) {
    Write-Log "AKS cluster '$AKS_CLUSTER_NAME' already exists, skipping creation." -Level WARN
    Write-Log "  Ensuring OIDC and workload identity are enabled..."
    az aks update --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --enable-oidc-issuer --enable-workload-identity --output none 2>$null
} else {
    Write-Log "Creating AKS cluster '$AKS_CLUSTER_NAME' (this may take 5-10 minutes)..."
    $vnetSubnetArg = if (-not [string]::IsNullOrWhiteSpace($VNET_SUBNET_ID)) { "--vnet-subnet-id $VNET_SUBNET_ID" } else { "" }
    Invoke-AzCmd "aks create --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --location $LOCATION --node-count $AKS_NODE_COUNT --node-vm-size $AKS_NODE_VM_SIZE --enable-oidc-issuer --enable-workload-identity --enable-managed-identity --enable-cluster-autoscaler --min-count 1 --max-count 10 --attach-acr $ACR_NAME --network-plugin azure --service-cidr $SERVICE_CIDR --dns-service-ip $DNS_SERVICE_IP $vnetSubnetArg --generate-ssh-keys --output none"
    Write-Log "Created AKS cluster '$AKS_CLUSTER_NAME'." -Level SUCCESS
}

$OIDC_ISSUER = az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query oidcIssuerProfile.issuerUrl -o tsv
Write-Log "  OIDC Issuer: $OIDC_ISSUER"

# Attach ACR (idempotent)
Write-Log "  Attaching ACR to AKS..."
az aks update --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --attach-acr $ACR_NAME --output none 2>$null

# Get credentials
Write-Log "  Fetching kubectl credentials..."
az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --overwrite-existing --output none
Write-Log "  kubectl configured for '$AKS_CLUSTER_NAME'." -Level SUCCESS

# =============================================================================
# 7. Federated Credential (links K8s SA to Azure MI)
# =============================================================================
Write-Log "[7/9] Federated Credential" -Level STEP
$FED_CRED_NAME = "migration-federated-cred"
$fedExists = az identity federated-credential show --resource-group $RESOURCE_GROUP --identity-name $IDENTITY_NAME --name $FED_CRED_NAME 2>$null
if ($fedExists) {
    Write-Log "Federated credential '$FED_CRED_NAME' already exists, skipping." -Level WARN
} else {
    Write-Log "Creating federated credential '$FED_CRED_NAME'..."
    Invoke-AzCmd "identity federated-credential create --resource-group $RESOURCE_GROUP --identity-name $IDENTITY_NAME --name $FED_CRED_NAME --issuer $OIDC_ISSUER --subject `"system:serviceaccount:${K8S_NAMESPACE}:${K8S_SERVICE_ACCOUNT}`" --audiences `"api://AzureADTokenExchange`" --output none"
    Write-Log "Created federated credential linking K8s SA '${K8S_NAMESPACE}/${K8S_SERVICE_ACCOUNT}' to MI." -Level SUCCESS
}

# =============================================================================
# 8. Kubernetes Resources (namespace, SA, RBAC, deployment)
# =============================================================================
Write-Log "[8/9] Kubernetes Resources" -Level STEP

# Create namespace
Write-Log "  Creating namespace '$K8S_NAMESPACE'..."
kubectl create namespace $K8S_NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Manifest token map (values are substituted into the k8s/*.yaml templates)
$k8sTokens = @{
    "__NAMESPACE__"            = $K8S_NAMESPACE
    "__SERVICE_ACCOUNT__"      = $K8S_SERVICE_ACCOUNT
    "__IDENTITY_CLIENT_ID__"   = $IDENTITY_CLIENT_ID
    "your-acr.azurecr.io/migration-engine-web:latest" = $WEB_IMAGE
    "your-acr.azurecr.io/migration-engine:latest"     = $ENGINE_IMAGE
    "__PG_FQDN__"              = $PG_FQDN
    "__PG_DATABASE_NAME__"     = $PG_DATABASE_NAME
    "__IDENTITY_NAME__"        = $IDENTITY_NAME
    "__STORAGE_ACCOUNT_NAME__" = $STORAGE_ACCOUNT_NAME
}

# Create service account YAML
Write-Log "  Applying service account with workload identity..."
Invoke-K8sManifest -FileName "serviceaccount.yaml" -Tokens $k8sTokens

# Apply RBAC (from the k8s/ folder bundled next to this script)
Write-Log "  Applying RBAC rules..."
Invoke-K8sManifest -FileName "rbac.yaml" -Tokens $k8sTokens

# Apply deployment and service
Write-Log "  Applying deployment and service manifests..."
Invoke-K8sManifest -FileName "deployment.yaml" -Tokens $k8sTokens

Write-Log "  Kubernetes resources applied." -Level SUCCESS

# =============================================================================
# 9. Build container images from the package using ACR Tasks (no local Docker)
# =============================================================================
Write-Log "[9/9] Build container images (ACR Tasks)" -Level STEP

Write-Log "  Building migration-engine-web in ACR (this may take a few minutes)..."
Invoke-AzCmd "acr build --registry $ACR_NAME --image ${WEB_IMAGE_NAME}:${IMAGE_TAG} --file `"$(Join-Path $SCRIPT_DIR 'MigrationEngineWeb.Dockerfile')`" `"$packageRoot`""
Write-Log "  migration-engine-web built and pushed." -Level SUCCESS

Write-Log "  Building migration-engine in ACR (this may take a few minutes)..."
Invoke-AzCmd "acr build --registry $ACR_NAME --image ${ENGINE_IMAGE_NAME}:${IMAGE_TAG} --file `"$(Join-Path $SCRIPT_DIR 'MigrationEngine.Dockerfile')`" `"$packageRoot`""
Write-Log "  migration-engine built and pushed." -Level SUCCESS

# Restart deployment to pick up latest images
Write-Log "  Restarting deployment..."
kubectl rollout restart deployment/migration-engine-web -n $K8S_NAMESPACE
Write-Log "  Deployment restarted." -Level SUCCESS

# Clean up extracted package
Remove-Item $packageRoot -Recurse -Force -ErrorAction SilentlyContinue

# =============================================================================
# Summary
# =============================================================================
Write-Host ""
Write-Log "=== Deployment Complete ===" -Level SUCCESS
Write-Host ""
Write-Log "Resources:"
Write-Log "  Resource Group:    $RESOURCE_GROUP"
Write-Log "  AKS Cluster:       $AKS_CLUSTER_NAME"
Write-Log "  ACR:               $ACR_LOGIN_SERVER"
Write-Log "  PostgreSQL:        $PG_FQDN"
Write-Log "  Storage Account:   $STORAGE_ACCOUNT_NAME"
Write-Log "  Managed Identity:  $IDENTITY_NAME (Client ID: $IDENTITY_CLIENT_ID)"
Write-Host ""
Write-Log "Waiting for External IP..." -Level STEP
$externalIp = ""
$maxAttempts = 30
$attempt = 0
while ($attempt -lt $maxAttempts) {
    $attempt++
    $externalIp = kubectl get svc migration-engine-web -n $K8S_NAMESPACE -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>$null
    if ($externalIp) {
        break
    }
    Write-Log "  Attempt $attempt/$maxAttempts - External IP not yet assigned, waiting 10s..."
    Start-Sleep -Seconds 10
}

if ($externalIp) {
    Write-Log "External IP: $externalIp" -Level SUCCESS
    Write-Log "Access the web UI at: http://$externalIp"
} else {
    Write-Log "External IP not assigned after $maxAttempts attempts." -Level WARN
    Write-Log "Check manually: kubectl get svc migration-engine-web -n $K8S_NAMESPACE"
}
Write-Host ""
Write-Log "Or via port-forward:"
Write-Log "  kubectl port-forward svc/migration-engine-web 8080:80 -n $K8S_NAMESPACE"
Write-Log "  Open http://localhost:8080"
