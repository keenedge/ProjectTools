# ProjectTools: pm clone | init | save -- GitHub repos backed up to OneDrive with restic.
#
# Uses the existing environment:
#   RESTIC_REPOSITORY     default repository (e.g. rclone:restic:backups/restic)
#   RESTIC_PASSWORD_FILE  repository password
#   RESTIC_EXCLUDE_FILE   optional patterns file passed to --exclude-file

$ConfigName = '.backup.json'
$ResticDir = '.restic'
$IncludeName = 'include.restic.txt'
$ExcludeName = 'exclude.restic.txt'
# User settings. "folders" maps owner/repo to the folder pm clone uses instead of the repo name.
$PmConfigFile = Join-Path $HOME '.config\pm\config.json'

function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

# Read the user config. A missing or empty file gives an empty config.
function Get-PmConfig {
    $config = $null
    if (Test-Path $PmConfigFile) {
        $text = Get-Content $PmConfigFile -Raw
        if ($text -and $text.Trim()) { $config = $text | ConvertFrom-Json -AsHashtable }
    }
    if (-not $config) { $config = [ordered]@{} }
    if (-not $config['folders']) { $config['folders'] = [ordered]@{} }
    $config
}

# Folder for a repo: the configured mapping (owner/repo, any case), else the repo name.
function Get-RepoFolder([hashtable]$Folders, [object]$Repo) {
    foreach ($key in $Folders.Keys) {
        if ($key -eq $Repo.nameWithOwner) { return $Folders[$key] }
    }
    $Repo.name
}

function Set-RepoFolder([object]$Repo, [string]$Folder) {
    $config = Get-PmConfig
    $folders = $config['folders']
    foreach ($key in @($folders.Keys)) {
        if ($key -eq $Repo.nameWithOwner) { $folders.Remove($key) }
    }
    $folders[$Repo.nameWithOwner] = $Folder
    New-Item -ItemType Directory -Path (Split-Path $PmConfigFile) -Force | Out-Null
    $config | ConvertTo-Json -Depth 5 | Set-Content -Path $PmConfigFile -Encoding utf8
    Write-Host "Saved folder mapping $($Repo.nameWithOwner) -> $Folder in $PmConfigFile"
}

function Assert-Command([string[]]$Names) {
    foreach ($n in $Names) {
        if (-not (Get-Command $n -ErrorAction SilentlyContinue)) { throw "'$n' is not on PATH." }
    }
}

function Assert-ResticPassword {
    if ($env:RESTIC_PASSWORD) { return }
    $pf = $env:RESTIC_PASSWORD_FILE
    if (-not $pf) { throw 'Neither RESTIC_PASSWORD nor RESTIC_PASSWORD_FILE is set.' }
    if (-not (Test-Path $pf)) { throw "Password file not found: $pf" }
    if ((Get-Item $pf).Length -eq 0) { throw "Password file is empty: $pf" }
}

function Get-ProjectConfig([string]$Dir) {
    $file = Join-Path $Dir $ConfigName
    if (-not (Test-Path $file)) { throw "No $ConfigName in $Dir. Run pm init or pm clone first." }
    Get-Content $file -Raw | ConvertFrom-Json
}

# Keep a file out of git without touching the repo's committed .gitignore.
function Add-LocalGitExclude([string]$Dir, [string]$Pattern) {
    $exclude = Join-Path $Dir '.git\info\exclude'
    if (-not (Test-Path $exclude)) { return }
    if (-not (Select-String -Path $exclude -SimpleMatch $Pattern -Quiet)) {
        Add-Content -Path $exclude -Value $Pattern
    }
}

# Create .restic\include.restic.txt (empty) and .restic\exclude.restic.txt.
# Existing files are left alone.
function Initialize-ResticFiles([string]$Dir) {
    $folder = Join-Path $Dir $ResticDir
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $include = Join-Path $folder $IncludeName
    if (-not (Test-Path $include)) { New-Item -ItemType File -Path $include | Out-Null }
    $exclude = Join-Path $folder $ExcludeName
    if (-not (Test-Path $exclude)) { Set-Content -Path $exclude -Value '.restic', '.git' -Encoding utf8 }
}

