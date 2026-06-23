# seed_model.ps1
# Create/refresh the `rewave-ai` model and everything around it via the Open WebUI
# API — so a fresh deploy needs no manual clicks in Admin → Models. Idempotent:
# safe to re-run on every redeploy. It does four things:
#
#   1. RouteLLM connection — adds http://routellm:6060/v1 as an OpenAI connection
#      with auth=none and a manual model_ids override (RouteLLM does not serve
#      /v1/models, so the router model id must be declared, not auto-discovered).
#      The LiteLLM connection is left untouched (it is seeded from env and
#      auto-discovers claude-sonnet/claude-haiku).
#   2. rewave-ai model — base model = the router, full system prompt (3-source
#      rules + empty wiki markers, filled later by refresh_wiki.ps1), params,
#      capabilities, default features (web search OFF as default — routing trap),
#      and the esporta_pdf action. Visibility = Public.
#   3. Visibility of the router targets — router model = Public (it is rewave-ai's
#      base, resolved with the user's permissions); claude-sonnet / claude-haiku /
#      gemma3-4b = Private (called server-side by RouteLLM via the master key).
#   4. Task Model = claude-haiku — background calls (chat title + tag generation,
#      follow-ups, search-query gen) run on the cheap model, not the router/Sonnet.
#
# The router model id carries the calibrated threshold (router-bert-<threshold>).
# It starts at router-bert-0.6 here; the value CAN CHANGE after recalibration —
# override with -RouterModelId and keep it in sync with the RouteLLM connection.
#
# Required setup (same as refresh_wiki.ps1 / seed_prompts.ps1 / seed_functions.ps1):
#   - OPENWEBUI_URL + OPENWEBUI_API_KEY as env vars, or in a .env file in the
#     project root (parent of scripts/). The API key must belong to an admin and
#     the API Key feature must be enabled (Admin → Settings → General, or
#     ENABLE_API_KEY=true in compose). This is the one irreducible manual step.
#
# Usage:
#   pwsh -File .\scripts\seed_model.ps1
#   pwsh -File .\scripts\seed_model.ps1 -RouterModelId "router-bert-0.45"
#   pwsh -File .\scripts\seed_model.ps1 -WhatIf      # show actions, write nothing
#   pwsh -File .\scripts\seed_model.ps1 -BaseUrl "https://oi.rewave.local" -ApiKey "sk-..."

