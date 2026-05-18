#Requires -Version 7.0
<#
.SYNOPSIS
    Renders Helm chart templates or shows values for inspection.
.DESCRIPTION
    Supports both local charts (umbrella/root with Chart.yaml) and multi-source
    apps (values-only directories that pull charts from upstream repos).
    For multi-source apps, chart details and env overrides are resolved from
    apps/values.yaml to produce a preview matching the deployed state.
    Supports both OCI registries and traditional HTTP Helm repos.
.EXAMPLE
    pwsh ./scripts/helm-preview.ps1 -Chart platform/grafana
    pwsh ./scripts/helm-preview.ps1 -Chart platform/grafana -Mode values
    pwsh ./scripts/helm-preview.ps1 -Chart apps -Mode template
    pwsh ./scripts/helm-preview.ps1 -Chart platform/cert-manager -UpdateDeps
#>

param(
    [Parameter(Mandatory)]
    [string] $chart,

    [ValidateSet("template", "values")]
    [string] $mode = "template",

    [string] $releaseName,

    [string] $namespace,

    [string[]] $set,

    [string[]] $valuesFiles,

    [switch] $updateDeps
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$tempFiles = [System.Collections.ArrayList]::new()

try {

# ── Helper functions ─────────────────────────────────────────────────────────

function Test-IsOci([string] $url) {
    return -not ($url -match '^https?://')
}

function Get-RepoName([string] $url) {
    $uri = [System.Uri]$url
    if ($uri.Host -match '^(.+)\.github\.io$') {
        return $Matches[1]
    }
    $cleaned = $uri.Host -replace '^(charts|helm)\.' -replace '\.(io|co|com|net)$'
    return ($cleaned -split '\.')[0]
}

function Get-ChartRef([string] $repoURL, [string] $chartName) {
    if (Test-IsOci $repoURL) {
        return "oci://$repoURL/$chartName"
    }
    $repoName = Get-RepoName $repoURL
    helm repo add $repoName $repoURL --force-update 2>$null | Out-Null
    helm repo update $repoName 2>$null | Out-Null
    return "$repoName/$chartName"
}

function Get-FlatEnvValues([string[]] $fileLines) {
    $values = @{}
    $inEnv = $false
    $parents = @{}

    foreach ($l in $fileLines) {
        if ($l -match '^env:\s*$') { $inEnv = $true; continue }
        if (-not $inEnv) { continue }
        if ($l -match '^\S') { break }
        if ($l -match '^\s*$' -or $l -match '^\s*#') { continue }

        $stripped = $l.TrimStart()
        $indent = $l.Length - $stripped.Length
        $level = [int](($indent - 2) / 2)

        if ($stripped -match '^(\w+):\s*$') {
            $parents[$level] = $Matches[1]
        }
        elseif ($stripped -match '^([\w]+):\s+(.+)') {
            $key = $Matches[1]
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            $path = "env"
            for ($i = 0; $i -lt $level; $i++) {
                if ($parents.ContainsKey($i)) { $path += ".$($parents[$i])" }
            }
            $path += ".$key"
            $values[$path] = $val
        }
    }

    return $values
}

function Resolve-GoTemplates([string] $content, [hashtable] $envValues) {
    return [regex]::Replace($content, '\{\{\s*\.Values\.([\w.]+)\s*\}\}', {
        param($m)
        $key = $m.Groups[1].Value
        if ($envValues.ContainsKey($key)) { return $envValues[$key] }
        return $m.Value
    })
}

function Get-HelmValuesBlock([string[]] $fileLines, [string] $matchField, [string] $matchValue) {
    $inApps = $false
    $current = $null
    $inHelmValues = $false
    $lines = @()

    foreach ($line in $fileLines) {
        if ($line -match '^apps:') { $inApps = $true; continue }
        if (-not $inApps) { continue }

        if ($line -match '^\s{2}-\s+name:\s+(.+)') {
            if ($null -ne $current -and $current[$matchField] -eq $matchValue -and $lines.Count -gt 0) {
                return ($lines -join "`n")
            }
            $current = @{}
            $inHelmValues = $false
            $lines = @()
        }
        elseif ($null -ne $current) {
            if ($inHelmValues) {
                if ($line -match '^\s{8}' -or ($line -match '^\s*$' -and $lines.Count -gt 0)) {
                    $lines += ($line -replace '^\s{8}', '')
                }
                else { $inHelmValues = $false }
            }

            if (-not $inHelmValues) {
                if ($line -match '^\s{4}(\w+):\s+(.+)') { $current[$Matches[1]] = $Matches[2].Trim() }
                elseif ($line -match '^\s{6}values:\s*\|') { $inHelmValues = $true }
            }
        }
    }

    if ($null -ne $current -and $current[$matchField] -eq $matchValue -and $lines.Count -gt 0) {
        return ($lines -join "`n")
    }

    return $null
}

function Write-EnvOverrides([string[]] $appsLines, [string] $matchField, [string] $matchValue) {
    $helmValuesBlock = Get-HelmValuesBlock $appsLines $matchField $matchValue
    if (-not $helmValuesBlock) { return @() }

    $envValues = Get-FlatEnvValues $appsLines
    $resolved = Resolve-GoTemplates $helmValuesBlock $envValues
    $tf = New-TemporaryFile
    [void]$script:tempFiles.Add($tf.FullName)
    $resolved | Set-Content -Path $tf.FullName -NoNewline
    Write-Host "    (env overrides applied from apps/values.yaml)" -ForegroundColor DarkGray
    return @("--values", $tf.FullName)
}

# ── Resolve chart path ───────────────────────────────────────────────────────

$chartPath = if ([System.IO.Path]::IsPathRooted($chart)) { $chart }
             else { Join-Path $repoRoot $chart }

if (-not (Test-Path $chartPath)) {
    throw "Path not found: $chartPath"
}

$chartYaml = Join-Path $chartPath "Chart.yaml"
$valuesYaml = Join-Path $chartPath "values.yaml"
$isLocalChart = Test-Path $chartYaml

$userArgs = @()
foreach ($s in $set) { $userArgs += "--set"; $userArgs += $s }
foreach ($f in $valuesFiles) { $userArgs += "--values"; $userArgs += $f }

$appsFile = Join-Path $repoRoot "apps/values.yaml"
$relativePath = $chartPath.Replace($repoRoot, "").TrimStart(
    [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar
).Replace("\", "/")

# ── Local chart (umbrella or root app-of-apps) ──────────────────────────────

if ($isLocalChart) {
    $chartName = (Get-Content $chartYaml | Select-String "^name:\s*(.+)$").Matches[0].Groups[1].Value.Trim()

    if (-not $releaseName) { $releaseName = $chartName }
    if (-not $namespace) { $namespace = "default" }

    if ($updateDeps) {
        Write-Host "--- Updating dependencies for $chartName ---" -ForegroundColor Cyan
        helm dependency update $chartPath
        Write-Host ""
    }

    $envArgs = @()
    if (Test-Path $appsFile) {
        $appsLines = Get-Content $appsFile
        $envArgs = Write-EnvOverrides $appsLines "path" $relativePath
    }

    Write-Host "--- $chartName (local chart) ---" -ForegroundColor Cyan
    switch ($mode) {
        "template" { helm template $releaseName $chartPath --namespace $namespace @envArgs @userArgs }
        "values"   { helm show values $chartPath }
    }
}

# ── Multi-source app ────────────────────────────────────────────────────────

else {
    if (-not (Test-Path $valuesYaml)) {
        throw "No Chart.yaml or values.yaml found in: $chartPath"
    }

    $appsLines = Get-Content $appsFile
    $appEntry = $null
    $current = $null
    $inApps = $false

    foreach ($line in $appsLines) {
        if ($line -match '^apps:') { $inApps = $true; continue }
        if (-not $inApps) { continue }

        if ($line -match '^\s{2}-\s+name:\s+(.+)') {
            if ($null -ne $current -and $current.ContainsKey("valuesPath") -and $current.valuesPath -eq $relativePath) {
                $appEntry = $current; break
            }
            $current = @{ name = $Matches[1].Trim() }
        }
        elseif ($null -ne $current) {
            if ($line -match '^\s{4}chart:\s+(.+)') { $current.chart = $Matches[1].Trim() }
            elseif ($line -match '^\s{4}repoURL:\s+(.+)') { $current.repoURL = $Matches[1].Trim() }
            elseif ($line -match '^\s{4}chartVersion:\s+"?([^"\s]+)"?') { $current.chartVersion = $Matches[1].Trim() }
            elseif ($line -match '^\s{4}valuesPath:\s+(.+)') { $current.valuesPath = $Matches[1].Trim() }
            elseif ($line -match '^\s{4}namespace:\s+(.+)') { $current.namespace = $Matches[1].Trim() }
        }
    }
    if ($null -eq $appEntry -and $null -ne $current -and $current.ContainsKey("valuesPath") -and $current.valuesPath -eq $relativePath) {
        $appEntry = $current
    }

    if ($null -eq $appEntry -or -not $appEntry.ContainsKey("chart")) {
        throw "No matching app found in apps/values.yaml for valuesPath: $relativePath"
    }

    $chartName = $appEntry.chart
    $repoURL = $appEntry.repoURL
    $chartVersion = $appEntry.chartVersion
    if (-not $releaseName) { $releaseName = $appEntry.name }
    if (-not $namespace) { $namespace = if ($appEntry.ContainsKey("namespace")) { $appEntry.namespace } else { "default" } }

    $fullChartRef = Get-ChartRef $repoURL $chartName

    Write-Host "--- $($appEntry.name): $chartName $chartVersion ---" -ForegroundColor Cyan
    $envArgs = Write-EnvOverrides $appsLines "valuesPath" $relativePath

    switch ($mode) {
        "template" {
            Write-Host ""
            helm template $releaseName $fullChartRef `
                --version $chartVersion `
                --namespace $namespace `
                --values $valuesYaml `
                @envArgs @userArgs
        }
        "values" {
            Write-Host ""
            helm show values $fullChartRef --version $chartVersion
        }
    }
}

} finally {
    foreach ($f in $tempFiles) {
        Remove-Item $f -ErrorAction SilentlyContinue
    }
}