# Read a patterns file, skipping blank lines and # comments.
function Get-PatternLines([string]$File) {
    if (-not (Test-Path $File)) { return @() }
    @(Get-Content $File | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}

# Initialise the restic repository if it does not exist yet.
function Initialize-ResticRepo([string]$Repository) {
    $env:RESTIC_REPOSITORY = $Repository
    restic cat config *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "restic repository is reachable: $Repository"
        return
    }
    # restic exit code 10 = repository does not exist (0.17+).
    if ($LASTEXITCODE -ne 10) { throw "Cannot open restic repository $Repository (exit $LASTEXITCODE)." }
    Write-Step "Creating restic repository $Repository"
    restic init
    if ($LASTEXITCODE -ne 0) { throw 'restic init failed.' }
}

# Numbered pick list. $Line formats an item, $Key is the text a filter matches against.
# A filter with one match picks it; with several it shows a shorter list.
function Select-Item([object[]]$Items, [string]$Noun, [scriptblock]$Line, [scriptblock]$Key) {
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ('{0,3}) {1}' -f ($i + 1), (& $Line $Items[$i]))
    }
    while ($true) {
        $answer = Read-Host "Pick a $Noun (1-$($Items.Count), or text to filter, blank to cancel)"
        if (-not $answer) { return $null }
        if ($answer -match '^\d+$' -and [int]$answer -ge 1 -and [int]$answer -le $Items.Count) {
            return $Items[[int]$answer - 1]
        }
        $hits = @($Items | Where-Object { (& $Key $_) -like "*$answer*" })
        if ($hits.Count -eq 1) { return $hits[0] }
        if ($hits.Count -gt 1) { return Select-Item $hits $Noun $Line $Key }
        Write-Host "No $Noun matches '$answer'." -ForegroundColor Yellow
    }
}

function Select-Repo([object[]]$Repos, [string]$Root) {
    $line = {
        param($r)
        $vis = if ($r.isPrivate) { 'private' } else { 'public ' }
        $here = if (Test-Path (Join-Path $Root "$($r.folder)\.git")) { '*' } else { ' ' }
        $desc = if ($r.description) { " - $($r.description)" } else { '' }
        '{0} {1}  {2}{3}' -f $here, $vis, $r.nameWithOwner, $desc
    }.GetNewClosure()
    Select-Item $Repos 'repo' $line { param($r) $r.nameWithOwner }
}

function Confirm-Action([string]$Prompt) {
    (Read-Host "$Prompt (y/N)").Trim() -match '^y(es)?$'
}

# Run $Action for each item, reporting failures at the end instead of stopping.
function Invoke-ForEach([object[]]$Items, [scriptblock]$Label, [scriptblock]$Action) {
    $failed = @()
    foreach ($item in $Items) {
        $name = & $Label $item
        Write-Host ''
        Write-Host "### $name" -ForegroundColor Magenta
        try { & $Action $item } catch { Write-Warning $_; $failed += $name }
    }
    Write-Host ''
    if ($failed) { Write-Warning "Failed: $($failed -join ', ')" }
    else { Write-Host "All $($Items.Count) done." -ForegroundColor Green }
}

# Write .backup.json and the .restic files. The caller checks the restic repository.
function Set-ProjectBackup([string]$Dir, [string]$Tag) {
    Write-Step 'Setting up restic backup'
    $config = [ordered]@{
        repository = $env:RESTIC_REPOSITORY
        tag        = $Tag
    }
    $config | ConvertTo-Json | Set-Content -Path (Join-Path $Dir $ConfigName) -Encoding utf8
    Add-LocalGitExclude $Dir $ConfigName
    Initialize-ResticFiles $Dir
    Write-Host "Ready: $Dir (tag '$Tag')" -ForegroundColor Green
}

function Assert-BackupEnvironment([string[]]$Commands) {
    Assert-Command $Commands
    Assert-ResticPassword
    if (-not $env:RESTIC_REPOSITORY) { throw 'RESTIC_REPOSITORY is not set.' }
    Initialize-ResticRepo $env:RESTIC_REPOSITORY
}

function Get-GitHubRepos([string]$Owner) {
    Write-Step 'Fetching GitHub repos'
    $ghArgs = @('repo', 'list')
    if ($Owner) { $ghArgs += $Owner }
    $ghArgs += '--no-archived', '--limit', '200', '--json', 'nameWithOwner,name,description,isPrivate,updatedAt'
    $json = gh @ghArgs
    if ($LASTEXITCODE -ne 0) { throw 'gh repo list failed.' }
    $repos = @($json | ConvertFrom-Json | Sort-Object updatedAt -Descending)
    if ($repos.Count -eq 0) { throw 'No repos found.' }
    $repos
}

