# Maestro round trip (runs every 2 min via Task Scheduler "Maestro Sync"):
#   1. new audio in <repo>\inbox and <repo>\inbox-backing  -> GPU box inboxes (then moved to .\sent)
#   2. finished songs on the box (have song.json)          -> Documents\Karaoke\library (staged, then renamed in)
$ErrorActionPreference = 'Stop'
$Box  = 'ryan@192.168.29.71'
$Root = Split-Path $PSScriptRoot -Parent
$Kar  = Join-Path $env:USERPROFILE 'Documents\Karaoke'
$Lib  = Join-Path $Kar 'library'
$Log  = Join-Path $Root 'sync.log'
$Ssh  = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10')
function Write-Log($m) { "$(Get-Date -Format 'MM-dd HH:mm:ss') $m" | Add-Content $Log }

# Only one run at a time (a big upload can outlast the 2-minute interval).
$lock = Join-Path $env:TEMP 'maestro-sync.lock'
try { $fs = [IO.File]::Open($lock, 'OpenOrCreate', 'ReadWrite', 'None') } catch { exit }

try {
    & ssh @Ssh $Box 'true' 2>$null
    if ($LASTEXITCODE -ne 0) { exit }  # box off or offline: try again next run

    foreach ($dir in 'inbox', 'inbox-backing') {
        $src = Join-Path $Root $dir
        if (-not (Test-Path $src)) { continue }
        $sent = Join-Path $src 'sent'
        New-Item -ItemType Directory -Force $sent | Out-Null
        Get-ChildItem $src -File |
            Where-Object { $_.Extension -match '^\.(mp3|flac|wav|m4a|ogg|opus|aac)$' -and $_.LastWriteTime -lt (Get-Date).AddSeconds(-30) } |
            ForEach-Object {
                $name = $_.Name -replace '-SnapYT\.App', ''
                & scp @Ssh $_.FullName "${Box}:karaoke/$dir/$name"
                if ($LASTEXITCODE -eq 0) { Move-Item $_.FullName (Join-Path $sent $_.Name) -Force; Write-Log "sent $name -> $dir" }
            }
    }

    # Quote-free remote command: Windows PowerShell 5.1 strips embedded double quotes from native args.
    $done = & ssh @Ssh $Box 'cd ~/karaoke/library && ls -d */song.json' | ForEach-Object { $_.Split('/')[0] }
    $stage = Join-Path $Kar '.incoming'
    New-Item -ItemType Directory -Force $stage, $Lib | Out-Null
    foreach ($id in $done) {
        if (-not $id -or (Test-Path (Join-Path $Lib $id))) { continue }  # never overwrite: the app owns local edits
        $tmp = Join-Path $stage $id
        if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
        & scp @Ssh -r "${Box}:karaoke/library/$id" $stage
        if ($LASTEXITCODE -eq 0) { Move-Item $tmp (Join-Path $Lib $id); Write-Log "added $id to Maestro library" }
    }
} catch { Write-Log "error: $_" } finally { $fs.Close() }
