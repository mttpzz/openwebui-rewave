# sync_documenti.ps1
# Sync local folders into Open WebUI Knowledge Bases (RAG) via API.
#
# Each local folder is mirrored into one KB: files are uploaded (text extracted by
# docling, OCR included), added to the KB, embedded and indexed. The KBs are NOT
# attached to any model: users pull a KB into a chat on demand by typing #kbname
# (e.g. "#fatture qual e' il totale della fattura X?"), which keeps per-KB access
# permissions enforced. Set each KB's access control in the UI (Knowledge > Access).
#
# Reusable: to mirror another folder into another KB, just add a path and a KB name
# to the .env lists (positional pairing — first path -> first KB, etc.):
#
#     SYNC_FOLDERS=C:\Users\Matteo\Downloads\fatture;C:\altra\cartella
#     SYNC_KB_NAMES=fatture;altra-kb
#
# Incremental: a per-KB state file under .sync_state/ maps each local file (by
# relative path) to its uploaded file_id + content hash. Re-runs only upload new
# files, re-upload changed ones (old copy removed first), and remove files deleted
# locally. Unchanged files are skipped.
#
# Required setup (same as the other scripts):
#   - OPENWEBUI_URL + OPENWEBUI_API_KEY as env vars, or in a .env file in the
#     project root (parent of scripts/). The API key must belong to an admin.
#   - SYNC_FOLDERS + SYNC_KB_NAMES in .env (see above).
#
# Usage:
#   pwsh -File .\scripts\sync_documenti.ps1            # sync all configured pairs
#   pwsh -File .\scripts\sync_documenti.ps1 -WhatIf    # show what would change, no write
#   pwsh -File .\scripts\sync_documenti.ps1 -Full      # ignore state, re-evaluate every file
#   pwsh -File .\scripts\sync_documenti.ps1 -Only fatture   # sync just the KB named "fatture"

param(
    [string]$BaseUrl = $env:OPENWEBUI_URL,
    [string]$ApiKey  = $env:OPENWEBUI_API_KEY,
    [string]$Folders = $env:SYNC_FOLDERS,
    [string]$KbNames = $env:SYNC_KB_NAMES,
    [string]$Only,
    [switch]$Full,
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
            if (-not $Folders -and $k -eq "SYNC_FOLDERS")      { $Folders = $v }
            if (-not $KbNames -and $k -eq "SYNC_KB_NAMES")     { $KbNames = $v }
        }
    }
}
if (-not $BaseUrl) { $BaseUrl = "http://localhost:3000" }
if (-not $ApiKey)  { Write-Error "OPENWEBUI_API_KEY missing. Set env var or add it to .env (admin key)."; exit 1 }
if (-not $Folders) { Write-Error "SYNC_FOLDERS missing. Add it to .env, e.g. SYNC_FOLDERS=C:\path\fatture"; exit 1 }
if (-not $KbNames) { Write-Error "SYNC_KB_NAMES missing. Add it to .env, e.g. SYNC_KB_NAMES=fatture"; exit 1 }
$BaseUrl = $BaseUrl.TrimEnd('/')

# Extensions docling / Open WebUI can extract (PDF incl. scanned via OCR, Office, text).
# Override with SYNC_EXTENSIONS in .env (comma-separated, no dots) if needed.
$extCsv = $env:SYNC_EXTENSIONS
if (-not $extCsv) { $extCsv = "pdf,docx,doc,xlsx,xls,pptx,ppt,rtf,odt,ods,odp,txt,md,csv,html,json,png,jpg,jpeg,tiff,tif,bmp" }
$allowedExt = @{}
foreach ($e in $extCsv.Split(',')) { $allowedExt[$e.Trim().TrimStart('.').ToLower()] = $true }