function Copy-Repo([string]$Root, [object]$Repo) {
    $dest = Join-Path $Root $Repo.folder
    if (Test-Path (Join-Path $dest '.git')) {
        Write-Host "Already cloned at $dest - skipping clone."
    } elseif ((Test-Path $dest) -and (Get-ChildItem $dest -Force | Select-Object -First 1)) {
        throw "$dest exists and is not empty."
    } else {
        Write-Step "Cloning $($Repo.nameWithOwner) into $dest"
        gh repo clone $Repo.nameWithOwner $dest
        if ($LASTEXITCODE -ne 0) { throw 'Clone failed.' }
    }
    # The restic tag is always the repo name, whatever the folder is called.
    if (-not (Test-Path (Join-Path $dest $ConfigName))) { Set-ProjectBackup $dest $Repo.name }
}

function Invoke-Clone([string]$Root, [string]$Name, [string]$Folder, [string]$Owner, [switch]$All) {
    if ($Folder -and $Folder.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Invalid folder name: $Folder" }
    Assert-BackupEnvironment gh, git, restic
    $repos = Get-GitHubRepos $Owner
    $folders = (Get-PmConfig)['folders']
    foreach ($r in $repos) { $r | Add-Member -NotePropertyName folder -NotePropertyValue (Get-RepoFolder $folders $r) }

    if ($All) {
        $missing = @($repos | Where-Object { -not (Test-Path (Join-Path $Root "$($_.folder)\.git")) })
        Write-Host "$($repos.Count) repos, $($missing.Count) not yet in $Root."
        if (-not (Confirm-Action "Clone all into $Root and set up backups?")) { Write-Host 'Cancelled.'; return }
        Invoke-ForEach $repos { param($r) $r.nameWithOwner } { param($r) Copy-Repo $Root $r }
        return
    }

    if ($Name) {
        $repo = $repos | Where-Object { $_.name -eq $Name -or $_.nameWithOwner -eq $Name } | Select-Object -First 1
        if (-not $repo) { throw "No GitHub repo named '$Name'." }
    } else {
        Write-Host "(* = already in $Root)"
        $repo = Select-Repo $repos $Root
        if (-not $repo) { Write-Host 'Cancelled.'; return }
    }
    if ($Folder) {
        Set-RepoFolder $repo $Folder
        $repo.folder = $Folder
    }
    Copy-Repo $Root $repo
}

# Create a project folder, or adopt an existing one: git init if needed, then set up backups.
function Initialize-Folder([string]$Dir) {
    $name = Split-Path $Dir -Leaf
    if (-not (Test-Path $Dir)) {
        Write-Step "Creating $Dir"
        New-Item -ItemType Directory -Path $Dir | Out-Null
    }
    if (-not (Test-Path (Join-Path $Dir '.git'))) {
        git init -q $Dir
        if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
    }
    Set-ProjectBackup $Dir $name
}

function Invoke-Init([string]$Root, [string]$Name, [switch]$All) {
    Assert-BackupEnvironment git, restic

    if ($All) {
        $folders = @(Get-ChildItem $Root -Directory | Where-Object { -not (Test-Path (Join-Path $_.FullName $ConfigName)) })
        if ($folders.Count -eq 0) { Write-Host "Every folder in $Root is already set up."; return }
        Write-Host "Not set up yet: $($folders.Name -join ', ')"
        if (-not (Confirm-Action "Set up these $($folders.Count) folders (git init where needed)?")) { Write-Host 'Cancelled.'; return }
        Invoke-ForEach $folders { param($f) $f.Name } { param($f) Initialize-Folder $f.FullName }
        return
    }

    if (-not $Name) { $Name = (Read-Host 'Project name (blank to cancel)').Trim() }
    if (-not $Name) { Write-Host 'Cancelled.'; return }
    if ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Invalid project name: $Name" }
    Initialize-Folder (Join-Path $Root $Name)
}

function Save-ProjectFolder([string]$Dir, [string]$Message, [switch]$NoPush) {
    $dir = (Resolve-Path $Dir).Path
    $top = git -C $dir rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { throw "$dir is not inside a git repository." }
    $dir = (Resolve-Path $top).Path
    $config = Get-ProjectConfig $dir

    # 1. Commit and push. Failures here are reported but do not stop the backup.
    Write-Step "Committing changes in $dir"
    git -C $dir add -A
    git -C $dir diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Nothing to commit.'
    } else {
        git -C $dir status --short
        if (-not $Message) { $Message = Read-Host 'Commit message (blank for timestamp)' }
        if (-not $Message) { $Message = "WIP $(Get-Date -Format 'yyyy-MM-dd HH:mm')" }
        git -C $dir commit -m $Message
        if ($LASTEXITCODE -ne 0) { Write-Warning 'Commit failed - continuing with backup.' }
    }

    if (-not $NoPush) {
        git -C $dir rev-parse --abbrev-ref '@{upstream}' *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning 'No upstream branch - skipping push.'
        } else {
            Write-Step 'Pushing'
            git -C $dir push
            if ($LASTEXITCODE -ne 0) { Write-Warning 'Push failed (try git pull --rebase) - continuing with backup.' }
        }
    }

    # 2. Back up the working folder to OneDrive.
    Write-Step "Backing up to $($config.repository)"
    $env:RESTIC_REPOSITORY = $config.repository
    $resticArgs = @('backup', '--tag', $config.tag)

    # include.restic.txt: paths relative to the project. Empty = whole project.
    $includes = Get-PatternLines (Join-Path $dir "$ResticDir\$IncludeName")
    $fileList = $null
    if ($includes.Count -gt 0) {
        $fileList = New-TemporaryFile
        $includes | ForEach-Object { Join-Path $dir $_ } | Set-Content -Path $fileList -Encoding utf8
        $resticArgs += "--files-from-verbatim=$fileList"
    } else {
        $resticArgs += $dir
    }

    $excludeFile = Join-Path $dir "$ResticDir\$ExcludeName"
    if (Test-Path $excludeFile) {
        $resticArgs += "--exclude-file=$excludeFile"
    } else {
        $resticArgs += '--exclude', '.git'
    }
    if ($env:RESTIC_EXCLUDE_FILE -and (Test-Path $env:RESTIC_EXCLUDE_FILE)) {
        $resticArgs += "--exclude-file=$env:RESTIC_EXCLUDE_FILE"
    }
    try { restic @resticArgs } finally { if ($fileList) { Remove-Item $fileList } }
    if ($LASTEXITCODE -eq 3) {
        Write-Warning 'Backup finished, but some files could not be read.'
    } elseif ($LASTEXITCODE -ne 0) {
        throw "restic backup failed (exit $LASTEXITCODE)."
    } else {
        Write-Host 'Backup complete.' -ForegroundColor Green
    }
}

