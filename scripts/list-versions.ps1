#Requires -Version 7.0
<#
.SYNOPSIS
    Lists Helm chart versions pinned in this cluster.
.DESCRIPTION
    Parses apps/values.yaml and umbrella Chart.yaml files to show all pinned
    chart versions. Use -Latest to query repos for available updates.
    Supports both OCI registries and traditional HTTP Helm repos.
.EXAMPLE
    pwsh ./scripts/list-versions.ps1
    pwsh ./scripts/list-versions.ps1 -Latest
#>

param(
    [switch] $latest
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-RepoName([string] $url) {
    $uri = [System.Uri]$url
    if ($uri.Host -match '^(.+)\.github\.io$') {
        return $Matches[1]
    }
    $cleaned = $uri.Host -replace '^(charts|helm)\.' -replace '\.(io|co|com|net)$'
    return ($cleaned -split '\.')[0]
}

function Test-IsOci([string] $url) {
    return -not ($url -match '^https?://')
}

# ── Parse direct-chart apps from apps/values.yaml ────────────────────────────
$appsFile = Join-Path $repoRoot "apps/values.yaml"
$lines = Get-Content $appsFile
$apps = [System.Collections.ArrayList]::new()
$current = $null
$inApps = $false

foreach ($line in $lines) {
    if ($line -match '^apps:') { $inApps = $true; continue }
    if (-not $inApps) { continue }

    if ($line -match '^\s{2}-\s+name:\s+(.+)') {
        if ($null -ne $current -and $current.ContainsKey("chart")) {
            [void]$apps.Add([PSCustomObject]$current)
        }
        $current = @{ name = $Matches[1].Trim(); source = "multi-source" }
    }
    elseif ($null -ne $current) {
        if ($line -match '^\s{4}chart:\s+(.+)') { $current.chart = $Matches[1].Trim() }
        elseif ($line -match '^\s{4}repoURL:\s+(.+)') { $current.repoURL = $Matches[1].Trim() }
        elseif ($line -match '^\s{4}chartVersion:\s+"?([^"\s]+)"?') { $current.chartVersion = $Matches[1].Trim() }
    }
}
if ($null -ne $current -and $current.ContainsKey("chart")) {
    [void]$apps.Add([PSCustomObject]$current)
}

# ── Parse umbrella chart dependencies ────────────────────────────────────────
# Two flavors:
#   1. Standard umbrella → upstream Helm chart in `dependencies:`
#   2. Vendored umbrella → no dependency, but `appVersion` pins a manifest from a
#      GitHub release. The annotation `k3s-cluster/upstream: <owner>/<repo>` tells
#      us where to look for newer releases.
$platformDir = Join-Path $repoRoot "platform"
foreach ($chartFile in (Get-ChildItem -Path $platformDir -Recurse -Filter "Chart.yaml")) {
    $chartLines = Get-Content $chartFile.FullName
    $dep = @{ name = $chartFile.Directory.Name; source = "umbrella" }
    $inDeps = $false
    $appVersion = $null
    $upstream = $null

    foreach ($cl in $chartLines) {
        if ($cl -match '^appVersion:\s+"?([^"\s]+)"?') { $appVersion = $Matches[1].Trim() }
        elseif ($cl -match '^\s+k3s-cluster/upstream:\s+(.+)') { $upstream = $Matches[1].Trim() }

        if ($cl -match '^dependencies:') { $inDeps = $true; continue }
        if (-not $inDeps) { continue }
        if ($cl -match '^\s+-\s+name:\s+(.+)') { $dep.chart = $Matches[1].Trim() }
        elseif ($cl -match '^\s+version:\s+"?([^"\s]+)"?') { $dep.chartVersion = $Matches[1].Trim() }
        elseif ($cl -match '^\s+repository:\s+(.+)') {
            $url = $Matches[1].Trim()
            $dep.repoURL = $url -replace '^oci://'
        }
    }

    if ($dep.ContainsKey("chart")) {
        [void]$apps.Add([PSCustomObject]$dep)
    }
    elseif ($null -ne $appVersion -and $null -ne $upstream) {
        # Vendored upstream manifest (e.g. RabbitMQ Cluster Operator)
        $dep.source = "vendored"
        $dep.chart = $upstream
        $dep.chartVersion = $appVersion
        $dep.repoURL = "github.com/$upstream"
        [void]$apps.Add([PSCustomObject]$dep)
    }
}

$apps = $apps | Sort-Object name

# ── Fetch latest versions if requested ───────────────────────────────────────
if ($latest) {
    Write-Host "Fetching latest versions from repos..." -ForegroundColor Cyan

    $httpRepos = @{}
    foreach ($app in $apps) {
        if ($app.source -eq "vendored") { continue }
        $url = $app.repoURL
        if (-not (Test-IsOci $url) -and -not $httpRepos.ContainsKey($url)) {
            $repoName = Get-RepoName $url
            helm repo add $repoName $url --force-update 2>$null | Out-Null
            $httpRepos[$url] = $repoName
        }
    }
    if ($httpRepos.Count -gt 0) {
        helm repo update 2>$null | Out-Null
    }

    foreach ($app in $apps) {
        if ($app.source -eq "vendored") {
            # Query GitHub releases API for vendored upstreams
            try {
                $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($app.chart)/releases/latest" -Headers @{ "User-Agent" = "list-versions" }
                $app | Add-Member -NotePropertyName "latestVersion" -NotePropertyValue $rel.tag_name -Force
            }
            catch {
                $app | Add-Member -NotePropertyName "latestVersion" -NotePropertyValue "?" -Force
            }
            continue
        }

        $url = $app.repoURL

        if (Test-IsOci $url) {
            $ociRef = "oci://$url/$($app.chart)"
            $output = helm show chart $ociRef 2>$null
            $verMatch = $output | Select-String "^version:\s+(.+)$"
            if ($verMatch) {
                $app | Add-Member -NotePropertyName "latestVersion" -NotePropertyValue $verMatch.Matches[0].Groups[1].Value.Trim() -Force
            }
            else {
                $app | Add-Member -NotePropertyName "latestVersion" -NotePropertyValue "?" -Force
            }
        }
        else {
            $repoName = $httpRepos[$url]
            $searchKey = "$repoName/$($app.chart)"
            $results = helm search repo $searchKey --output json 2>$null | ConvertFrom-Json
            $exact = $results | Where-Object { $_.name -eq $searchKey } | Select-Object -First 1
            if ($exact) {
                $app | Add-Member -NotePropertyName "latestVersion" -NotePropertyValue $exact.version -Force
            }
            else {
                $app | Add-Member -NotePropertyName "latestVersion" -NotePropertyValue "?" -Force
            }
        }
    }
}

# ── Display results ──────────────────────────────────────────────────────────
$nameW = 24
$chartW = 36
$pinnedW = 12

if ($latest) {
    $header = "{0,-$nameW} {1,-$chartW} {2,-$pinnedW} {3,-12} {4}" -f "App", "Chart", "Pinned", "Latest", "Status"
    $sep = "{0,-$nameW} {1,-$chartW} {2,-$pinnedW} {3,-12} {4}" -f ("-" * $nameW), ("-" * $chartW), ("-" * $pinnedW), ("-" * 12), ("-" * 16)
}
else {
    $header = "{0,-$nameW} {1,-$chartW} {2,-$pinnedW} {3}" -f "App", "Chart", "Pinned", "Source"
    $sep = "{0,-$nameW} {1,-$chartW} {2,-$pinnedW} {3}" -f ("-" * $nameW), ("-" * $chartW), ("-" * $pinnedW), ("-" * 12)
}

Write-Host ""
Write-Host $header -ForegroundColor White
Write-Host $sep -ForegroundColor DarkGray

foreach ($app in $apps) {
    if ($latest) {
        $latestVer = $app.latestVersion
        $pinnedNorm = $app.chartVersion -replace '^v'
        $latestNorm = $latestVer -replace '^v'

        $status = if ($latestNorm -eq $pinnedNorm) { "Up to date" }
                  elseif ($latestVer -eq "?") { "Unknown" }
                  else { "Update available" }

        $line = "{0,-$nameW} {1,-$chartW} {2,-$pinnedW} {3,-12}" -f $app.name, $app.chart, $app.chartVersion, $latestVer
        Write-Host $line -NoNewline

        switch ($status) {
            "Up to date"       { Write-Host " $status" -ForegroundColor Green }
            "Update available"  { Write-Host " $status" -ForegroundColor Yellow }
            default            { Write-Host " $status" -ForegroundColor DarkGray }
        }
    }
    else {
        Write-Host ("{0,-$nameW} {1,-$chartW} {2,-$pinnedW} {3}" -f $app.name, $app.chart, $app.chartVersion, $app.source)
    }
}

Write-Host ""
