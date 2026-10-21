# Install or update the ProjectTools (pm) module from GitHub. Rerun to update.
#
#   irm https://raw.githubusercontent.com/keenedge/ProjectTools/main/Install.ps1 | iex
#
# Another branch, tag or commit:
#
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/keenedge/ProjectTools/main/Install.ps1))) -Ref <ref>

param([string]$Ref = 'main')

# Run in a child scope so nothing leaks into the caller's session when piped to iex.
& {
    $ErrorActionPreference = 'Stop'
    $ModuleName = 'ProjectTools'
    $BaseUrl = "https://raw.githubusercontent.com/keenedge/ProjectTools/$Ref"
    $Files = 'ProjectTools.psm1', 'ProjectTools.psd1'

    function Write-Step([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }

    if ($PSVersionTable.PSVersion.Major -lt 7) { throw 'ProjectTools requires PowerShell 7. Run this from pwsh.' }

    $docs = [Environment]::GetFolderPath('MyDocuments')
    $dest = Join-Path $docs "PowerShell\Modules\$ModuleName"

    Write-Step "Downloading $ModuleName@$Ref"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "$ModuleName-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        foreach ($f in $Files) {
            Invoke-WebRequest -Uri "$BaseUrl/$f" -OutFile (Join-Path $tmp $f) -UseBasicParsing
            Write-Host "  $f"
        }
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item (Join-Path $tmp '*') $dest
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Add the import to the profile, replacing any older ProjectTools import line
    # (by name or by path to a .psd1/.psm1).
    $profilePath = $PROFILE.CurrentUserAllHosts
    $importLine = "Import-Module $ModuleName -DisableNameChecking"
    if (-not (Test-Path $profilePath)) { New-Item -ItemType File -Path $profilePath -Force | Out-Null }
    $lines = @(Get-Content $profilePath)
    $oldImport = "^\s*Import-Module\s+(\S*[\\/])?$ModuleName(\.ps[dm]1)?(\s|$)"
    $others = @($lines | Where-Object { $_ -notmatch $oldImport })
    if ($lines.Count -ne $others.Count + 1 -or $lines -notcontains $importLine) {
        $lines = $others + $importLine
        Set-Content -Path $profilePath -Value $lines
        Write-Step "Added '$importLine' to $profilePath"
    }

    Import-Module $ModuleName -DisableNameChecking -Force
    Write-Host "Installed $ModuleName to $dest" -ForegroundColor Green
}