function Invoke-Save([string]$Root, [string]$Name, [string]$Message, [switch]$NoPush, [switch]$All) {
    Assert-Command git, restic
    Assert-ResticPassword

    if (-not $All) {
        $dir = if ($Name) { Join-Path $Root $Name } else { $Root }
        Save-ProjectFolder $dir $Message -NoPush:$NoPush
        return
    }

    $projects = @(Get-ChildItem $Root -Directory | Where-Object { Test-Path (Join-Path $_.FullName $ConfigName) })
    if ($projects.Count -eq 0) { throw "No projects in $Root have a $ConfigName. Run pm init or pm clone first." }
    Invoke-ForEach $projects { param($p) $p.Name } { param($p) Save-ProjectFolder $p.FullName $Message -NoPush:$NoPush }
}

# Every snapshot in the current RESTIC_REPOSITORY, newest first.
function Get-Snapshots {
    $json = restic snapshots --json
    if ($LASTEXITCODE -ne 0) { throw "restic snapshots failed (exit $LASTEXITCODE)." }
    @($json | ConvertFrom-Json | Sort-Object { [datetime]$_.time } -Descending)
}

# One entry per tag: its latest snapshot and how many there are.
function Get-SnapshotTags([object[]]$Snapshots) {
    $seen = [ordered]@{}
    foreach ($s in $Snapshots) {
        foreach ($t in @($s.tags)) {
            if (-not $t) { continue }
            if ($seen.Contains($t)) { $seen[$t].count++ }
            else { $seen[$t] = [pscustomobject]@{ tag = $t; latest = $s; count = 1 } }
        }
    }
    @($seen.Values)
}

