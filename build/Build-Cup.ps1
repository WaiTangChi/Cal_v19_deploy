<#
.SYNOPSIS
    Builds the .cup of the custom code on a clean, disposable build node.

.DESCRIPTION
    1. Loads the environment tokens (BUILD by default).
    2. If INSTALL_DIR contains a previous build node (marker .calypso-build-node), it is deleted.
       If it exists with any other content, the script stops without touching anything.
    3. Installs a clean Calypso (install\New-CalypsoInstall.ps1).
    4. Replaces custom-extensions\custom-projects with a clone of the source repository at -Ref.
    5. Runs: bld.bat clean build createCup --no-daemon   (from custom-extensions)
    6. Validates the .cup: exactly one *-rel.zip; version X.Y.Z if -Ref is a vX.Y.Z tag, or X.Y.Z-SNAPSHOT if it is a branch.
    7. Stores in CUP_OUTPUT_DIR:
         custom-projects-distribution-<version>.cup
         custom-projects-distribution-<version>.cup.sha256
         custom-projects-distribution-<version>.build-info.txt
       A release version is never overwritten; a SNAPSHOT is.
    8. Deletes the build node, also when something failed (unless -KeepInstall).

    Tokens used: INSTALL_DIR, INSTALLER_PATH, JDBC_DRIVER_FILES (installation),
                 SOURCE_REPO_URL, CUP_OUTPUT_DIR.

.PARAMETER Ref
    Tag (vX.Y.Z) or branch of the source repository to build.

.PARAMETER Environment
    Token file to use. Defaults to BUILD.

.PARAMETER TokenOverride
    Optional. Tokens that override those of the file.

.PARAMETER KeepInstall
    Do not delete the build node at the end (for troubleshooting). The next run will delete it.

.EXAMPLE
    .\build\Build-Cup.ps1 -Ref develop

.EXAMPLE
    .\build\Build-Cup.ps1 -Ref v1.4.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Ref,

    [string] $Environment = 'BUILD',

    [hashtable] $TokenOverride = @{},

    [switch] $KeepInstall
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\Tokens.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Processes.psm1') -Force
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$MarkerName = '.calypso-build-node'

function Write-Step([string] $Text) { Write-Host ''; Write-Host "=== $Text" -ForegroundColor Cyan }

function Invoke-Native {
    # Runs an external command and fails if the exit code is not 0
    param([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory = (Get-Location).Path)
    Push-Location $WorkingDirectory
    try {
        & $FilePath @Arguments
        if ($LASTEXITCODE -ne 0) { throw "'$FilePath $($Arguments -join ' ')' exited with code $LASTEXITCODE" }
    } finally { Pop-Location }
}

function Remove-BuildNode([string] $Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $Dir $MarkerName))) {
        throw "Not deleting '$Dir': it has no $MarkerName marker (it is not a build node created by this script)"
    }
    Write-Host "Deleting build node: $Dir"
    $null = Stop-ProcessesUsing -Dir $Dir

    $attempts = 5
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction Stop
            return
        } catch {
            if ($i -eq $attempts) {
                # A partial delete may have removed the marker: restore it so the next run can clean up
                if (Test-Path -LiteralPath $Dir) {
                    Set-Content -LiteralPath (Join-Path $Dir $MarkerName) -Value "Build node (incomplete delete) $(Get-Date -Format s)" -ErrorAction SilentlyContinue
                }
                throw "Could not delete '$Dir' after $attempts attempts: $($_.Exception.Message)"
            }
            Write-Host "Attempt $i failed ($($_.Exception.Message)). Retrying..."
            Start-Sleep -Seconds (2 * $i)
            $null = Stop-ProcessesUsing -Dir $Dir
        }
    }
}

