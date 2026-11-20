# Install selected Windows apps from the helper CD's offline cache.
#
# The manifest (apps.json) pins the official URL, SHA-256 and silent arguments
# for each app. Installers are looked up in .\apps next to this script and in
# %ProgramData%\WindowsSlim\apps. Missing files can be downloaded from the
# official URL with -Download, but the helper CD normally ships them.

[CmdletBinding()]
param(
    [string[]]$App,
    [switch]$All,
    [switch]$List,
    [switch]$Verify,
    [switch]$Download,
    [switch]$Force,
    [string]$Manifest = "$PSScriptRoot\apps.json",
    [string]$CacheDir = "$env:ProgramData\WindowsSlim\apps"
)

$ErrorActionPreference = 'Continue'
$script:Failures = 0

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {
    # PowerShell 7 on Windows already negotiates TLS 1.2+.
}

function Get-AppList {
    if (-not (Test-Path -LiteralPath $Manifest)) {
        throw "App manifest not found: $Manifest"
    }

    $data = Get-Content -LiteralPath $Manifest -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($data.PSObject.Properties.Name -contains 'apps') {
        return @($data.apps)
    }
    return @($data)
}

function Test-AppInstalled {
    param($Entry)

    if ($Entry.detectPath) {
        return (Test-Path -LiteralPath $Entry.detectPath)
    }
    if ($Entry.detectRegistry) {
        $value = Get-ItemProperty -Path $Entry.detectRegistry -Name $Entry.detectValue -ErrorAction SilentlyContinue
        return ($null -ne $value)
    }
    return $false
}