# The project folder a snapshot was taken of. With an include list there are several
# paths, so use their common parent.
function Get-SnapshotRoot([object]$Snapshot) {
    $paths = @($Snapshot.paths)
    if ($paths.Count -eq 1) { return $paths[0] }
    $common = $paths[0] -split '\\'
    foreach ($p in $paths) {
        $parts = $p -split '\\'
        $n = 0
        while ($n -lt $common.Count -and $n -lt $parts.Count -and $common[$n] -eq $parts[$n]) { $n++ }
        if ($n -eq 0) { throw "Snapshot $($Snapshot.short_id) has no common folder." }
        $common = @($common[0..($n - 1)])
    }
    $common -join '\'
}

# D:\projects\x -> /D/projects/x, the form restic uses inside a snapshot.
function ConvertTo-ResticPath([string]$Path) {
    '/' + ($Path -replace ':', '' -replace '\\', '/').TrimEnd('/')
}

# Folder for a tag: a config mapping whose repo name matches, else the tag itself.
function Get-TagFolder([string]$Tag) {
    $folders = (Get-PmConfig)['folders']
    foreach ($key in $folders.Keys) {
        if (($key -split '/')[-1] -eq $Tag) { return $folders[$key] }
    }
    $Tag
}

function Invoke-Restore([string]$Root, [string]$Name, [string]$Snapshot, [string]$Target, [switch]$Force, [switch]$DryRun) {
    Assert-Command restic
    Assert-ResticPassword
    if (-not $env:RESTIC_REPOSITORY) { throw 'RESTIC_REPOSITORY is not set.' }

    $snaps = Get-Snapshots
    if ($Snapshot) {
        $snap = $snaps | Where-Object { $_.id -like "$Snapshot*" } | Select-Object -First 1
        if (-not $snap) { throw "No snapshot '$Snapshot' in $env:RESTIC_REPOSITORY." }
        if (-not $Name) { $Name = @($snap.tags)[0] }
    }
    if (-not $Name) {
        $tags = Get-SnapshotTags $snaps
        if ($tags.Count -eq 0) { throw "No tagged snapshots in $env:RESTIC_REPOSITORY." }
        $line = { param($t) '{0,-28} {1:yyyy-MM-dd HH:mm}  {2,3}x  {3}' -f $t.tag, [datetime]$t.latest.time, $t.count, (Get-SnapshotRoot $t.latest) }
        $pick = Select-Item $tags 'project' $line { param($t) $t.tag }
        if (-not $pick) { Write-Host 'Cancelled.'; return }
        $Name = $pick.tag
    }

    $dest = if ($Target) { $Target } else { Join-Path $Root (Get-TagFolder $Name) }
    $dest = [IO.Path]::GetFullPath($dest)

    # A project already set up here may back up to a different repository.
    $configFile = Join-Path $dest $ConfigName
    if (Test-Path $configFile) {
        $repository = (Get-Content $configFile -Raw | ConvertFrom-Json).repository
        if ($repository -and $repository -ne $env:RESTIC_REPOSITORY) {
            Write-Host "Using $repository from $configFile"
            $env:RESTIC_REPOSITORY = $repository
            $snaps = Get-Snapshots
        }
    }

    if (-not $Snapshot) {
        $snap = $snaps | Where-Object { $Name -in @($_.tags) } | Select-Object -First 1
        if (-not $snap) { throw "No snapshots tagged '$Name' in $env:RESTIC_REPOSITORY." }
    } elseif ($Name -notin @($snap.tags)) {
        throw "Snapshot $($snap.short_id) is not tagged '$Name'."
    }

    $source = Get-SnapshotRoot $snap
    Write-Step "Restoring $Name from snapshot $($snap.short_id) ($([datetime]$snap.time | Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    Write-Host "  from $source"
    Write-Host "  to   $dest"

    if (-not $DryRun -and -not $Force -and (Test-Path $dest) -and (Get-ChildItem $dest -Force | Select-Object -First 1)) {
        Write-Host "$dest is not empty. Files in the snapshot overwrite files with the same name; other files are left alone." -ForegroundColor Yellow
        if (-not (Confirm-Action 'Restore into it?')) { Write-Host 'Cancelled.'; return }
    }

    $resticArgs = @('restore', "$($snap.id):$(ConvertTo-ResticPath $source)", '--target', $dest)
    if ($DryRun) { $resticArgs += '--dry-run', '-v' }
    restic @resticArgs
    if ($LASTEXITCODE -ne 0) { throw "restic restore failed (exit $LASTEXITCODE)." }
    if ($DryRun) { Write-Host 'Dry run - nothing written.' -ForegroundColor Green; return }

    # .restic is excluded from backups by default; put the default files back.
    if (Test-Path (Join-Path $dest $ConfigName)) { Initialize-ResticFiles $dest }
    Write-Host "Restored to $dest" -ForegroundColor Green
    if (-not (Test-Path (Join-Path $dest '.git'))) {
        Write-Host 'No .git here: git history is not in restic backups. To reattach it, run in that folder:'
        Write-Host '  git init; git remote add origin <url>; git fetch; git reset origin/<branch>'
    }
}

