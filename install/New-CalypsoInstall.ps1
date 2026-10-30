<#
.SYNOPSIS
    Crea una instalación limpia de Calypso en modo desatendido (install4j).

.DESCRIPTION
    1. Valida el instalador, el varfile plantilla, los drivers JDBC y el destino (que debe no existir o estar vacío).
    2. Genera un varfile temporal a partir de la plantilla, sustituyendo sys.installationDir
       (y jdbcDriverFiles si se indica).
    3. Ejecuta el instalador con -q -varfile <varfile temporal> y espera a que termine.
    4. Comprueba el código de salida y que existan las carpetas básicas de la instalación.

.PARAMETER DestinationDir
    Carpeta de instalación. No debe existir o debe estar vacía.

.PARAMETER InstallerPath
    Ruta del instalador de Calypso.

.PARAMETER VarFileTemplate
    Varfile plantilla (formato install4j / .properties). Por defecto, el que está junto a este script.

.PARAMETER JdbcDriverFiles
    Opcional. Rutas de los drivers JDBC separadas por ';'. Sustituye el valor de jdbcDriverFiles de la plantilla.

.EXAMPLE
    .\New-CalypsoInstall.ps1 -DestinationDir D:\calypso_v19\build-node

.EXAMPLE
    .\New-CalypsoInstall.ps1 -DestinationDir D:\calypso_v19\pre `
        -JdbcDriverFiles 'D:\drivers\ojdbc8-23.26.3.0.0.jar'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $DestinationDir,

    [string] $InstallerPath = 'D:\calypso_v19\dowloads\calypso-installer-19.26.10.1-win64-rel.exe',

    [string] $VarFileTemplate = (Join-Path $PSScriptRoot 'calypso-19.26.10.1.varfile'),

    [string] $JdbcDriverFiles
)

$ErrorActionPreference = 'Stop'

# --- Formato .properties de install4j: '\' -> '\\'  y  ':' -> '\:' -------------------------
function ConvertTo-PropertyPath([string] $Path) {
    return $Path.Replace('\', '\\').Replace(':', '\:')
}
function ConvertFrom-PropertyPath([string] $Value) {
    return $Value.Replace('\:', ':').Replace('\\', '\')
}

# --- 1. Validaciones ------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $InstallerPath -PathType Leaf)) {
    throw "No existe el instalador: $InstallerPath"
}
if (-not (Test-Path -LiteralPath $VarFileTemplate -PathType Leaf)) {
    throw "No existe el varfile plantilla: $VarFileTemplate"
}

$DestinationDir = [System.IO.Path]::GetFullPath($DestinationDir)
if ($DestinationDir -match '[^\x20-\x7E]') {
    throw "La ruta de destino contiene caracteres no ASCII (no soportados por el varfile): $DestinationDir"
}
if ((Test-Path -LiteralPath $DestinationDir) -and
    (Get-ChildItem -LiteralPath $DestinationDir -Force | Select-Object -First 1)) {
    throw "El destino existe y no está vacío: $DestinationDir"
}

$template = Get-Content -LiteralPath $VarFileTemplate
if (-not ($template | Where-Object { $_ -like 'sys.installationDir=*' })) {
    throw "La plantilla no contiene sys.installationDir: $VarFileTemplate"
}

# Drivers JDBC: los indicados por parámetro o los de la plantilla
if ($JdbcDriverFiles) {
    $jdbcPaths = $JdbcDriverFiles -split ';' | Where-Object { $_ }
} else {
    $jdbcLine  = $template | Where-Object { $_ -like 'jdbcDriverFiles=*' } | Select-Object -First 1
    $jdbcPaths = @()
    if ($jdbcLine) {
        $jdbcPaths = ($jdbcLine.Substring('jdbcDriverFiles='.Length) -split ';') |
                     Where-Object { $_ } | ForEach-Object { ConvertFrom-PropertyPath $_ }
    }
}
foreach ($p in $jdbcPaths) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "No existe el driver JDBC: $p" }
}

# --- 2. Varfile temporal ---------------------------------------------------------------------
$varFile = Join-Path ([System.IO.Path]::GetTempPath()) ('calypso-install-{0:yyyyMMdd-HHmmss}.varfile' -f (Get-Date))

$lines = foreach ($line in $template) {
    if ($line -like 'sys.installationDir=*') {
        'sys.installationDir=' + (ConvertTo-PropertyPath $DestinationDir)
    } elseif ($JdbcDriverFiles -and $line -like 'jdbcDriverFiles=*') {
        'jdbcDriverFiles=' + ((($jdbcPaths | ForEach-Object { ConvertTo-PropertyPath $_ }) -join ';') + ';')
    } else {
        $line
    }
}
[System.IO.File]::WriteAllLines($varFile, [string[]] $lines, [System.Text.Encoding]::ASCII)

# --- 3. Instalación --------------------------------------------------------------------------
Write-Host "Instalador : $InstallerPath"
Write-Host "Destino    : $DestinationDir"
Write-Host "Varfile    : $varFile"
$start = Get-Date

try {
    $proc = Start-Process -FilePath $InstallerPath `
                          -ArgumentList @('-q', '-varfile', "`"$varFile`"") `
                          -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw "El instalador terminó con código $($proc.ExitCode). Revisa $DestinationDir\.install4j\installation.log"
    }
} finally {
    Remove-Item -LiteralPath $varFile -ErrorAction SilentlyContinue
}

# --- 4. Comprobaciones -----------------------------------------------------------------------
$expected = @(
    'client\lib',
    'server',
    'custom-extensions\custom-projects',
    'tools\gradle',
    'tools\calypso-patcher',
    'tools\local-deployer',
    'patch.bat'
)
$missing = $expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $DestinationDir $_)) }
if ($missing) {
    throw "Instalación incompleta. Falta: $($missing -join ', ')"
}

$elapsed = (Get-Date) - $start
Write-Host ("Instalación completada en {0:mm\:ss} -> {1}" -f $elapsed, $DestinationDir)
