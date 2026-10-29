<#
  ccr.ps1 - Selector de sesiones de Claude Code y Codex de todos los proyectos.

  Uso:
    ccr            abre el selector
    ccr texto      abre el selector ya filtrado
    ccr -Refresh   reconstruye las cachés desde cero
    ccr -Demo      datos inventados (para capturas sin enseñar tus chats)

  Teclas: escribir = filtrar · ←/→ = Claude Code / Codex · ↑/↓ PgUp/PgDn = moverse
          Enter = retomar · Esc = salir

  IMPORTANTE: guardar este archivo como UTF-8 con BOM (Windows PowerShell 5.1 lo necesita).
#>
param(
    [Parameter(Position = 0)][string]$Filter = '',
    [switch]$Refresh,
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$ClaudeDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE '.claude' }
$CodexDir  = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
$CacheDir  = Join-Path $env:LOCALAPPDATA 'cc-sessions'
$TailBytes = 512KB
$HeadLines = 300

# ---------------------------------------------------------------- utilidades de lectura

function Get-JsonString([string]$line, [string]$key) {
    # Extrae "key":"valor" sin parsear la línea entera (algunas líneas pesan MB)
    $m = [regex]::Match($line, '"' + $key + '":"((?:[^"\\]|\\.)*)"')
    if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
    return $null
}

function Read-Tail([string]$path) {
    $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
    try {
        $start = [Math]::Max(0, $fs.Length - $TailBytes)
        [void]$fs.Seek($start, 'Begin')
        $buf = New-Object byte[] ($fs.Length - $start)
        [void]$fs.Read($buf, 0, $buf.Length)
        $lines = [Text.Encoding]::UTF8.GetString($buf) -split "`n"
        if ($start -gt 0) { $lines = $lines | Select-Object -Skip 1 }  # primera línea cortada
        return $lines
    } finally { $fs.Dispose() }
}

function Read-Head([string]$path, [int]$max) {
    $i = 0
    foreach ($l in [IO.File]::ReadLines($path)) { $l; if (++$i -ge $max) { break } }
}

# Cachea por archivo (tamaño + fecha) y solo vuelve a leer los que han cambiado
function Get-Cached([string]$name, $files, [scriptblock]$reader) {
    $file = Join-Path $CacheDir $name
    $cache = @{}
    if (-not $Refresh -and (Test-Path $file)) {
        try { foreach ($s in (Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json)) { $cache[$s.Path] = $s } } catch {}
    }
    $result = @(foreach ($f in $files) {
        $c = $cache[$f.FullName]
        if ($c -and $c.Length -eq $f.Length -and $c.Ticks -eq $f.LastWriteTimeUtc.Ticks) { $c }
        else { & $reader $f }
    })
    if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory $CacheDir | Out-Null }
    ConvertTo-Json -InputObject $result -Depth 3 -Compress | Set-Content $file -Encoding UTF8
    return $result
}

# ---------------------------------------------------------------- Claude Code

function Read-ClaudeFile([IO.FileInfo]$file) {
    $meta = @{ CustomTitle = $null; AiTitle = $null; LastPrompt = $null; Cwd = $null }

    foreach ($l in [IO.File]::ReadLines($file.FullName)) {
        if ($l.Contains('"cwd":"')) { $meta.Cwd = Get-JsonString $l 'cwd'; break }
    }

    $scan = {
        param($lines)
        foreach ($l in $lines) {
            if     ($l.StartsWith('{"type":"custom-title"')) { $meta.CustomTitle = Get-JsonString $l 'customTitle' }
            elseif ($l.StartsWith('{"type":"ai-title"'))     { $meta.AiTitle     = Get-JsonString $l 'aiTitle' }
            elseif ($l.StartsWith('{"type":"last-prompt"'))  { $meta.LastPrompt  = Get-JsonString $l 'lastPrompt' }
        }
    }
    & $scan (Read-Tail $file.FullName)
    if (-not $meta.CustomTitle -and -not $meta.AiTitle -and $file.Length -gt $TailBytes) {
        & $scan ([IO.File]::ReadLines($file.FullName))  # respaldo: archivo completo
    }

    $title = $meta.CustomTitle
    if (-not $title) { $title = $meta.AiTitle }
    if (-not $title) { $title = $meta.LastPrompt }

    [pscustomobject]@{
        Path = $file.FullName; Length = $file.Length; Ticks = $file.LastWriteTimeUtc.Ticks
        Id = $file.BaseName; Title = $title; Prompt = $meta.LastPrompt; Cwd = $meta.Cwd
    }
}

