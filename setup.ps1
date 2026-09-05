# setup.ps1 - stamp your GitHub username into the repo and prepare the first commit.
#
#   .\setup.ps1 -GitHubUser yourname
#
# Run this once, before pushing. It replaces the __GITHUB_USER__ placeholder in
# image-template.env and disk_config/iso.toml, then initialises git.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$')]
    [string]$GitHubUser,

    [string]$RepoName = 'bazzite-mattsumoto',

    # Address recorded as the commit author. Defaults to GitHub's noreply form,
    # which keeps a real address out of the public commit log.
    [string]$Email = ''
)

if (-not $Email) { $Email = "$GitHubUser@users.noreply.github.com" }

$ErrorActionPreference = 'Stop'
Set-Location -Path $PSScriptRoot

$targets = @('image-template.env', 'disk_config\iso.toml')
$changed = 0

foreach ($file in $targets) {
    if (-not (Test-Path $file)) { throw "Missing expected file: $file" }
    $raw = [System.IO.File]::ReadAllText((Resolve-Path $file))
    if ($raw -notmatch '__GITHUB_USER__') {
        Write-Host "  already stamped: $file" -ForegroundColor DarkGray
        continue
    }
    $new = $raw.Replace('__GITHUB_USER__', $GitHubUser)
    # Write back as UTF-8 without BOM and with LF endings, so the Linux build
    # runner and bootc-image-builder parse these files correctly.
    $new = $new.Replace("`r`n", "`n")
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Resolve-Path $file), $new, $utf8NoBom)
    Write-Host "  stamped: $file" -ForegroundColor Green
    $changed++
}

if ($RepoName -ne 'bazzite-mattsumoto') {
    foreach ($file in $targets) {
        $p = Resolve-Path $file
        $raw = [System.IO.File]::ReadAllText($p).Replace('bazzite-mattsumoto', $RepoName).Replace("`r`n", "`n")
        [System.IO.File]::WriteAllText($p, $raw, (New-Object System.Text.UTF8Encoding($false)))
    }
    Write-Host "  repo name set to: $RepoName" -ForegroundColor Green
}

Write-Host ""
Write-Host "Files updated: $changed" -ForegroundColor Cyan

if (-not (Test-Path '.git')) {
    git init -b main | Out-Null
    git add -A

    # Windows checkouts do not carry the POSIX executable bit, so git would
    # record these as 100644 and the Linux build runner would refuse to run
    # them. Force the mode into the index explicitly.
    $execFiles = @(
        'build_files/build.sh',
        'system_files/usr/bin/g9-display',
        'system_files/usr/bin/broadcom-wifi-fix',
        'system_files/usr/bin/hw-fixes'
    )
    foreach ($f in $execFiles) { git update-index --chmod=+x -- $f }
    Write-Host "  marked $($execFiles.Count) scripts executable in the git index" -ForegroundColor Green

    git -c user.name="$GitHubUser" -c user.email="$Email" `
        commit -m "Bazzite image with hardware fixes for X570-F / RTX 3080 / Odyssey G9" | Out-Null
    Write-Host "Git repository initialised with an initial commit." -ForegroundColor Green
} else {
    Write-Host "Git repo already exists - commit your changes manually." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Create an EMPTY repo named '$RepoName' at https://github.com/new"
Write-Host "     (public, no README - the workflows publish to ghcr.io/$GitHubUser/$RepoName)"
Write-Host "  2. git remote add origin https://github.com/$GitHubUser/$RepoName.git"
Write-Host "  3. git push -u origin main"
Write-Host "  4. On GitHub: Actions tab -> enable workflows -> run 'build.yml'"
Write-Host "  5. Packages -> $RepoName -> change visibility to Public"
Write-Host "  6. Actions -> 'build-disk.yml' -> Run workflow -> download the ISO artifact"
