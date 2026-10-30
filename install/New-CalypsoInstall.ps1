<#
.SYNOPSIS
    Creates a clean, unattended Calypso installation (install4j) for an environment.

.DESCRIPTION
    1. Loads the environment tokens (tokens\tokens.COMMON + tokens\tokens.<ENV> + secrets + overrides).
    2. Validates the installer (INSTALLER_PATH), the JDBC drivers (JDBC_DRIVER_FILES) and the target
       directory (INSTALL_DIR), which must not exist or must be empty.
    3. Renders the install\calypso-19.26.10.1.varfile template into a temporary varfile.
    4. Runs the installer with -q -varfile <temporary> and waits for it to finish.
    5. Checks the exit code and that the basic installation folders exist.

    Tokens used: INSTALL_DIR, INSTALLER_PATH, JDBC_DRIVER_FILES.

.PARAMETER Environment
    Environment: name of the tokens\tokens.<Environment> file (DEV, PRE, PRO, BUILD, ...).

.PARAMETER TokenOverride
    Optional. Tokens that override those of the file, e.g. @{ INSTALL_DIR = 'D:\calypso_v19\other' }.

.PARAMETER VarFileTemplate
    Varfile template. Defaults to the one next to this script.

.EXAMPLE
    .\install\New-CalypsoInstall.ps1 -Environment DEV

.EXAMPLE
    .\install\New-CalypsoInstall.ps1 -Environment DEV -TokenOverride @{ INSTALL_DIR = 'D:\calypso_v19\other' }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Environment,

    [hashtable] $TokenOverride = @{},

    [string] $VarFileTemplate = (Join-Path $PSScriptRoot 'calypso-19.26.10.1.varfile')
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\Tokens.psm1') -Force
Import-Module (Join-Path $repoRoot 'lib\Processes.psm1') -Force

# --- 1. Tokens ------------------------------------------------------------------------------
$tokens = Get-EnvironmentTokens -Environment $Environment -RepoRoot $repoRoot -Override $TokenOverride

$required = @('INSTALL_DIR', 'INSTALLER_PATH', 'JDBC_DRIVER_FILES')
$missing  = @($required | Where-Object { -not $tokens.Contains($_) })
if ($missing.Count -gt 0) {
    throw "Missing tokens in environment '$Environment': $($missing -join ', ')"
}

$installDir    = [System.IO.Path]::GetFullPath($tokens['INSTALL_DIR'])
$installerPath = $tokens['INSTALLER_PATH']
$jdbcPaths     = @($tokens['JDBC_DRIVER_FILES'] -split ';' | Where-Object { $_ })
$tokens['INSTALL_DIR'] = $installDir

# --- 2. Validation --------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $installerPath -PathType Leaf)) {
    throw "Installer not found (INSTALLER_PATH): $installerPath"
}
foreach ($p in $jdbcPaths) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "JDBC driver not found (JDBC_DRIVER_FILES): $p" }
}
if ((Test-Path -LiteralPath $installDir) -and
    (Get-ChildItem -LiteralPath $installDir -Force | Select-Object -First 1)) {
    throw "Target directory (INSTALL_DIR) exists and is not empty: $installDir"
}

# --- 3. Temporary varfile -------------------------------------------------------------------
$varFile = Join-Path ([System.IO.Path]::GetTempPath()) ('calypso-install-{0}-{1:yyyyMMdd-HHmmss}.varfile' -f $Environment, (Get-Date))
Expand-TokenTemplate -Template $VarFileTemplate -Destination $varFile -Tokens $tokens

# --- 4. Installation ------------------------------------------------------------------------
Write-Host "Environment : $Environment"
Write-Host "Installer   : $installerPath"
Write-Host "Target      : $installDir"
Write-Host "Varfile     : $varFile"
$start = Get-Date

# The installer runs the installation's own Gradle several times (installLibraries, createClientPackage, patch...).
# By default Gradle starts a daemon that outlives the installer and locks files in INSTALL_DIR.
# With org.gradle.daemon=false in GRADLE_OPTS (inherited by the installer) no daemon is created.
$previousGradleOpts = $env:GRADLE_OPTS
$env:GRADLE_OPTS = (@($previousGradleOpts, '-Dorg.gradle.daemon=false') | Where-Object { $_ }) -join ' '

try {
    # Wait only for the installer, not for its children: if it left a process alive, Start-Process -Wait would never return.
    $exitCode = Invoke-ProcessAndWait -FilePath $installerPath -ArgumentList @('-q', '-varfile', "`"$varFile`"")
    if ($exitCode -ne 0) {
        throw "Installer exited with code $exitCode. Check $installDir\.install4j\installation.log"
    }
} finally {
    $env:GRADLE_OPTS = $previousGradleOpts
    Remove-Item -LiteralPath $varFile -ErrorAction SilentlyContinue
}

# Processes left alive by the installer that use the installation (they lock files)
$leftover = @(Get-ProcessesUsing -Dir $installDir)
foreach ($p in $leftover) {
    Write-Warning "The installer left a process using the installation: $(Format-ProcessInfo $p)"
}

# --- 5. Checks ------------------------------------------------------------------------------
$expected = @(
    'client\lib',
    'server',
    'custom-extensions\custom-projects',
    'tools\gradle',
    'tools\calypso-patcher',
    'tools\local-deployer',
    'patch.bat'
)
$notFound = @($expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installDir $_)) })
if ($notFound.Count -gt 0) {
    throw "Incomplete installation. Missing: $($notFound -join ', ')"
}

$elapsed = (Get-Date) - $start
Write-Host ("Installation completed in {0:mm\:ss} -> {1}" -f $elapsed, $installDir)
