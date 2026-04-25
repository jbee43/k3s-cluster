#Requires -Version 7.0
<#
.SYNOPSIS
    Installs and configures k3s on a Linux node via SSH.
.DESCRIPTION
    Connects to a target Linux node via SSH and installs k3s with a
    hardened config.yaml. Supports both server (first/joining) and agent roles.
.EXAMPLE
    pwsh ./scripts/setup-k3s.ps1 -Node 192.168.1.10 -User admin -Role server -DisableTraefik -DisableServiceLB -DisableLocalPath
    pwsh ./scripts/setup-k3s.ps1 -Node 192.168.1.11 -User admin -Role server -JoinURL "https://192.168.1.10:6443" -Token (Read-Host -AsSecureString)
    pwsh ./scripts/setup-k3s.ps1 -Node 192.168.1.20 -User admin -Role agent -JoinURL "https://192.168.1.10:6443" -Token (Read-Host -AsSecureString)
#>

param(
    [Parameter(Mandatory)]
    [string] $node,

    [Parameter(Mandatory)]
    [string] $user,

    [ValidateSet("server", "agent")]
    [string] $role = "server",

    [string] $k3sChannel = "stable",

    [string] $joinURL,

    [SecureString] $token,

    [string] $clusterCIDR = "10.42.0.0/16",

    [string] $serviceCIDR = "10.43.0.0/16",

    [switch] $disableTraefik,

    [switch] $disableServiceLB,

    [switch] $disableLocalPath
)

$ErrorActionPreference = "Stop"

if ($role -eq "agent" -and (-not $joinURL -or -not $token)) {
    throw "Agent nodes require -JoinURL and -Token parameters."
}

if ($role -eq "server" -and $joinURL -and -not $token) {
    throw "Joining server nodes require both -JoinURL and -Token parameters."
}

# Build k3s config.yaml content
$config = [ordered]@{}

if ($joinURL) {
    $config["server"] = $joinURL
}

if ($role -eq "server") {
    $config["write-kubeconfig-mode"] = "0644"
    $config["cluster-cidr"] = $clusterCIDR
    $config["service-cidr"] = $serviceCIDR
    $config["tls-san"] = @($node)
    $config["etcd-expose-metrics"] = $true
    $config["kube-controller-manager-arg"] = @("bind-address=0.0.0.0")
    $config["kube-scheduler-arg"] = @("bind-address=0.0.0.0")

    if (-not $joinURL) {
        $config["cluster-init"] = $true
    }

    $disableList = @()
    if ($disableLocalPath) { $disableList += "local-storage" }
    if ($disableServiceLB) { $disableList += "servicelb" }
    if ($disableTraefik) { $disableList += "traefik" }
    if ($disableList.Count -gt 0) {
        $config["disable"] = $disableList
    }
}

$config["protect-kernel-defaults"] = $true
$config["kubelet-arg"] = @("max-pods=110")

# Convert to YAML manually (simple key-value, avoid module dependency)
$yamlLines = @()
foreach ($key in $config.Keys) {
    $value = $config[$key]
    if ($value -is [bool]) {
        $yamlLines += "${key}: $($value.ToString().ToLower())"
    }
    elseif ($value -is [array]) {
        $yamlLines += "${key}:"
        foreach ($item in $value) {
            $yamlLines += "  - `"$item`""
        }
    }
    else {
        $yamlLines += "${key}: `"$value`""
    }
}
$configYaml = $yamlLines -join "`n"

Write-Host "--- Configuring k3s ($role) on $node ---" -ForegroundColor Cyan
Write-Host "Config:" -ForegroundColor DarkGray
Write-Host $configYaml -ForegroundColor DarkGray

# Upload config and install k3s
$remoteConfigDir = "/etc/rancher/k3s"
$sshTarget = "${user}@${node}"

Write-Host "`n--- Creating config directory ---" -ForegroundColor Cyan
ssh $sshTarget "sudo mkdir -p $remoteConfigDir"

Write-Host "--- Uploading config.yaml ---" -ForegroundColor Cyan
$configYaml | ssh $sshTarget "sudo tee ${remoteConfigDir}/config.yaml > /dev/null"

Write-Host "--- Setting secure permissions ---" -ForegroundColor Cyan
ssh $sshTarget "sudo chmod 600 ${remoteConfigDir}/config.yaml"

Write-Host "--- Installing k3s ($role) via official installer ---" -ForegroundColor Cyan
$installCmd = "curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=$k3sChannel"
if ($token) {
    $plainToken = ConvertFrom-SecureString -SecureString $token -AsPlainText
    $installCmd += " K3S_TOKEN='$plainToken'"
}
if ($role -eq "agent") {
    $installCmd += " sh -s - agent"
}
else {
    $installCmd += " sh -s - server"
}
ssh $sshTarget $installCmd

Write-Host "--- Waiting for k3s to be ready ---" -ForegroundColor Cyan
ssh $sshTarget "sudo k3s kubectl wait --for=condition=Ready node/$($node.Split('.')[0]) --timeout=120s 2>/dev/null || sleep 10"

if ($role -eq "server" -and -not $joinURL) {
    Write-Host "`n--- Retrieving cluster token ---" -ForegroundColor Cyan
    $clusterToken = ssh $sshTarget "sudo cat /var/lib/rancher/k3s/server/node-token"
    Write-Host "Cluster token: $clusterToken" -ForegroundColor Green
    Write-Host "Use this token with -JoinURL and -Token to add more nodes." -ForegroundColor Yellow

    Write-Host "`n--- Retrieving kubeconfig ---" -ForegroundColor Cyan
    Write-Host "Run: scp ${sshTarget}:/etc/rancher/k3s/k3s.yaml ~/.kube/config" -ForegroundColor Yellow
    Write-Host "Then: sed -i 's/127.0.0.1/$node/' ~/.kube/config" -ForegroundColor Yellow
}

Write-Host "`nk3s $role setup complete on $node." -ForegroundColor Green