param(
    [string]$BaseUrl       = $env:OPENWEBUI_URL,
    [string]$ApiKey        = $env:OPENWEBUI_API_KEY,
    [string]$ModelId       = "rewave-ai",
    [string]$ModelName     = "ReWave AI",
    [string]$RouterModelId = "router-bert-0.6",            # carries the threshold; can change
    [string]$RouterUrl     = "http://routellm:6060/v1",
    [string]$TaskModel     = "claude-haiku",
    [string[]]$PrivateTargets = @("claude-sonnet", "claude-haiku", "gemma3-4b"),
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

# ── Load .env if present (same loader as the other seed scripts) ────
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

function Invoke-Owui {
    param([string]$Method, [string]$Path, $Body)
    $uri = "$BaseUrl$Path"
    if ($Body -ne $null) {
        $json = ($Body | ConvertTo-Json -Depth 12)
        return Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method -Body $json
    }
    return Invoke-RestMethod -Uri $uri -Headers $headers -Method $Method
}

# Public = wildcard read grant (user:* read). Private = no grants (owner/admin only).
$PUBLIC_GRANTS  = @(@{ principal_type = "user"; principal_id = "*"; permission = "read" })
$PRIVATE_GRANTS = @()

# ── System prompt: 3-source rules + EMPTY wiki markers ──────────────
# refresh_wiki.ps1 injects the bundle between the markers afterwards. This block is
# the canonical source of the rewave-ai instruction prompt (keep DEPLOY.md in sync).
$systemPrompt = @'
Sei assistente Rewave Srl (cartotecnica, italiano).

Hai 3 fonti info in ordine priorità:

1. WIKI REWAVE (sotto, tra marker BEGIN/END WIKI): conoscenza interna autoritativa su clienti, prodotti, decisioni, mercato. Cita con [[slug-pagina]] solo se slug esiste in sezione index.md del bundle.

2. WEB SEARCH RESULTS: se nel contesto della chat appaiono risultati di ricerca web (snippet con URL, iniettati automaticamente dal sistema), usali per rispondere e cita URL. Non chiedere mai all'utente di "attivare web search" — se risultati ci sono, sono già lì; se non ci sono, rispondi con wiki + general knowledge.

3. GENERAL KNOWLEDGE: domande tech generiche, concetti, how-to → rispondi normale senza forzare wiki.

Regole:
- Info in wiki → cita wiki, non duplicare con web.
- Wiki dice "unclear" o manca dato → dichiara "non in wiki" poi rispondi con web results (se presenti) o general knowledge.
- Mai inventare slug wiki.
- Mai chiedere all'utente di abilitare funzionalità — usa ciò che hai in contesto.
- Lingua: italiano default.
- Se domanda totalmente fuori dominio Rewave → rispondi normale general purpose, ignora wiki.


=====BEGIN WIKI=====
=====END WIKI=====
'@

# ── Model meta/params (mirror of the live rewave-ai config) ─────────
$modelMeta = @{
    profile_image_url = "/static/favicon.png"
    description       = "Assistente aziendale ReWave"
    capabilities      = @{
        file_context = $true; vision = $true; file_upload = $true; web_search = $true
        image_generation = $false; code_interpreter = $false; terminal = $false
        citations = $true; status_updates = $true; usage = $false; builtin_tools = $true
    }
    suggestion_prompts = $null
    tags               = @()
    # Default Features: all OFF. web_search MUST stay false here (a default web-search
    # feature wraps every message in a context template → RouteLLM routes all to Sonnet).
    builtinTools = @{
        calendar = $false; automations = $false; tasks = $false; memory = $false
        chats = $false; notes = $false; channels = $false; image_generation = $false
        code_interpreter = $false; knowledge = $false; web_search = $false
    }
    actionIds = @("esporta_pdf")   # esporta_pdf is also global via seed_functions; harmless to list
}
$modelParams = @{ system = $systemPrompt; temperature = 0.2; max_tokens = 4096 }

Write-Host "Target: $BaseUrl   model=$ModelId   router=$RouterModelId   task=$TaskModel"
Write-Host ""

# ════════════════════════════════════════════════════════════════════
# 1. RouteLLM connection (idempotent)
# ════════════════════════════════════════════════════════════════════
Write-Host "[1/4] OpenAI connections — ensuring RouteLLM ($RouterUrl) with model_ids=[$RouterModelId] ..."
$cfg = Invoke-Owui GET "/openai/config"
$urls    = @($cfg.OPENAI_API_BASE_URLS)
$keys    = @($cfg.OPENAI_API_KEYS)
$configs = @{}
if ($cfg.OPENAI_API_CONFIGS) {
    $cfg.OPENAI_API_CONFIGS.PSObject.Properties | ForEach-Object { $configs[$_.Name] = $_.Value }
}

$idx = [Array]::IndexOf($urls, $RouterUrl)
if ($idx -lt 0) {
    $urls += $RouterUrl
    $keys += ""                       # auth=none → empty key
    $idx = $urls.Count - 1
    Write-Host "  + added connection at index $idx"
} else {
    while ($keys.Count -lt $urls.Count) { $keys += "" }
    Write-Host "  = connection already present at index $idx"
}
$configs["$idx"] = @{
    enable = $true; tags = @(); prefix_id = ""
    model_ids = @($RouterModelId); connection_type = "external"; auth_type = "none"
}

$openaiBody = @{
    ENABLE_OPENAI_API    = $true
    OPENAI_API_BASE_URLS = $urls
    OPENAI_API_KEYS      = $keys
    OPENAI_API_CONFIGS   = $configs
}
if ($WhatIf) { Write-Host "  WOULD POST /openai/config/update (urls=$($urls -join ','))" }
else { Invoke-Owui POST "/openai/config/update" $openaiBody | Out-Null; Write-Host "  updated." }

# ════════════════════════════════════════════════════════════════════
# 2. rewave-ai model (create or update) — Public
# ════════════════════════════════════════════════════════════════════
Write-Host "[2/4] Model '$ModelId' (base=$RouterModelId) ..."
$exists = $false
try { Invoke-Owui GET "/api/v1/models/model?id=$ModelId" | Out-Null; $exists = $true } catch { $exists = $false }

$modelBody = @{
    id            = $ModelId
    base_model_id = $RouterModelId
    name          = $ModelName
    meta          = $modelMeta
    params        = $modelParams
    access_grants = $PUBLIC_GRANTS
    is_active     = $true
}
if ($WhatIf) {
    Write-Host ("  WOULD {0} {1} (Public)" -f ($(if ($exists) {"UPDATE"} else {"CREATE"}), $ModelId))
} else {
    if ($exists) { Invoke-Owui POST "/api/v1/models/model/update" $modelBody | Out-Null; Write-Host "  UPDATED (Public)." }
    else         { Invoke-Owui POST "/api/v1/models/create"       $modelBody | Out-Null; Write-Host "  CREATED (Public)." }
}

# ════════════════════════════════════════════════════════════════════
# 3. Visibility — router Public, targets Private
# ════════════════════════════════════════════════════════════════════
Write-Host "[3/4] Visibility ..."
function Set-Access {
    param([string]$Id, [array]$Grants, [string]$Label)
    $body = @{ id = $Id; access_grants = $Grants }
    if ($WhatIf) { Write-Host "  WOULD set $Id -> $Label"; return }
    try { Invoke-Owui POST "/api/v1/models/model/access/update" $body | Out-Null; Write-Host "  $Id -> $Label" }
    catch { Write-Warning "  access update failed for ${Id}: $($_.Exception.Message)" }
}
Set-Access -Id $RouterModelId -Grants $PUBLIC_GRANTS  -Label "Public (rewave-ai base model)"
foreach ($t in $PrivateTargets) { Set-Access -Id $t -Grants $PRIVATE_GRANTS -Label "Private (router target)" }

# ════════════════════════════════════════════════════════════════════
# 4. Task Model = cheap model (titles, tags, follow-ups) — GET-merge-POST
# ════════════════════════════════════════════════════════════════════
Write-Host "[4/4] Task Model = $TaskModel (titles/tags/follow-ups/query gen) ..."
$task = Invoke-Owui GET "/api/v1/tasks/config"
$taskBody = @{}
$task.PSObject.Properties | ForEach-Object { $taskBody[$_.Name] = $_.Value }
$taskBody["TASK_MODEL"]          = $TaskModel
$taskBody["TASK_MODEL_EXTERNAL"] = $TaskModel
if ($WhatIf) { Write-Host "  WOULD POST /api/v1/tasks/config/update (TASK_MODEL=$TaskModel)" }
else { Invoke-Owui POST "/api/v1/tasks/config/update" $taskBody | Out-Null; Write-Host "  pinned." }

Write-Host ""
Write-Host "Done. Next: push the wiki bundle into the empty markers:"
Write-Host "  pwsh -File .\scripts\refresh_wiki.ps1 -BaseUrl `"$BaseUrl`" -ApiKey `"sk-...`" -ModelId `"$ModelId`""
if ($RouterModelId -ne "router-bert-0.6") {
    Write-Host "NOTE: router model id is $RouterModelId — make sure the RouteLLM threshold matches."
}
