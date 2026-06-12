# seed_prompts.ps1
# Create/update the shared "/command" prompt presets in Open WebUI via API.
# Presets are made PUBLIC (read) so every user can type the command in chat.
#
# Required setup (same as refresh_wiki.ps1):
#   - OPENWEBUI_URL + OPENWEBUI_API_KEY as env vars, or in a .env file in the
#     project root (parent of scripts/). The API key must belong to an admin.
#
# Usage:
#   pwsh -File .\scripts\seed_prompts.ps1            # create or update all presets
#   pwsh -File .\scripts\seed_prompts.ps1 -WhatIf    # show what would change, no write

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

# Public read grant — Open WebUI treats principal user:"*" as "everyone"
$publicGrant = @(@{ principal_type = "user"; principal_id = "*"; permission = "read" })

# ── Preset definitions (edit freely; commands must be unique) ────────
# Most prompts end with ": " so the user appends the specific request after
# inserting the command in chat.
$presets = @(
    @{ command = "/riassumi";        name = "Riassumi documento";
       content = "Riassumi il documento o testo seguente in punti chiave (massimo 10 bullet), in italiano. Evidenzia date, importi e scadenze se presenti." }

    @{ command = "/estrai-fattura";  name = "Estrai dati fattura";
       content = "Dal documento allegato estrai in una tabella markdown: fornitore, numero fattura, data, imponibile, IVA, totale, scadenza, modalita di pagamento. Se un campo manca scrivi 'n.d.'." }

    @{ command = "/traduci-en";      name = "Traduci in inglese";
       content = "Traduci in inglese il testo seguente, mantenendo tono professionale e terminologia tecnica corretta. Testo: " }

    @{ command = "/normativa";       name = "Spiega normativa";
       content = "Spiega in modo pratico e sintetico cosa comporta, per un'azienda di cartotecnica, quanto segue. Indica adempimenti concreti e scadenze se rilevanti. Argomento/normativa: " }

    @{ command = "/scheda-tecnica";  name = "Scheda tecnica prodotto";
       content = "Genera una scheda tecnica per un prodotto cartotecnico con le sezioni: dimensioni, materiale e grammatura, lavorazioni/finiture, imballo, note di produzione. Prodotto: " }

    @{ command = "/punti-azione";    name = "Estrai punti d'azione";
       content = "Dal testo o verbale seguente estrai i punti d'azione in una tabella markdown con colonne: attivita, responsabile, scadenza. Testo: " }
)

# ── Fetch existing prompts → command→id map ─────────────────────────
Write-Host "Fetching existing prompts from $BaseUrl ..."
$existing = Invoke-RestMethod -Uri "$BaseUrl/api/v1/prompts/" -Headers $headers -Method GET
$byCommand = @{}
foreach ($p in $existing) { $byCommand[$p.command] = $p.id }

$created = 0; $updated = 0; $skipped = 0
foreach ($preset in $presets) {
    $cmd = $preset.command
    $body = @{
        command       = $cmd
        name          = $preset.name
        content       = $preset.content
        access_grants = $publicGrant
    } | ConvertTo-Json -Depth 6

    if ($byCommand.ContainsKey($cmd)) {
        $id = $byCommand[$cmd]
        if ($WhatIf) { Write-Host "WOULD UPDATE $cmd"; $skipped++; continue }
        try {
            Invoke-RestMethod -Uri "$BaseUrl/api/v1/prompts/id/$id/update" -Headers $headers -Method POST -Body $body | Out-Null
            Write-Host "UPDATED  $cmd"; $updated++
        } catch {
            Write-Warning "Update failed for ${cmd}: $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
        }
    } else {
        if ($WhatIf) { Write-Host "WOULD CREATE $cmd"; $skipped++; continue }
        try {
            Invoke-RestMethod -Uri "$BaseUrl/api/v1/prompts/create" -Headers $headers -Method POST -Body $body | Out-Null
            Write-Host "CREATED  $cmd"; $created++
        } catch {
            Write-Warning "Create failed for ${cmd}: $($_.Exception.Message)"
            if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message }
        }
    }
}

Write-Host ""
Write-Host "Done. created=$created updated=$updated skipped=$skipped  (total presets: $($presets.Count))"
Write-Host "Users can now type the commands (e.g. /riassumi) in any chat."
