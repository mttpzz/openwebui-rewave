# provision_user_pc.ps1
# Configure a Windows user PC to access Open WebUI over HTTPS with SSO.
# Run ONCE per PC, from an ELEVATED PowerShell (Administrator).
#
# What it does (both steps are idempotent — safe to re-run):
#   1. Adds / updates *.rewave.local → server IP entries in the Windows hosts file.
#      Existing entries with a different IP are updated in-place.
#   2. Installs the Caddy internal CA certificate into the Windows Trusted Root
#      Certification Authorities store so Chrome / Edge trust the HTTPS cert without
#      warnings. Skipped if the same cert (by thumbprint) is already installed.
#      Replaces any older Caddy CA cert with the same subject (handles CA regeneration).
#
# Firefox note: Firefox ignores the Windows cert store by default and will still
# show a warning. Either set security.enterprise_roots.enabled = true in about:config
# (per user), or push it via a policies.json under the Firefox install dir (admin).
# See: https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox
#
# Distribution: share this script alongside caddy-root.crt (from caddy/ in the repo).
# Default cert path = ../caddy/caddy-root.crt relative to this script; override with -CertPath.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\scripts\provision_user_pc.ps1 -ServerIP 192.168.1.100
#   powershell -ExecutionPolicy Bypass -File .\scripts\provision_user_pc.ps1 -ServerIP 192.168.1.100 -CertPath .\caddy-root.crt
#   powershell -ExecutionPolicy Bypass -File .\scripts\provision_user_pc.ps1 -ServerIP 192.168.1.100 -Uninstall

param(
    [string]$ServerIP,
    [string]$CertPath,
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

# ── Elevation check ─────────────────────────────────────────────────
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "Run this script from an ELEVATED PowerShell (right-click → Run as Administrator)."
    exit 1
}

# ── Defaults ────────────────────────────────────────────────────────
if (-not $CertPath) {
    $CertPath = Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..")).Path "caddy\caddy-root.crt"
}
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$Hostnames = @(
    "oi.rewave.local",
    "keycloak.rewave.local",
    "litellm.rewave.local"
)

# ══════════════════════════════════════════════════════════════════════
# UNINSTALL
# ══════════════════════════════════════════════════════════════════════
if ($Uninstall) {
    Write-Host "== Removing Open WebUI client configuration =="

    $lines = Get-Content $HostsFile
    $filtered = $lines | Where-Object { $_ -notmatch 'rewave\.local' }
    Set-Content -Path $HostsFile -Value $filtered -Encoding UTF8
    Write-Host "Removed *.rewave.local entries from hosts file."

    $removed = 0
    Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -match "Caddy" } | ForEach-Object {
        Remove-Item $_.PSPath -Force
        Write-Host "Removed cert: $($_.Subject) [$($_.Thumbprint)]"
        $removed++
    }
    if ($removed -eq 0) { Write-Host "No Caddy CA cert found in Trusted Root store." }

    Write-Host "Done. Restart the browser to apply cert changes."
    exit 0
}

# ══════════════════════════════════════════════════════════════════════
# INSTALL
# ══════════════════════════════════════════════════════════════════════
if (-not $ServerIP) {
    Write-Error "ServerIP is required.`nUsage: provision_user_pc.ps1 -ServerIP <ip>"
    exit 1
}
if ($ServerIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
    Write-Error "ServerIP '$ServerIP' does not look like a valid IPv4 address."
    exit 1
}

Write-Host "== Configuring PC for Open WebUI =="
Write-Host "   Server IP : $ServerIP"
Write-Host "   Cert path : $CertPath"
Write-Host ""

# ── 1. Hosts file ───────────────────────────────────────────────────
Write-Host "[1/2] Updating hosts file..."

$lines = [System.Collections.Generic.List[string]](Get-Content $HostsFile)
foreach ($hostname in $Hostnames) {
    $pattern = "(?i)\s" + [regex]::Escape($hostname) + "(\s|$)"
    $existingIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $existingIdx = $i; break }
    }
    $newLine = "$ServerIP`t$hostname"
    if ($existingIdx -ge 0) {
        if ($lines[$existingIdx] -match "^$([regex]::Escape($ServerIP))\s") {
            Write-Host "  = already set: $hostname → $ServerIP"
        } else {
            $lines[$existingIdx] = $newLine
            Write-Host "  ~ updated:     $hostname → $ServerIP"
        }
    } else {
        $lines.Add($newLine)
        Write-Host "  + added:       $hostname → $ServerIP"
    }
}
Set-Content -Path $HostsFile -Value $lines -Encoding UTF8

# Quick verify
foreach ($hostname in @("oi.rewave.local", "keycloak.rewave.local")) {
    try {
        $resolved = [System.Net.Dns]::GetHostAddresses($hostname)[0].IPAddressToString
        if ($resolved -eq $ServerIP) { Write-Host "  OK resolved $hostname → $resolved" }
        else { Write-Warning "  $hostname resolved to $resolved (expected $ServerIP) — DNS may be overriding hosts file" }
    } catch { Write-Warning "  Could not resolve ${hostname}: $($_.Exception.Message)" }
}

# ── 2. Caddy CA certificate ─────────────────────────────────────────
Write-Host ""
Write-Host "[2/2] Installing Caddy CA certificate into Windows Trusted Root store..."

if (-not (Test-Path $CertPath)) {
    Write-Error "Cert file not found: $CertPath`nCopy caddy-root.crt from the server (see DEPLOY.md Phase 6) or pass -CertPath."
    exit 1
}

$cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CertPath

$existing = Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Thumbprint -eq $cert.Thumbprint }
if ($existing) {
    Write-Host "  = cert already installed (thumbprint $($cert.Thumbprint))"
} else {
    # Remove outdated Caddy CA certs (same subject = CA was regenerated)
    Get-ChildItem Cert:\LocalMachine\Root | Where-Object { $_.Subject -eq $cert.Subject } | ForEach-Object {
        Remove-Item $_.PSPath -Force
        Write-Host "  ~ removed outdated cert [$($_.Thumbprint)]"
    }
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $store.Open("ReadWrite")
    $store.Add($cert)
    $store.Close()
    Write-Host "  + installed (thumbprint $($cert.Thumbprint))"
    Write-Host "    Subject : $($cert.Subject)"
    Write-Host "    Expires : $($cert.NotAfter.ToString('yyyy-MM-dd'))"
}

Write-Host ""
Write-Host "Done. Open https://oi.rewave.local in Chrome or Edge — no certificate warning should appear."
Write-Host ""
Write-Host "Firefox: uses its own cert store — will still show a warning unless you either:"
Write-Host "  A) about:config → security.enterprise_roots.enabled = true  (per user)"
Write-Host "  B) deploy a policies.json under the Firefox install dir      (admin, machine-wide)"
Write-Host "  See: https://support.mozilla.org/en-US/kb/setting-certificate-authorities-firefox"
