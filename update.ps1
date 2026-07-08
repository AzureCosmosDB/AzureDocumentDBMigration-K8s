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
    [string]$ResourceGroup = "docdb-migration-engine-rg",
    [string]$AksClusterName = "docdb-migration-engine-aks",
    [string]$AcrName = "docdbmigrationengineacr",
    [string]$K8sNamespace = "migrations",
    [string]$WebDeploymentName = "migration-engine-web",
    [string]$WebContainerName = "migration-engine-web",
    [string]$EngineImageName = "migration-engine",
    [string]$WebImageName = "migration-engine-web",
    [string]$ImageTag = "",
    [string]$RolloutTimeout = "300s"
)

$ErrorActionPreference = "Stop"

# =============================================================================
# Customer Update Script for Azure DocumentDB Migration Platform (PowerShell)
# Downloads the latest published package from a GitHub release, rebuilds the
# container images in ACR (no local Docker required), and rolls out the update.
# =============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "INFO"    { Write-Host "[$timestamp] [INFO]    $Message" -ForegroundColor White }
        "SUCCESS" { Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green }
        "WARN"    { Write-Host "[$timestamp] [WARN]    $Message" -ForegroundColor DarkYellow }
        "ERROR"   { Write-Host "[$timestamp] [ERROR]   $Message" -ForegroundColor Red }
        "STEP"    { Write-Host "[$timestamp] [STEP]    $Message" -ForegroundColor Yellow }
        "CMD"     { Write-Host "[$timestamp] [CMD]     $Message" -ForegroundColor DarkGray }
    }
}

function Invoke-NativeCommand {
    param([string]$FilePath, [string[]]$Arguments)
    Write-Log "$FilePath $($Arguments -join ' ')" -Level CMD
    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw ("Command failed with exit code {0}: {1} {2}" -f $LASTEXITCODE, $FilePath, ($Arguments -join ' '))
    }
}

if ([string]::IsNullOrWhiteSpace($ImageTag)) {
    $ImageTag = (Get-Date -Format "yyyyMMdd-HHmmss")
}

$SCRIPT_DIR = $PSScriptRoot

Write-Host "=== Azure DocumentDB Migration Platform - Customer Update ===" -ForegroundColor Cyan
Write-Log "GitHub Repo:    $GitHubRepo"
Write-Log "Release Tag:    $ReleaseTag"
Write-Log "Resource Group: $ResourceGroup"
Write-Log "AKS Cluster:    $AksClusterName"
Write-Log "ACR:            $AcrName"
Write-Log "Namespace:      $K8sNamespace"
Write-Log "Deployment:     $WebDeploymentName"
Write-Log "Image Tag:      $ImageTag"
Write-Host ""

foreach ($tool in @("az", "kubectl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "Required tool not found: $tool"
    }
}

if (-not [string]::IsNullOrWhiteSpace($Subscription)) {
    Write-Log "[0/6] Set Azure subscription" -Level STEP
    Invoke-NativeCommand "az" @("account", "set", "--subscription", $Subscription)
}

Write-Log "[1/6] Download package from GitHub release" -Level STEP
$packageRoot = Join-Path ([System.IO.Path]::GetTempPath()) "migration-package-$([System.Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

if (-not [string]::IsNullOrWhiteSpace($LocalPackagePath)) {
    if (-not (Test-Path $LocalPackagePath)) {
        throw "LocalPackagePath '$LocalPackagePath' does not exist."
    }
    Write-Log "Using local package '$LocalPackagePath' (skipping GitHub download)." -Level WARN
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
    Write-Log "Downloading $downloadUrl ..."
    Invoke-WebRequest -Uri $downloadUrl -OutFile $zipPath -UseBasicParsing
    Expand-Archive -Path $zipPath -DestinationPath $packageRoot -Force
    Remove-Item $zipPath -Force
}
foreach ($required in @("MigrationEngine", "MigrationEngineWeb")) {
    if (-not (Test-Path (Join-Path $packageRoot $required))) {
        throw "Package is missing required entry '$required'. The release asset '$PackageAsset' may be malformed."
    }
}
$versionFile = Join-Path $packageRoot "version.json"
if (Test-Path $versionFile) {
    $pkgVersion = (Get-Content $versionFile -Raw | ConvertFrom-Json)
    Write-Log "Package version: $($pkgVersion.version) (commit $($pkgVersion.gitCommit), built $($pkgVersion.builtAtUtc))" -Level SUCCESS
}
Write-Log "Package downloaded and extracted." -Level SUCCESS

Write-Log "[2/6] Resolve ACR login server" -Level STEP
$acrLoginServer = (& az acr show --resource-group $ResourceGroup --name $AcrName --query loginServer -o tsv).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($acrLoginServer)) {
    throw "Failed to resolve login server for ACR '$AcrName'."
}
$engineImage = "$acrLoginServer/$EngineImageName`:$ImageTag"
$webImage = "$acrLoginServer/$WebImageName`:$ImageTag"
Write-Log "Login Server: $acrLoginServer" -Level SUCCESS

Write-Log "[3/6] Get AKS credentials" -Level STEP
Invoke-NativeCommand "az" @("aks", "get-credentials", "--resource-group", $ResourceGroup, "--name", $AksClusterName, "--overwrite-existing", "--output", "none")

Write-Log "[4/6] Build web image in ACR (this may take a few minutes)" -Level STEP
Invoke-NativeCommand "az" @("acr", "build", "--registry", $AcrName, "--image", "$WebImageName`:$ImageTag", "--file", (Join-Path $SCRIPT_DIR "MigrationEngineWeb.Dockerfile"), $packageRoot)
Write-Log "Built and pushed $webImage" -Level SUCCESS

Write-Log "[5/6] Build engine image in ACR (this may take a few minutes)" -Level STEP
Invoke-NativeCommand "az" @("acr", "build", "--registry", $AcrName, "--image", "$EngineImageName`:$ImageTag", "--file", (Join-Path $SCRIPT_DIR "MigrationEngine.Dockerfile"), $packageRoot)
Write-Log "Built and pushed $engineImage" -Level SUCCESS

Write-Log "[6/6] Update deployment and roll out" -Level STEP
Invoke-NativeCommand "kubectl" @("set", "image", "deployment/$WebDeploymentName", "-n", $K8sNamespace, "$WebContainerName=$webImage")
Invoke-NativeCommand "kubectl" @("set", "env", "deployment/$WebDeploymentName", "-n", $K8sNamespace, "Kubernetes__MigrationEngineImage=$engineImage")
Invoke-NativeCommand "kubectl" @("rollout", "status", "deployment/$WebDeploymentName", "-n", $K8sNamespace, "--timeout=$RolloutTimeout")

# Clean up extracted package
Remove-Item $packageRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== Update Complete ===" -ForegroundColor Green
Write-Log "Web Image:    $webImage" -Level SUCCESS
Write-Log "Engine Image: $engineImage" -Level SUCCESS
Write-Log "Deployment:   $K8sNamespace/$WebDeploymentName" -Level SUCCESS