function Get-ClaudeSessions {
    $dir = Join-Path $ClaudeDir 'projects'
    if (-not (Test-Path $dir)) { return @() }
    $files = Get-ChildItem $dir -Recurse -Filter *.jsonl -File |
             Where-Object { $_.DirectoryName -notmatch '[\\/]subagents$' }
    $all = Get-Cached 'cache.json' $files ${function:Read-ClaudeFile}
    @($all | Where-Object { $_.Cwd -and $_.Title } |
          Select-Object *, @{ n = 'Tool'; e = { 'claude' } }, @{ n = 'SortTicks'; e = { $_.Ticks } } |
          Sort-Object SortTicks -Descending)
}

# ---------------------------------------------------------------- Codex

function Get-CodexUserText([string]$line) {
    # Mensajes del usuario; se descartan los que inyecta Codex (<environment_context>, AGENTS.md...)
    if (-not $line.Contains('"role":"user"')) { return $null }
    $t = Get-JsonString $line 'text'
    if (-not $t) { return $null }
    $t = $t.Trim()
    if ($t.StartsWith('<') -or $t.StartsWith('# AGENTS.md')) { return $null }
    return $t
}

function Read-CodexFile([IO.FileInfo]$file) {
    $cwd = $null; $first = $null; $last = $null
    foreach ($l in (Read-Head $file.FullName $HeadLines)) {
        if (-not $cwd -and $l.Contains('"cwd":"')) { $cwd = Get-JsonString $l 'cwd' }
        if (-not $first) { $first = Get-CodexUserText $l }
        if ($cwd -and $first) { break }
    }
    foreach ($l in (Read-Tail $file.FullName)) {
        $t = Get-CodexUserText $l
        if ($t) { $last = $t }
    }
    if (-not $last) { $last = $first }

    [pscustomobject]@{
        Path = $file.FullName; Length = $file.Length; Ticks = $file.LastWriteTimeUtc.Ticks
        Id = [regex]::Match($file.Name, '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.jsonl$').Groups[1].Value
        Cwd = $cwd; FirstPrompt = $first; LastPrompt = $last
    }
}

function Get-CodexSessions {
    $dir = Join-Path $CodexDir 'sessions'
    if (-not (Test-Path $dir)) { return @() }

    # Títulos (session_index.jsonl) y últimos prompts (history.jsonl): pequeños, se leen siempre
    $names = @{}; $nameTicks = @{}
    $idx = Join-Path $CodexDir 'session_index.jsonl'
    if (Test-Path $idx) {
        foreach ($l in [IO.File]::ReadLines($idx)) {
            $id = Get-JsonString $l 'id'
            if (-not $id) { continue }
            $names[$id] = Get-JsonString $l 'thread_name'
            $u = Get-JsonString $l 'updated_at'
            if ($u) { $nameTicks[$id] = [DateTime]::Parse($u).ToUniversalTime().Ticks }
        }
    }
    $prompts = @{}; $promptTicks = @{}
    $hist = Join-Path $CodexDir 'history.jsonl'
    if (Test-Path $hist) {
        foreach ($l in [IO.File]::ReadLines($hist)) {
            $id = Get-JsonString $l 'session_id'
            if (-not $id) { continue }
            $prompts[$id] = Get-JsonString $l 'text'
            $m = [regex]::Match($l, '"ts":(\d+)')
            if ($m.Success) { $promptTicks[$id] = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.Groups[1].Value).UtcTicks }
        }
    }

    $files = Get-ChildItem $dir -Recurse -Filter 'rollout-*.jsonl' -File
    $all = Get-Cached 'codex-cache.json' $files ${function:Read-CodexFile}

    @(foreach ($s in $all) {
        if (-not $s.Cwd) { continue }
        $title  = $names[$s.Id]
        $prompt = $prompts[$s.Id]
        if (-not $prompt) { $prompt = $s.LastPrompt }
        if (-not $title)  { $title = $s.FirstPrompt }
        if (-not $title)  { $title = $prompt }
        if (-not $title)  { continue }
        $ticks = (@($s.Ticks, $nameTicks[$s.Id], $promptTicks[$s.Id]) | Where-Object { $_ } | Measure-Object -Maximum).Maximum
        [pscustomobject]@{ Tool = 'codex'; Id = $s.Id; Title = $title; Prompt = $prompt; Cwd = $s.Cwd; SortTicks = [long]$ticks }
    }) | Sort-Object SortTicks -Descending
}