function Manage-Project {
    <#
    .SYNOPSIS
        pm clone [repo] | pm init [name] | pm save [project]  -- each takes --all.
        pm restore [project]
    .DESCRIPTION
        clone  Clone a GitHub repo (asks with a list if no name) and set up backups.
               -Folder clones into that folder instead of the repo name and remembers it.
               --all clones every repo you own.
        init   Create a project folder, or adopt an existing one, and set up backups.
               Asks for a name if none is given. --all sets up every folder not yet set up.
        save   Commit and push, then back up to OneDrive with restic.
               --all saves every project that is set up.
        restore  Restore a project's latest restic snapshot (asks with a list of tags if no name).
               -Snapshot picks another snapshot, -Target another folder, -DryRun previews.
               Asks before writing into a non-empty folder unless -Force.
        With --all any name is ignored. Everything works under -Root, default the current folder.
    .EXAMPLE
        pm clone flario
    .EXAMPLE
        pm clone homelab -Folder _homelab
    .EXAMPLE
        pm init my-tool
    .EXAMPLE
        pm save -Message "fix stuff"
    .EXAMPLE
        pm save --all -NoPush
    .EXAMPLE
        pm restore holdclick -DryRun
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateSet('clone', 'init', 'save', 'restore')]
        [string]$Action,

        [Parameter(Position = 1)]
        [string]$Name,

        [string]$Root = (Get-Location).Path,
        [string]$Owner,
        [string]$Folder,
        [string]$Message,
        [string]$Snapshot,
        [string]$Target,
        [switch]$All,
        [switch]$NoPush,
        [switch]$Force,
        [switch]$DryRun,

        # Catches GNU-style --all, which PowerShell would otherwise treat as a value.
        [Parameter(ValueFromRemainingArguments)]
        [string[]]$Rest
    )
    $ErrorActionPreference = 'Stop'

    if ('--all' -in (@($Name) + @($Rest))) { $All = $true }
    if ($All -and $Folder) { throw '-Folder names a single repo; it cannot be used with --all.' }
    if ($All -and $Action -eq 'restore') { throw "--all is not valid with 'restore'." }
    if ($All) { $Name = $null }
    elseif ($Rest) { throw "Unexpected argument: $($Rest -join ' ')" }

    $restoreOnly = 'Snapshot', 'Target', 'Force', 'DryRun'
    $bad = switch ($Action) {
        'clone'   { @('Message', 'NoPush') + $restoreOnly }
        'init'    { @('Owner', 'Folder', 'Message', 'NoPush') + $restoreOnly }
        'save'    { @('Owner', 'Folder') + $restoreOnly }
        'restore' { 'Owner', 'Folder', 'Message', 'NoPush' }
    }
    foreach ($key in $bad) {
        if ($PSBoundParameters.ContainsKey($key)) { throw "-$key is not valid with '$Action'." }
    }

    switch ($Action) {
        'clone'   { Invoke-Clone $Root $Name $Folder $Owner -All:$All }
        'init'    { Invoke-Init $Root $Name -All:$All }
        'save'    { Invoke-Save $Root $Name $Message -NoPush:$NoPush -All:$All }
        'restore' { Invoke-Restore $Root $Name $Snapshot $Target -Force:$Force -DryRun:$DryRun }
    }
}

Set-Alias pm Manage-Project

Export-ModuleMember -Function Manage-Project -Alias pm
