# bundle_wiki.ps1
# Concatenate llm_wiki into a single _bundle.md for use as the Open-WebUI system prompt.

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$root = Join-Path $repoRoot "llm_wiki"
$out  = Join-Path $root "_bundle.md"

if (-not (Test-Path $root)) {
    Write-Error "llm_wiki folder not found: $root"
    exit 1
}

$header = @"
# Rewave Wiki Bundle

Knowledge base aziendale Rewave. Pages connesse via [[wikilink]] stile Obsidian.
Categorie: sources/, entities/, concepts/, topics/, decisions/, queries/.

Vedi sezione "FILE: index.md" per catalogo completo.
Vedi sezione "FILE: CLAUDE.md" per schema/convenzioni.

---

"@

# Order: CLAUDE.md, index.md, log.md, then wiki/** sorted by path
$ordered = @()
foreach ($name in @("CLAUDE.md", "index.md", "log.md")) {
    $p = Join-Path $root $name
    if (Test-Path $p) { $ordered += $p }
}

$wikiDir = Join-Path $root "wiki"
if (Test-Path $wikiDir) {
    $ordered += Get-ChildItem -Path $wikiDir -Recurse -Filter *.md |
                Sort-Object FullName |
                Select-Object -ExpandProperty FullName
}

if ($ordered.Count -eq 0) {
    Write-Error "No .md found in $root"
    exit 1
}

$sb = [System.Text.StringBuilder]::new()
[void]$sb.Append($header)

foreach ($f in $ordered) {
    $rel = $f.Substring($root.Length).TrimStart('\','/').Replace('\','/')
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("---")
    [void]$sb.AppendLine()
    [void]$sb.AppendLine("## FILE: $rel")
    [void]$sb.AppendLine()
    [void]$sb.Append((Get-Content -Raw -LiteralPath $f -Encoding utf8))
    [void]$sb.AppendLine()
}

$bundle = $sb.ToString()
Set-Content -LiteralPath $out -Value $bundle -Encoding utf8 -NoNewline

$size = (Get-Item -LiteralPath $out).Length
$approxTokens = [math]::Round($bundle.Length / 4)

Write-Host ""
Write-Host "Bundle created:"
Write-Host "  Path:        $out"
Write-Host "  Files:       $($ordered.Count)"
Write-Host "  Size:        $([math]::Round($size/1KB,1)) KB"
Write-Host "  Chars:       $($bundle.Length)"
Write-Host "  Token approx:~$approxTokens (4 chars/token rough estimate)"
Write-Host ""

if ($approxTokens -gt 180000) {
    Write-Warning "Bundle near Sonnet 200k limit. Consider Opus 4.7 1M context."
}
