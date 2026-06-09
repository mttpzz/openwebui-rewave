# refresh_wiki.ps1
# Regenerate the wiki bundle and update the Custom Model System Prompt in Open-WebUI via API.
#
# Required setup:
#   1. Create an API key in Open-WebUI: Settings → Account → API Keys → "+"
#   2. Save env vars (once):
#        $env:OPENWEBUI_URL = "http://localhost:3000"
#        $env:OPENWEBUI_API_KEY = "sk-..."
#        $env:OPENWEBUI_MODEL_ID = "rewave-ai"
#      Or use a .env file in the project root (parent of scripts/) with KEY=VALUE lines.
#
# Usage:
#   pwsh -File .\refresh_wiki.ps1
#   pwsh -File .\refresh_wiki.ps1 -SkipBundle   # if bundle already generated

param(
    [switch]$SkipBundle,
    [string]$ModelId = $env:OPENWEBUI_MODEL_ID,
    [string]$BaseUrl = $env:OPENWEBUI_URL,
    [string]$ApiKey  = $env:OPENWEBUI_API_KEY
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# ── Load .env if it exists ──────────────────────────────────────────
$envFile = Join-Path $repoRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([^#=]+?)\s*=\s*(.+?)\s*$') {
            $k = $Matches[1]
            $v = $Matches[2].Trim('"').Trim("'")
            Set-Item -Path "env:$k" -Value $v
            if (-not $ModelId -and $k -eq "OPENWEBUI_MODEL_ID") { $ModelId = $v }
            if (-not $BaseUrl -and $k -eq "OPENWEBUI_URL")      { $BaseUrl = $v }
            if (-not $ApiKey  -and $k -eq "OPENWEBUI_API_KEY")  { $ApiKey  = $v }
        }
    }
}

# Defaults
if (-not $ModelId) { $ModelId = "rewave-ai" }
if (-not $BaseUrl) { $BaseUrl = "http://localhost:3000" }
if (-not $ApiKey) {
    Write-Error "OPENWEBUI_API_KEY missing. Set env var or create .env with OPENWEBUI_API_KEY=sk-..."
    exit 1
}

$BaseUrl = $BaseUrl.TrimEnd('/')
$BEGIN_MARK = "=====BEGIN WIKI====="
$END_MARK   = "=====END WIKI====="

# ── Step 1: regenerate bundle ──────────────────────────────────────
$bundlePath = Join-Path $repoRoot "llm_wiki\_bundle.md"

if (-not $SkipBundle) {
    Write-Host "[1/4] Regenerating bundle..."
    & (Join-Path $PSScriptRoot "bundle_wiki.ps1")
    # bundle_wiki.ps1 has $ErrorActionPreference=Stop, exceptions propagate automatically
}

if (-not (Test-Path $bundlePath)) {
    throw "Bundle not found: $bundlePath"
}

$bundleContent = Get-Content -LiteralPath $bundlePath -Raw -Encoding utf8
Write-Host "[1/4] Bundle: $($bundleContent.Length) chars"

# ── Step 2: GET current model ───────────────────────────────────────
Write-Host "[2/4] GET model $ModelId ..."

$headers = @{
    "Authorization" = "Bearer $ApiKey"
    "Content-Type"  = "application/json"
}

try {
    $getUrl = "$BaseUrl/api/v1/models/model?id=$ModelId"
    $model = Invoke-RestMethod -Uri $getUrl -Headers $headers -Method GET
} catch {
    Write-Error "GET failed: $($_.Exception.Message)"
    Write-Host "Check: BaseUrl=$BaseUrl, ModelId=$ModelId, API key valid"
    exit 1
}

if (-not $model) { throw "Model $ModelId not found" }

# ── Step 3: replace wiki block in the system prompt ────────────────
Write-Host "[3/4] Updating system prompt..."

$currentSystem = $model.params.system
if (-not $currentSystem) { $currentSystem = "" }

$pattern = "(?s)" + [regex]::Escape($BEGIN_MARK) + ".*?" + [regex]::Escape($END_MARK)
$replacement = "$BEGIN_MARK`n`n$bundleContent`n`n$END_MARK"

if ($currentSystem -match $pattern) {
    $newSystem = [regex]::Replace($currentSystem, $pattern, { param($m) $replacement })
    Write-Host "      Existing wiki block replaced"
} else {
    # First run or markers lost: append wiki block at the end
    $newSystem = $currentSystem.TrimEnd() + "`n`n" + $replacement
    Write-Warning "Markers $BEGIN_MARK / $END_MARK not found in existing system prompt. Appended at the end."
}

$model.params.system = $newSystem

# ── Step 4: POST update ─────────────────────────────────────────────
Write-Host "[4/4] PATCH model..."

$updateUrl = "$BaseUrl/api/v1/models/model/update?id=$ModelId"
$body = $model | ConvertTo-Json -Depth 20 -Compress

try {
    $result = Invoke-RestMethod -Uri $updateUrl -Headers $headers -Method POST -Body $body
} catch {
    Write-Error "Update failed: $($_.Exception.Message)"
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
    exit 1
}

Write-Host ""
Write-Host "✓ Model $ModelId updated"
Write-Host "  System prompt: $($newSystem.Length) chars"
Write-Host "  Open-WebUI:    $BaseUrl"