function Get-CupInfo([string] $CupPath) {
    # Returns the -rel.zip name and the .cdf version; fails if the .cup does not contain exactly one -rel.zip
    $cup = [System.IO.Compression.ZipFile]::OpenRead($CupPath)
    try {
        $rel = @($cup.Entries | Where-Object { $_.FullName -like '*-rel.zip' -and $_.FullName -notlike '*/*' })
        if ($rel.Count -ne 1) {
            throw "The .cup must contain exactly one *-rel.zip and it contains $($rel.Count): $(($rel | ForEach-Object FullName) -join ', ')"
        }
        $relStream = $rel[0].Open()
        try {
            $relZip = New-Object System.IO.Compression.ZipArchive($relStream, [System.IO.Compression.ZipArchiveMode]::Read)
            $cdf = @($relZip.Entries | Where-Object { $_.FullName -like '.metadata/distributions/*.cdf' })
            if ($cdf.Count -ne 1) { throw "The -rel.zip must contain exactly one .cdf and it contains $($cdf.Count)" }
            $reader = New-Object System.IO.StreamReader($cdf[0].Open())
            try { [xml] $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
            $files = @($xml.'calypso-distribution'.file | ForEach-Object { $_.path })
            return [pscustomobject]@{
                RelZip  = $rel[0].FullName
                Name    = $xml.'calypso-distribution'.name
                Version = $xml.'calypso-distribution'.version
                Files   = $files
            }
        } finally { $relStream.Dispose() }
    } finally { $cup.Dispose() }
}

# --- 1. Tokens ------------------------------------------------------------------------------
Write-Step "Tokens for environment $Environment"
$tokens  = Get-EnvironmentTokens -Environment $Environment -RepoRoot $repoRoot -Override $TokenOverride
$missing = @('INSTALL_DIR', 'SOURCE_REPO_URL', 'CUP_OUTPUT_DIR') | Where-Object { -not $tokens.Contains($_) }
if ($missing) { throw "Missing tokens in environment '$Environment': $($missing -join ', ')" }

$installDir = [System.IO.Path]::GetFullPath($tokens['INSTALL_DIR'])
$outputDir  = [System.IO.Path]::GetFullPath($tokens['CUP_OUTPUT_DIR'])
$sourceUrl  = $tokens['SOURCE_REPO_URL']

$isTag = $Ref -match '^v(\d+\.\d+\.\d+)$'
$expectedVersion = if ($isTag) { $Matches[1] } else { $null }

Write-Host "Ref        : $Ref $(if ($isTag) { "(tag -> version $expectedVersion)" } else { '(branch -> SNAPSHOT version)' })"
Write-Host "Source     : $sourceUrl"
Write-Host "Build node : $installDir"
Write-Host "Output     : $outputDir"

foreach ($tool in 'git') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "'$tool' not found in PATH" }
}

# --- 2. Previous node -----------------------------------------------------------------------
if (Test-Path -LiteralPath $installDir) {
    if (Get-ChildItem -LiteralPath $installDir -Force | Select-Object -First 1) {
        Write-Step 'Previous build node'
        Remove-BuildNode $installDir
    }
}