# ---------------------------------------------------------------- interfaz

$E   = [char]27
$Dim = '38;5;244'
$SelBg = '48;5;236'
$TagColors = @(75, 114, 179, 176, 80, 215, 147, 203, 156, 223)

$Tabs = @(
    @{ Key = 'claude'; Name = 'Claude Code'; Icon = '✻'; Accent = '38;2;217;119;87' },   # naranja Claude
    @{ Key = 'codex';  Name = 'Codex';       Icon = '⬡'; Accent = '38;2;16;163;127' }    # verde ChatGPT
)

function Format-Ago([long]$ticks) {
    $d = [DateTime]::UtcNow - [DateTime]::new($ticks, 'Utc')
    if ($d.TotalMinutes -lt 60) { return @(('hace {0} min' -f [int]$d.TotalMinutes), '38;5;114') }
    if ($d.TotalHours   -lt 24) { return @(('hace {0} h'   -f [int]$d.TotalHours),   '38;5;114') }
    if ($d.TotalDays    -lt 7)  { return @(('hace {0} d'   -f [int]$d.TotalDays),    '38;5;179') }
    if ($d.TotalDays    -lt 30) { return @(('hace {0} d'   -f [int]$d.TotalDays),    $Dim) }
    return @([DateTime]::new($ticks, 'Utc').ToLocalTime().ToString('dd/MM/yyyy'), $Dim)
}

function Fit([string]$s, [int]$w) {
    if ($w -le 0) { return '' }
    if (-not $s) { $s = '' }
    $s = ($s -replace '\s+', ' ').Trim()
    if ($s.Length -gt $w) { $s = $s.Substring(0, [Math]::Max(0, $w - 1)) + '…' }
    return $s.PadRight($w)
}

function Get-Tag([string]$cwd) {
    $name = Split-Path $cwd -Leaf
    if (-not $name) { $name = $cwd }
    $h = 0; foreach ($ch in $name.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 9973 }
    return @($name, ('38;5;' + $TagColors[$h % $TagColors.Count]))
}

# Una línea = lista de segmentos @(texto, sgr). Con $bg se pinta el fondo de toda la línea.
function Write-Seg($sb, $segs, [string]$bg = '') {
    $pre = if ($bg) { "$E[$bg" + 'm' } else { '' }
    foreach ($s in $segs) { [void]$sb.Append("$E[0m$pre$E[$($s[1])m$($s[0])") }
    [void]$sb.Append("$E[0m$E[K`n")
}

