# seed_functions.ps1
# Install/update Open WebUI custom Functions from the functions/ folder via API,
# then activate them and make them global (so they apply to every model, including
# rewave-ai, with no per-model assignment — actions show a button, filters run
# automatically on each reply).
#
# Idempotent: safe to re-run on every redeploy (e.g. on the Ubuntu VM). It creates
# missing functions, refreshes the code of existing ones, and ensures is_active +
# is_global are set. New code is loaded live by Open WebUI; no restart required.
#
# Required setup (same as refresh_wiki.ps1):
#   - OPENWEBUI_URL + OPENWEBUI_API_KEY as env vars, or in a .env file in the
#     project root (parent of scripts/). The API key must belong to an admin.
#
# Usage:
#   pwsh -File .\scripts\seed_functions.ps1            # install/update + activate all
#   pwsh -File .\scripts\seed_functions.ps1 -WhatIf    # show what would change, no write

param(
    [string]$BaseUrl = $env:OPENWEBUI_URL,
    [string]$ApiKey  = $env:OPENWEBUI_API_KEY,
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# ── Load .env if present ────────────────────────────────────────────
$envFile = Join-Path $repoRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*(.+?)\s*$') {
            $k = $Matches[1]; $v = $Matches[2].Trim('"').Trim("'")
            if (-not $BaseUrl -and $k -eq "OPENWEBUI_URL")     { $BaseUrl = $v }
            if (-not $ApiKey  -and $k -eq "OPENWEBUI_API_KEY") { $ApiKey  = $v }
        }
    }
}
if (-not $BaseUrl) { $BaseUrl = "http://localhost:3000" }
if (-not $ApiKey) {
    Write-Error "OPENWEBUI_API_KEY missing. Set env var or add it to .env (admin key)."
    exit 1
}
$BaseUrl = $BaseUrl.TrimEnd('/')
$headers = @{ "Authorization" = "Bearer $ApiKey"; "Content-Type" = "application/json" }

# ── Function definitions ────────────────────────────────────────────
# id must be a valid Python identifier (letters/digits/underscore). It is the file
# stem; the source is read from functions/<id>.py. Add more entries as needed.
$functions = @(
    @{ id = "esporta_pdf"; name = "Presentazione PDF"; file = "functions\esporta_pdf.py";
       description = "Filter: quando una risposta contiene una presentazione reveal.js, genera il PDF e accoda il link di download al messaggio." }
)

# ── Fetch existing functions → id→{active,global} map ───────────────
Write-Host "Fetching existing functions from $BaseUrl ..."
$existing = Invoke-RestMethod -Uri "$BaseUrl/api/v1/functions/" -Headers $headers -Method GET
$byId = @{}
foreach ($f in $existing) { $byId[$f.id] = $f }

$created = 0; $updated = 0; $toggled = 0
foreach ($fn in $functions) {
    $id = $fn.id.ToLower()
    $srcPath = Join-Path $repoRoot $fn.file
    if (-not (Test-Path $srcPath)) { Write-Warning "Source not found: $srcPath"; continue }
    $content = Get-Content $srcPath -Raw

    $body = @{
        id      = $id
        name    = $fn.name
        content = $content
        meta    = @{ description = $fn.description; manifest = @{} }
    } | ConvertTo-Json -Depth 8

    # ── Create or update the code ───────────────────────────────────
    if ($byId.ContainsKey($id)) {
        if ($WhatIf) { Write-Host "WOULD UPDATE $id" }
        else {
            try {
                Invoke-RestMethod -Uri "$BaseUrl/api/v1/functions/id/$id/update" -Headers $headers -Method POST -Body $body | Out-Null
                Write-Host "UPDATED  $id"; $updated++
            } catch {
                Write-Warning "Update failed for ${id}: $($_.Exception.Message)"
                if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
                continue
            }
        }
    } else {
        if ($WhatIf) { Write-Host "WOULD CREATE $id" }
        else {
            try {
                Invoke-RestMethod -Uri "$BaseUrl/api/v1/functions/create" -Headers $headers -Method POST -Body $body | Out-Null
                Write-Host "CREATED  $id"; $created++
            } catch {
                Write-Warning "Create failed for ${id}: $($_.Exception.Message)"
                if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
                continue
            }
        }
    }

    # ── Ensure is_active + is_global = true (toggle endpoints flip) ──
    # Re-read current state (a freshly created function defaults to false/false).
    if ($WhatIf) {
        $cur = $byId[$id]
        $needA = (-not $cur) -or (-not $cur.is_active)
        $needG = (-not $cur) -or (-not $cur.is_global)
        if ($needA) { Write-Host "  WOULD ACTIVATE $id" }
        if ($needG) { Write-Host "  WOULD MAKE GLOBAL $id" }
        continue
    }
    $cur = Invoke-RestMethod -Uri "$BaseUrl/api/v1/functions/id/$id" -Headers $headers -Method GET
    if (-not $cur.is_active) {
        Invoke-RestMethod -Uri "$BaseUrl/api/v1/functions/id/$id/toggle" -Headers $headers -Method POST | Out-Null
        Write-Host "  ACTIVATED $id"; $toggled++
    }
    if (-not $cur.is_global) {
        Invoke-RestMethod -Uri "$BaseUrl/api/v1/functions/id/$id/toggle/global" -Headers $headers -Method POST | Out-Null
        Write-Host "  GLOBAL    $id"; $toggled++
    }
}

Write-Host ""
Write-Host "Done. created=$created updated=$updated toggled=$toggled  (total: $($functions.Count))"
Write-Host "Global functions apply to every model (incl. rewave-ai): actions show as a button, filters run automatically."