# ── Pair folders <-> KB names by position ───────────────────────────
$folderList = @($Folders.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$kbList     = @($KbNames.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($folderList.Count -ne $kbList.Count) {
    Write-Error "SYNC_FOLDERS ($($folderList.Count)) and SYNC_KB_NAMES ($($kbList.Count)) have different lengths. They pair by position; counts must match."
    exit 1
}

$hAuth = @{ Authorization = "Bearer $ApiKey" }
$hJson = @{ Authorization = "Bearer $ApiKey"; "Content-Type" = "application/json" }
$stateDir = Join-Path $repoRoot ".sync_state"
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }

# ── Helpers ─────────────────────────────────────────────────────────
function Get-KbByName([string]$name) {
    $resp = Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/" -Headers $hAuth -Method GET
    return $resp.items | Where-Object { $_.name -eq $name } | Select-Object -First 1
}
function Sanitize([string]$s) { return ($s -replace '[^A-Za-z0-9_.-]', '_') }

# ── Per-pair sync ───────────────────────────────────────────────────
$grandNew = 0; $grandUpd = 0; $grandDel = 0; $grandSkip = 0; $grandErr = 0

for ($i = 0; $i -lt $folderList.Count; $i++) {
    $folder = $folderList[$i]
    $kbName = $kbList[$i]
    if ($Only -and $kbName -ne $Only) { continue }

    Write-Host ""
    Write-Host "==== [$($i+1)/$($folderList.Count)] folder '$folder'  ->  KB '$kbName' ===="

    if (-not (Test-Path -LiteralPath $folder)) { Write-Warning "Folder not found, skipping: $folder"; continue }

    # Resolve / create KB
    $kb = Get-KbByName $kbName
    if (-not $kb) {
        if ($WhatIf) { Write-Host "WOULD CREATE KB '$kbName'"; }
        else {
            $body = @{ name = $kbName; description = "Sync da $folder (sync_documenti.ps1)" } | ConvertTo-Json
            $kb = Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/create" -Headers $hJson -Method POST -Body $body
            Write-Host "CREATED KB '$kbName' (id=$($kb.id))"
        }
    }
    $kbId = if ($kb) { $kb.id } else { $null }

    # Load state: relpath -> @{ file_id; hash }
    $stateFile = Join-Path $stateDir ("{0}.json" -f (Sanitize $kbName))
    $state = @{}
    if ((Test-Path $stateFile) -and -not $Full) {
        $raw = Get-Content $stateFile -Raw | ConvertFrom-Json
        foreach ($p in $raw.PSObject.Properties) { $state[$p.Name] = @{ file_id = $p.Value.file_id; hash = $p.Value.hash } }
    }

    # NOTE: we deliberately do NOT reconcile against the live KB. In Open WebUI
    # v0.9.6 GET /knowledge/{id} returns files=null, so it can't be trusted to list
    # KB membership. We trust the local state file instead. If the state is lost,
    # re-running will hit "Duplicate content detected" for files already in the KB
    # (harmless: the stray upload is deleted, nothing in the KB is touched) — to
    # rebuild from scratch, empty the KB then sync again.

    # Enumerate local files (filtered by extension)
    $localFiles = Get-ChildItem -LiteralPath $folder -Recurse -File | Where-Object {
        $allowedExt.ContainsKey($_.Extension.TrimStart('.').ToLower())
    }

    $newState = @{}
    $nNew = 0; $nUpd = 0; $nSkip = 0; $nErr = 0
    $seen = @{}

    foreach ($file in $localFiles) {
        $rel = $file.FullName.Substring($folder.Length).TrimStart('\', '/')
        $seen[$rel] = $true
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash

        $prev = $state[$rel]
        if ($prev -and $prev.hash -eq $hash) {
            $newState[$rel] = $prev; $nSkip++; continue          # unchanged
        }

        $action = if ($prev) { "UPDATE" } else { "NEW   " }
        if ($WhatIf) { Write-Host "  WOULD $action $rel"; if ($prev) { $nUpd++ } else { $nNew++ }; if ($prev) { $newState[$rel] = $prev }; continue }

        try {
            # On update, remove the old copy first (file/remove also deletes the underlying file).
            if ($prev) {
                $rb = @{ file_id = $prev.file_id } | ConvertTo-Json
                try { Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/$kbId/file/remove" -Headers $hJson -Method POST -Body $rb | Out-Null } catch {}
            }

            # Upload synchronously so extraction is done before we add to the KB.
            $up = Invoke-RestMethod -Uri "$BaseUrl/api/v1/files/?process_in_background=false" -Headers $hAuth -Method POST -Form @{ file = Get-Item -LiteralPath $file.FullName } -TimeoutSec 600
            $fid = $up.id

            # Add to the KB (embeds + indexes). Fails if extraction produced no text.
            $ab = @{ file_id = $fid } | ConvertTo-Json
            try {
                Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/$kbId/file/add" -Headers $hJson -Method POST -Body $ab | Out-Null
            } catch {
                # e.g. "content empty" for an unreadable/blank file: drop the stray upload, skip.
                try { Invoke-RestMethod -Uri "$BaseUrl/api/v1/files/$fid" -Headers $hAuth -Method DELETE | Out-Null } catch {}
                throw
            }

            $newState[$rel] = @{ file_id = $fid; hash = $hash }
            if ($prev) { Write-Host "  UPDATED $rel"; $nUpd++ } else { Write-Host "  ADDED   $rel"; $nNew++ }
        } catch {
            $msg = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
            Write-Warning "  FAILED  $rel -> $msg"
            $nErr++
        }
    }

    # Files removed locally -> remove from KB (also deletes the underlying file)
    $nDel = 0
    foreach ($rel in @($state.Keys)) {
        if (-not $seen.ContainsKey($rel)) {
            if ($WhatIf) { Write-Host "  WOULD DELETE $rel"; $nDel++; continue }
            try {
                $rb = @{ file_id = $state[$rel].file_id } | ConvertTo-Json
                Invoke-RestMethod -Uri "$BaseUrl/api/v1/knowledge/$kbId/file/remove" -Headers $hJson -Method POST -Body $rb | Out-Null
                Write-Host "  DELETED $rel"; $nDel++
            } catch { Write-Warning "  delete failed for ${rel}: $($_.Exception.Message)"; $nErr++ }
        }
    }

    # Persist state (skip on WhatIf)
    if (-not $WhatIf) {
        ($newState | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $stateFile -Encoding utf8
    }

    Write-Host "  -- '$kbName': new=$nNew updated=$nUpd deleted=$nDel skipped=$nSkip errors=$nErr (local files: $($localFiles.Count))"
    $grandNew += $nNew; $grandUpd += $nUpd; $grandDel += $nDel; $grandSkip += $nSkip; $grandErr += $nErr
}

Write-Host ""
Write-Host "==== DONE  new=$grandNew updated=$grandUpd deleted=$grandDel skipped=$grandSkip errors=$grandErr ===="
if (-not $WhatIf) {
    Write-Host "Query a KB on demand in chat with #kbname (no model attach). Set KB access in the UI (Knowledge > Access)."
}