function Select-Session($data, [string]$query) {
    $tab = 0; $sel = 0; $top = 0
    if (-not $data['claude'].Count -and $data['codex'].Count) { $tab = 1 }
    [Console]::CursorVisible = $false
    [Console]::Write("$E[?1049h$E[2J")  # pantalla alternativa
    try {
        while ($true) {
            $t = $Tabs[$tab]; $Accent = $t.Accent
            $all = @($data[$t.Key])
            $words = @($query.ToLower() -split '\s+' | Where-Object { $_ })
            $list = @($all | Where-Object {
                $hay = ("$($_.Title) $($_.Prompt) $($_.Cwd)").ToLower()
                -not ($words | Where-Object { -not $hay.Contains($_) })
            })

            $w = [Console]::WindowWidth - 1
            $h = [Console]::WindowHeight
            $rows = [Math]::Max(1, [int][Math]::Floor(($h - 11) / 2))
            if ($sel -ge $list.Count) { $sel = [Math]::Max(0, $list.Count - 1) }
            if ($sel -lt $top) { $top = $sel }
            if ($sel -ge $top + $rows) { $top = $sel - $rows + 1 }

            $sb = New-Object Text.StringBuilder
            [void]$sb.Append("$E[H")

            # cabecera: título de la pestaña activa + selector de pestañas
            $left = " $($t.Icon) $($t.Name) · sesiones"
            $tabSegs = @()
            for ($j = 0; $j -lt $Tabs.Count; $j++) {
                $n = " $($Tabs[$j].Name) $($data[$Tabs[$j].Key].Count) "
                if ($j -eq $tab) { $tabSegs += , @($n, "1;7;$($Tabs[$j].Accent)") } else { $tabSegs += , @($n, $Dim) }
                if ($j -lt $Tabs.Count - 1) { $tabSegs += , @(' ', '0') }
            }
            $tabsLen = ($tabSegs | ForEach-Object { $_[0].Length } | Measure-Object -Sum).Sum
            Write-Seg $sb (@(, @($left, "1;$Accent")) + @(, @((' ' * [Math]::Max(1, $w - $left.Length - $tabsLen - 6)), '0')) + @(, @('← ', $Dim)) + $tabSegs + @(, @(' →', $Dim)))

            $count = if ($words.Count) { "$($list.Count) de $($all.Count)" } else { '' }
            if ($query) { Write-Seg $sb @(@(' ❯ ', $Accent), @($query, '1'), @('█', $Accent), @(("   $count"), $Dim)) }
            else        { Write-Seg $sb @(@(' ❯ ', $Accent), @('█', $Accent), @(' escribe para filtrar por título, prompt o carpeta', $Dim)) }
            Write-Seg $sb @(@(('─' * $w), $Accent))

            # lista
            for ($i = $top; $i -lt $top + $rows; $i++) {
                if ($i -ge $list.Count) {
                    if ($i -eq 0) {
                        $msg = if ($all.Count) { '   Nada coincide con la búsqueda.' } else { "   No hay sesiones de $($t.Name)." }
                        Write-Seg $sb @(@($msg, $Dim))
                    } else { Write-Seg $sb @() }
                    Write-Seg $sb @(); continue
                }
                $s = $list[$i]; $isSel = $i -eq $sel
                $bg  = if ($isSel) { $SelBg } else { '' }
                $bar = if ($isSel) { @(' ▌', $Accent) } else { @('  ', '0') }
                $ago = Format-Ago $s.SortTicks
                $tag = Get-Tag $s.Cwd
                $titleStyle = if ($isSel) { '1;38;5;231' } else { '38;5;252' }

                $agoW = 13
                Write-Seg $sb @($bar, @((' ' + (Fit $s.Title ($w - 3 - $agoW))), $titleStyle), @($ago[0].PadLeft($agoW), $ago[1])) $bg
                $tagText = Fit $tag[0] ([Math]::Min(26, $tag[0].Length))
                Write-Seg $sb @($bar, @(" $tagText", $tag[1]), @(' · ', $Dim), @((Fit $s.Prompt ($w - 6 - $tagText.Length)), $Dim)) $bg
            }

            # detalle de la seleccionada
            Write-Seg $sb @(@(('─' * $w), '38;5;238'))
            if ($list.Count) {
                $s = $list[$sel]
                $when = [DateTime]::new($s.SortTicks, 'Utc').ToLocalTime().ToString('dd/MM/yyyy HH:mm')
                if ($Demo -or (Test-Path -LiteralPath $s.Cwd)) { Write-Seg $sb @(@('  Carpeta  ', $Dim), @((Fit $s.Cwd ($w - 11)), '38;5;114')) }
                else { Write-Seg $sb @(@('  Carpeta  ', $Dim), @((Fit "$($s.Cwd)  (ya no existe)" ($w - 11)), '38;5;203')) }
                $p = ("$($s.Prompt)" -replace '\s+', ' ').Trim(); $pw = $w - 11
                $p1 = if ($p.Length -gt $pw) { $p.Substring(0, $pw) } else { $p }
                $p2 = if ($p.Length -gt $pw) { $p.Substring($pw) } else { '' }
                Write-Seg $sb @(@('  Prompt   ', $Dim), @((Fit $p1 $pw), '38;5;250'))
                Write-Seg $sb @(@('           ', $Dim), @((Fit $p2 $pw), '38;5;250'))
                Write-Seg $sb @(@('  Sesión   ', $Dim), @("$($s.Id)  ·  $when", $Dim))
            } else { 1..4 | ForEach-Object { Write-Seg $sb @() } }

            # pie
            $keys = @(@('←→', 'Claude/Codex'), @('↑↓', 'moverse'), @('Enter', 'retomar'), @('Esc', 'salir'))
            foreach ($kk in $keys) { [void]$sb.Append("$E[0m$E[1m $($kk[0])$E[0m$E[$($Dim)m $($kk[1])  ") }
            [void]$sb.Append("$E[0m$E[J")
            [Console]::Write($sb.ToString())

            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'Escape'     { return $null }
                'Enter'      { if ($list.Count) { return $list[$sel] } }
                'LeftArrow'  { $tab = ($tab + $Tabs.Count - 1) % $Tabs.Count; $sel = 0; $top = 0 }
                'RightArrow' { $tab = ($tab + 1) % $Tabs.Count; $sel = 0; $top = 0 }
                'Tab'        { $tab = ($tab + 1) % $Tabs.Count; $sel = 0; $top = 0 }
                'UpArrow'    { if ($sel -gt 0) { $sel-- } }
                'DownArrow'  { if ($sel -lt $list.Count - 1) { $sel++ } }
                'PageUp'     { $sel = [Math]::Max(0, $sel - $rows) }
                'PageDown'   { $sel = [Math]::Min([Math]::Max(0, $list.Count - 1), $sel + $rows) }
                'Home'       { $sel = 0 }
                'End'        { $sel = [Math]::Max(0, $list.Count - 1) }
                'Backspace'  { if ($query.Length) { $query = $query.Substring(0, $query.Length - 1); $sel = 0 } }
                default      { if (-not [char]::IsControl($k.KeyChar)) { $query += $k.KeyChar; $sel = 0 } }
            }
        }
    } finally {
        [Console]::Write("$E[0m$E[?1049l")
        [Console]::CursorVisible = $true
    }
}