$start = Get-Date
$ownsDir = $true      # from here on INSTALL_DIR does not exist or is empty: anything created in it is ours
try {
    # --- 3. Clean installation --------------------------------------------------------------
    Write-Step 'Clean Calypso installation'
    & (Join-Path $repoRoot 'install\New-CalypsoInstall.ps1') -Environment $Environment -TokenOverride $TokenOverride
    Set-Content -LiteralPath (Join-Path $installDir $MarkerName) -Value "Build node created by Build-Cup.ps1 on $(Get-Date -Format s)"
    # The node is disposable: anything the installer left alive is stopped so it does not lock files
    $null = Stop-ProcessesUsing -Dir $installDir

    # --- 4. Sources -------------------------------------------------------------------------
    Write-Step "Clone of $sourceUrl ($Ref)"
    $extDir    = Join-Path $installDir 'custom-extensions'
    $sourceDir = Join-Path $extDir 'custom-projects'
    if (Test-Path -LiteralPath $sourceDir) { Remove-Item -LiteralPath $sourceDir -Recurse -Force }
    Invoke-Native git @('-c', 'advice.detachedHead=false', 'clone', '--quiet', '--depth', '1', '--branch', $Ref, $sourceUrl, $sourceDir)
    $commit = (& git -C $sourceDir rev-parse HEAD).Trim()
    Write-Host "Commit     : $commit"

    # --- 5. Build ---------------------------------------------------------------------------
    Write-Step 'bld.bat clean build createCup'
    Invoke-Native (Join-Path $extDir 'bld.bat') @('clean', 'build', 'createCup', '--no-daemon') -WorkingDirectory $extDir

    # --- 6. Validation ----------------------------------------------------------------------
    Write-Step '.cup validation'
    $cups = @(Get-ChildItem -LiteralPath (Join-Path $extDir 'build\distributions') -Filter '*.cup' -File -ErrorAction SilentlyContinue)
    if ($cups.Count -ne 1) { throw "Expected exactly one .cup in build\distributions and found $($cups.Count)" }
    $cupPath = $cups[0].FullName
    $info = Get-CupInfo $cupPath
    Write-Host "Distribution: $($info.Name) $($info.Version)"
    $info.Files | ForEach-Object { Write-Host "  $_" }

    if ($isTag) {
        if ($info.Version -ne $expectedVersion) {
            throw "The .cup version ($($info.Version)) does not match tag $Ref (expected $expectedVersion). Check 'version' in gradle.properties."
        }
    } elseif ($info.Version -notlike '*-SNAPSHOT') {
        throw "A branch ($Ref) must produce a -SNAPSHOT version and the .cup has $($info.Version). Releases are built from a vX.Y.Z tag."
    }

    # --- 7. Store ---------------------------------------------------------------------------
    Write-Step 'Store .cup'
    $baseName = "custom-projects-distribution-$($info.Version)"
    $target   = Join-Path $outputDir "$baseName.cup"
    if ((Test-Path -LiteralPath $target) -and $info.Version -notlike '*-SNAPSHOT') {
        throw "$target already exists. A release version is never overwritten."
    }
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Copy-Item -LiteralPath $cupPath -Destination $target -Force

    $sha = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath "$target.sha256" -Value "$sha  $baseName.cup" -Encoding ASCII
    [System.IO.File]::WriteAllLines((Join-Path $outputDir "$baseName.build-info.txt"), [string[]] @(
        "version=$($info.Version)",
        "ref=$Ref",
        "commit=$commit",
        "source=$sourceUrl",
        "built=$(Get-Date -Format s)",
        "builder=$env:COMPUTERNAME",
        "sha256=$sha",
        "files=$($info.Files -join ';')"
    ), (New-Object System.Text.UTF8Encoding($false)))   # UTF-8 without BOM: key=value file readable by any tool
    Write-Host "Stored     : $target"
    Write-Host "SHA256     : $sha"
}
finally {
    # --- 8. Cleanup -------------------------------------------------------------------------
    if ($ownsDir -and (Test-Path -LiteralPath $installDir)) {
        # If the installation failed halfway it may have no marker: add it so it can be deleted now or on the next run
        $marker = Join-Path $installDir $MarkerName
        if (-not (Test-Path -LiteralPath $marker)) {
            Set-Content -LiteralPath $marker -Value "Build node (incomplete) created by Build-Cup.ps1 on $(Get-Date -Format s)"
        }
        if ($KeepInstall) {
            Write-Host "Build node kept at $installDir (-KeepInstall)"
        } else {
            Write-Step 'Build node deletion'
            try { Remove-BuildNode $installDir }
            catch { Write-Warning "Could not delete the build node: $($_.Exception.Message)" }
        }
    }
}

$elapsed = (Get-Date) - $start
Write-Host ''
Write-Host ("Build completed in {0:hh\:mm\:ss}" -f $elapsed) -ForegroundColor Green