function Get-InstallerPath {
    param($Entry)

    $candidates = @()
    if ($PSScriptRoot) {
        $candidates += (Join-Path -Path (Join-Path -Path $PSScriptRoot -ChildPath 'apps') -ChildPath $Entry.file)
    }
    if ($CacheDir) {
        $candidates += (Join-Path -Path $CacheDir -ChildPath $Entry.file)
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-FileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
}

function Get-VerifiedInstaller {
    param(
        $Entry,
        [switch]$AllowDownload
    )

    $path = Get-InstallerPath -Entry $Entry

    if (-not $path -and $AllowDownload) {
        if (-not (Test-Path -LiteralPath $CacheDir)) {
            New-Item -Path $CacheDir -ItemType Directory -Force | Out-Null
        }
        $path = Join-Path -Path $CacheDir -ChildPath $Entry.file
        $partial = "$path.part"
        Write-Host ("Downloading {0} from {1} ..." -f $Entry.name, $Entry.url)
        try {
            Invoke-WebRequest -Uri $Entry.url -OutFile $partial -UseBasicParsing -ErrorAction Stop
            Move-Item -LiteralPath $partial -Destination $path -Force -ErrorAction Stop
        } catch {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
            Write-Host ("Download failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
            return $null
        }
    }

    if (-not $path) {
        Write-Host ("Installer missing: {0}" -f $Entry.file) -ForegroundColor Red
        Write-Host ("Put it in {0} or run with -Download." -f (Join-Path $PSScriptRoot 'apps')) -ForegroundColor Yellow
        return $null
    }

    try {
        $actual = Get-FileSha256 -Path $path
    } catch {
        Write-Host ("Could not hash {0}: {1}" -f $path, $_.Exception.Message) -ForegroundColor Red
        return $null
    }

    if ($Entry.sha256 -and $actual -ne $Entry.sha256.ToLowerInvariant()) {
        Write-Host ("SHA-256 mismatch for {0}" -f $Entry.file) -ForegroundColor Red
        Write-Host ("  expected {0}" -f $Entry.sha256)
        Write-Host ("  actual   {0}" -f $actual)
        return $null
    }

    return $path
}

function Install-App {
    param(
        $Entry,
        [switch]$AllowDownload
    )

    if ((Test-AppInstalled -Entry $Entry) -and -not $Force -and -not $Verify) {
        Write-Host ("{0} is already installed. Use -Force to reinstall." -f $Entry.name) -ForegroundColor Yellow
        return
    }

    $installer = Get-VerifiedInstaller -Entry $Entry -AllowDownload:$AllowDownload
    if (-not $installer) {
        $script:Failures++
        return
    }

    if ($Verify) {
        Write-Host ("Verified {0} ({1})" -f $Entry.name, $installer) -ForegroundColor Green
        return
    }

    Write-Host ("Installing {0} silently ..." -f $Entry.name)
    try {
        $startArgs = @{
            FilePath    = $installer
            Wait        = $true
            PassThru    = $true
            ErrorAction = 'Stop'
        }
        if ($Entry.silentArgs) {
            $startArgs['ArgumentList'] = $Entry.silentArgs
        }
        $process = Start-Process @startArgs
        if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
            Write-Host ("{0} installed (exit {1})." -f $Entry.name, $process.ExitCode) -ForegroundColor Green
        } else {
            Write-Host ("{0} installer exited with {1}." -f $Entry.name, $process.ExitCode) -ForegroundColor Red
            $script:Failures++
        }
    } catch {
        Write-Host ("Installer failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        $script:Failures++
    }
}

function Show-AppMenu {
    param(
        [object[]]$Apps,
        [switch]$AllowDownload
    )

    Write-Host ''
    Write-Host 'Windows apps' -ForegroundColor Cyan
    Write-Host ('-' * 64)
    for ($i = 0; $i -lt $Apps.Count; $i++) {
        $entry = $Apps[$i]
        $status = if (Test-AppInstalled -Entry $entry) { 'installed' } else { 'not installed' }
        $source = if (Get-InstallerPath -Entry $entry) { 'local' } else { 'missing' }
        Write-Host ('  {0,2}) {1}  [{2}, {3}]' -f ($i + 1), $entry.name, $status, $source)
        Write-Host ('      {0}' -f $entry.description) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host '   A) Install all missing apps'
    Write-Host ('   D) Downloads from official URLs: {0}' -f $(if ($AllowDownload) { 'enabled' } else { 'disabled' }))
    Write-Host '   0) Back'
    Write-Host ''
}

function Install-Selection {
    param(
        [object[]]$Entries,
        [switch]$AllowDownload
    )

    foreach ($entry in $Entries) {
        Install-App -Entry $entry -AllowDownload:$AllowDownload
    }
}

$apps = Get-AppList
$requested = @()
if ($App) {
    foreach ($item in $App) {
        foreach ($part in ($item -split ',')) {
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $requested += $part.Trim()
            }
        }
    }
}

if ($List) {
    Show-AppMenu -Apps $apps -AllowDownload:$Download
    return
}

if ($Verify) {
    $targets = if ($requested.Count -gt 0) { @($apps | Where-Object { $requested -contains $_.id -or $requested -contains $_.name }) } else { $apps }
    if (-not $targets) {
        Write-Host 'No matching apps.' -ForegroundColor Red
        return
    }
    foreach ($entry in $targets) {
        Install-App -Entry $entry -AllowDownload:$Download
    }
    if ($script:Failures -gt 0) {
        Write-Host ('{0} app(s) failed verification.' -f $script:Failures) -ForegroundColor Yellow
    }
    return
}

if ($All -or $requested.Count -gt 0) {
    $targets = if ($All) {
        $apps
    } else {
        @($apps | Where-Object { $requested -contains $_.id -or $requested -contains $_.name })
    }

    if (-not $targets -or $targets.Count -eq 0) {
        Write-Host 'No matching apps.' -ForegroundColor Red
        return
    }

    Install-Selection -Entries $targets -AllowDownload:$Download
    if ($script:Failures -gt 0) {
        Write-Host ('{0} app(s) failed.' -f $script:Failures) -ForegroundColor Yellow
    }
    return
}

while ($true) {
    Show-AppMenu -Apps $apps -AllowDownload:$Download

    try {
        $choice = Read-Host 'Select'
    } catch {
        return
    }
    if ([string]::IsNullOrWhiteSpace($choice)) {
        continue
    }
    $choice = $choice.Trim()

    if ($choice -eq '0') {
        return
    }
    if ($choice -match '^[Aa]$') {
        Install-Selection -Entries $apps -AllowDownload:$Download
        continue
    }
    if ($choice -match '^[Dd]$') {
        $Download = $true
        continue
    }

    $index = 0
    if ([int]::TryParse($choice, [ref]$index) -and $index -ge 1 -and $index -le $apps.Count) {
        Install-App -Entry $apps[$index - 1] -AllowDownload:$Download
    } else {
        Write-Host 'Unknown choice.' -ForegroundColor Yellow
        Start-Sleep -Milliseconds 700
    }
}