# ---------------------------------------------------------------- demo

function Get-DemoSessions([string]$tool, $rows) {
    $now = [DateTime]::UtcNow
    foreach ($r in $rows) {
        [pscustomobject]@{
            Tool = $tool; Id = [guid]::NewGuid().ToString(); Title = $r[0]; Prompt = $r[1]
            Cwd = "C:\Users\demo\$($r[2])"; SortTicks = $now.AddMinutes(-[double]$r[3]).Ticks
        }
    }
}

function Get-DemoData {
    @{
        claude = @(Get-DemoSessions 'claude' @(
            @('Refactor del sistema de autenticación', 'Pasa el login a JWT y añade refresh tokens', 'code\api-backend', 4),
            @('Landing page con animaciones', 'Haz que el hero entre con un fade más suave', 'code\portfolio-web', 52),
            @('Script de backup de fotos', 'Que no copie los duplicados y deje un log', 'scripts\backup', 180),
            @('Bug en el carrito de compra', 'El total no se actualiza al quitar un producto', 'code\tienda-online', 1500),
            @('Apuntes de redes para el examen', 'Resúmeme el tema 4: routing y subnetting', 'uni\redes', 2900),
            @('Juego de plataformas en raylib', 'Añade doble salto y coyote time', 'code\plataformas', 6200),
            @('Bot de Telegram para recordatorios', 'Que acepte fechas tipo "mañana a las 9"', 'code\recordatorios-bot', 11000),
            @('Migrar proyecto a TypeScript', 'Empieza por los modelos y los servicios', 'code\api-backend', 20000)
        ))
        codex = @(Get-DemoSessions 'codex' @(
            @('Tests para el parser de CSV', 'Cubre comillas escapadas y saltos de línea', 'code\csv-tools', 25),
            @('Optimizar consultas SQL', 'La query de pedidos tarda 4 s, mira los índices', 'code\tienda-online', 300),
            @('CLI para renombrar archivos', 'Añade un modo --dry-run', 'scripts\renamer', 2100),
            @('Dockerizar la API', 'Imagen multi-stage y docker-compose con Postgres', 'code\api-backend', 4500),
            @('Componente de calendario', 'Que se pueda navegar con el teclado', 'code\portfolio-web', 9000)
        ))
    }
}

# ---------------------------------------------------------------- main

if ($Demo) { $data = Get-DemoData }
else { $data = @{ claude = @(Get-ClaudeSessions); codex = @(Get-CodexSessions) } }
if (-not $data.claude.Count -and -not $data.codex.Count) { Write-Host 'No hay sesiones de Claude Code ni de Codex.'; return }

$pick = Select-Session $data $Filter
if (-not $pick) { return }
if ($Demo) { Write-Host "  (demo) Se retomaría: $($pick.Title)" -ForegroundColor DarkGray; return }

if (-not (Test-Path -LiteralPath $pick.Cwd)) {
    Write-Host "La carpeta ya no existe: $($pick.Cwd)" -ForegroundColor Red
    return
}

Set-Location -LiteralPath $pick.Cwd
Write-Host ''
if ($pick.Tool -eq 'codex') { Write-Host "  ⬡ $($pick.Title)" -ForegroundColor Green }
else                        { Write-Host "  ✻ $($pick.Title)" -ForegroundColor Yellow }
Write-Host "    $($pick.Cwd)" -ForegroundColor DarkGray
Write-Host ''
if ($pick.Tool -eq 'codex') { codex resume $pick.Id } else { claude --resume $pick.Id }
