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
# Listed in creation order (oldest first), so the source shows which preset was
# added first and which last. Display order in the chat "/" menu is independent
# (Open WebUI sorts it by last-updated) and not managed here.
# Prompts that take pasted text as input end with a label + newline (`n) so the
# user types the text on a fresh line below the inserted command.
$presets = @(
    @{ command = "/riassumi";        name = "Riassumi documento";
       content = "Riassumi il documento o testo seguente in punti chiave (massimo 10 bullet), in italiano. Evidenzia date, importi e scadenze se presenti.`n" }

    @{ command = "/estrai-fattura";  name = "Estrai dati fattura";
       content = "Dal documento allegato estrai in una tabella markdown: fornitore, numero fattura, data, imponibile, IVA, totale, scadenza, modalita di pagamento. Se un campo manca scrivi 'n.d.'." }

    @{ command = "/traduci-en";      name = "Traduci in inglese";
       content = "Traduci in inglese il testo seguente, mantenendo tono professionale e terminologia tecnica corretta. Testo:`n" }

    @{ command = "/normativa";       name = "Spiega normativa";
       content = "Spiega in modo pratico e sintetico cosa comporta quanto segue. Indica adempimenti concreti e scadenze se rilevanti. Argomento/normativa:`n" }

    @{ command = "/presentazione";   name = "Crea presentazione";
       content = @'
Crea una presentazione a partire dai dati seguenti. Produci UN SOLO documento HTML completo e autonomo basato su reveal.js, racchiuso in un blocco di codice fenced con linguaggio html (tre backtick seguiti da html), cosi che Open WebUI lo mostri come Artifact interattivo.

Requisiti:
- Carica reveal.js da CDN jsDelivr: CSS https://cdn.jsdelivr.net/npm/reveal.js@5/dist/reveal.css, tema https://cdn.jsdelivr.net/npm/reveal.js@5/dist/theme/white.css, e script https://cdn.jsdelivr.net/npm/reveal.js@5/dist/reveal.js; poi inizializza con: new Reveal().initialize();
- Struttura: una slide titolo (titolo + sottotitolo + "Rewave Srl" e data), poi una slide per ogni argomento/sezione, infine una slide di chiusura.
- Ogni slide e un elemento <section> dentro <div class="slides"> dentro <div class="reveal">. Usa bullet brevi (max ~6 per slide), grassetto per i numeri chiave, tabelle HTML solo dove i dati lo richiedono.
- Lingua italiana, tono professionale e sintetico. Niente testo fuori dal blocco HTML, niente spiegazioni.
- Palette sobria e leggibile, adatta a un contesto aziendale professionale.

Dati per la presentazione:

'@ }

    @{ command = "/traduci-it";      name = "Traduci in italiano";
       content = "Traduci in italiano il testo seguente in modo corretto e naturale, qualunque sia la lingua di partenza. Mantieni tono professionale e terminologia tecnica corretta. Testo:`n" }
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
