# seed_suggestions.ps1
# Set the new-chat "Suggerito" prompt suggestion cards in Open WebUI via API.
# These are a global admin config (PersistentConfig), NOT per-model. The env var
# DEFAULT_PROMPT_SUGGESTIONS in docker-compose.yml only seeds a FRESH DB; on an
# already-initialised DB it is ignored, so use this script to overwrite them.
#
# Required setup (same as refresh_wiki.ps1 / seed_prompts.ps1):
#   - OPENWEBUI_URL + OPENWEBUI_API_KEY as env vars, or in a .env file in the
#     project root (parent of scripts/). The API key must belong to an admin.
#
# Usage:
#   pwsh -File .\scripts\seed_suggestions.ps1            # overwrite suggestions
#   pwsh -File .\scripts\seed_suggestions.ps1 -WhatIf    # show payload, no write

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

# ── Suggestion cards (edit freely) ──────────────────────────────────
# title is a 2-line array [riga1, riga2]; content is prefilled into the input box.
$suggestions = @(
    @{ title = @("Cosa sai fare?", "scopri le funzioni");
       content = "Cosa sai fare? Elenca in modo sintetico come puoi aiutarmi nel lavoro quotidiano in Rewave." }

    @{ title = @("Genera presentazione", "esempio presentazione");
       content = "/presentazione Genera una presentazione di esempio in 4 slide che illustra i servizi di Rewave Srl." }
)

$body = @{ suggestions = $suggestions } | ConvertTo-Json -Depth 6

if ($WhatIf) {
    Write-Host "WOULD POST to $BaseUrl/api/v1/configs/suggestions :"
    Write-Host $body
    exit 0
}

Write-Host "Setting prompt suggestions on $BaseUrl ..."
try {
    $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/configs/suggestions" -Headers $headers -Method POST -Body $body
    Write-Host "OK. $($suggestions.Count) suggestion card(s) set."
} catch {
    Write-Warning "Failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    exit 1
}
