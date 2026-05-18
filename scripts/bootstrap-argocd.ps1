#Requires -Version 7.0
<#
.SYNOPSIS
    Bootstraps Argo CD on a k3s cluster and applies the root app-of-apps.
.DESCRIPTION
    Prerequisites: kubectl configured with cluster access, helm v3.
    This script installs Argo CD via Helm, waits for readiness,
    then applies the root Application that manages all other apps.
.EXAMPLE
    pwsh ./scripts/bootstrap-argocd.ps1 -RepoURL "https://github.com/you/k3s-cluster.git"
#>

param(
    [string] $argocdVersion = "9.5.4",

    [string] $argocdNamespace = "argocd",

    [Parameter(Mandatory)]
    [string] $repoURL
)

$ErrorActionPreference = "Stop"

Write-Host "--- Adding Argo CD Helm repository ---" -ForegroundColor Cyan
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

Write-Host "--- Creating namespace $argocdNamespace ---" -ForegroundColor Cyan
kubectl create namespace $argocdNamespace --dry-run=client -o yaml | kubectl apply -f -

Write-Host "--- Installing Argo CD $argocdVersion ---" -ForegroundColor Cyan
helm upgrade --install argocd argo/argo-cd `
    --namespace $argocdNamespace `
    --version $argocdVersion `
    --values "$PSScriptRoot/../platform/argocd/values.yaml" `
    --wait --timeout 5m

Write-Host "--- Waiting for Argo CD server readiness ---" -ForegroundColor Cyan
kubectl wait --for=condition=available deployment/argocd-server `
    --namespace $argocdNamespace `
    --timeout=300s

$adminPassword = kubectl get secret argocd-initial-admin-secret `
    --namespace $argocdNamespace `
    -o jsonpath="{.data.password}" |
    ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }

Write-Host "`nArgo CD initial admin password: $adminPassword" -ForegroundColor Green
Write-Host "CHANGE THIS PASSWORD IMMEDIATELY after first login." -ForegroundColor Yellow

Write-Host "`n--- Applying root app-of-apps ---" -ForegroundColor Cyan

@"
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: $argocdNamespace
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: $repoURL
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: $argocdNamespace
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
"@ | kubectl apply -f -

Write-Host "`nBootstrap complete. Argo CD now manages all applications." -ForegroundColor Green
Write-Host "UI access: kubectl port-forward svc/argocd-server -n $argocdNamespace 8080:443" -ForegroundColor Cyan
