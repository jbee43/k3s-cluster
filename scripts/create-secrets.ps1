#Requires -Version 7.0
<#
.SYNOPSIS
    Creates all required Kubernetes secrets for the k3s cluster.
.DESCRIPTION
    Interactively prompts for credentials and creates secrets in their
    respective namespaces. Safe to re-run (uses apply with dry-run).
.EXAMPLE
    pwsh ./scripts/create-secrets.ps1
    pwsh ./scripts/create-secrets.ps1 -Secret grafana
    pwsh ./scripts/create-secrets.ps1 -List
#>

param(
    [string] $secret,

    [switch] $list
)

$ErrorActionPreference = "Stop"

$secrets = [ordered]@{
    "grafana-admin-credentials" = @{
        namespace = "monitoring"
        keys      = @("username", "password")
    }
    "zabbix-db-credentials" = @{
        namespace = "zabbix"
        keys      = @("username", "password")
    }
    "pgadmin-credentials" = @{
        namespace = "pgadmin"
        keys      = @("password")
    }
    "pihole-admin-password" = @{
        namespace = "pihole"
        keys      = @("password")
    }
    "cnpg-backup-creds" = @{
        namespace = "cnpg"
        keys      = @("ACCESS_KEY_ID", "ACCESS_SECRET_KEY")
    }
    "owncloud-admin-credentials" = @{
        namespace = "owncloud"
        keys      = @("username", "password")
    }
}

if ($list) {
    Write-Host "`nRequired secrets:" -ForegroundColor Cyan
    Write-Host ""
    foreach ($name in $secrets.Keys) {
        $s = $secrets[$name]
        $keysStr = ($s.keys -join ", ")
        Write-Host "  $name" -ForegroundColor Green -NoNewline
        Write-Host " ($($s.namespace))" -ForegroundColor DarkGray -NoNewline
        Write-Host " - keys: $keysStr"
    }
    Write-Host ""
    exit 0
}

function New-Secret {
    param(
        [string] $name,
        [string] $namespace,
        [string[]] $keys
    )

    Write-Host "`n--- $name ($namespace) ---" -ForegroundColor Cyan

    kubectl create namespace $namespace --dry-run=client -o yaml | kubectl apply -f - 2>$null

    $literals = @()
    foreach ($key in $keys) {
        $value = Read-Host -Prompt "  $key" -AsSecureString
        $plain = ConvertFrom-SecureString -SecureString $value -AsPlainText
        if ([string]::IsNullOrWhiteSpace($plain)) {
            Write-Host "  Skipped (empty value)" -ForegroundColor Yellow
            return
        }
        $literals += "--from-literal=$key=$plain"
    }

    $kubectlArgs = @("create", "secret", "generic", $name, "--namespace", $namespace) + $literals + @("--dry-run=client", "-o", "yaml")
    & kubectl @kubectlArgs | kubectl apply -f -

    Write-Host "  Created." -ForegroundColor Green
}

if ($secret) {
    $matched = $secrets.Keys | Where-Object { $_ -like "*$secret*" }
    if (-not $matched) {
        Write-Host "No secret matching '$secret'. Use -List to see all." -ForegroundColor Red
        exit 1
    }
    foreach ($name in $matched) {
        New-Secret -name $name -namespace $secrets[$name].namespace -keys $secrets[$name].keys
    }
}
else {
    Write-Host "This will create all required secrets interactively." -ForegroundColor Cyan
    Write-Host "Press Enter to skip any secret you don't need yet.`n"

    foreach ($name in $secrets.Keys) {
        New-Secret -name $name -namespace $secrets[$name].namespace -keys $secrets[$name].keys
    }
}

Write-Host "`nDone." -ForegroundColor Green
