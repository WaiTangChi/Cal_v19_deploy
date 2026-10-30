<#
.SYNOPSIS
    Renders the Calypso environment property files of one or more environments into the user's Calypso folder.

.DESCRIPTION
    For each environment <ENV>:
    1. Loads the environment tokens (tokens\tokens.COMMON + tokens\tokens.<ENV> + secrets\tokens.<ENV>.secrets + overrides).
    2. Takes every template in envProperties\ whose name ends with .<ENV> (e.g. calypsouser.properties.DEV).
    3. Renders each template (escaping values according to the file format; *.properties.<ENV> = .properties)
       and fails without writing anything if a token is missing.
    4. Writes the result into the target folder (default %USERPROFILE%\Calypso) with the same file name:
         - unchanged file          -> left as is
         - changed existing file   -> previous version backed up as <name>.<yyyyMMdd-HHmmss>.bak, then replaced
         - new file                -> created

    All templates of all requested environments are rendered before anything is written, so a missing
    token in any of them leaves the target folder untouched.

.PARAMETER Environment
    One or more environments (DEV, INT, PRE, PRO, ...).

.PARAMETER TemplateDir
    Folder with the tokenized templates. Defaults to envProperties\ in this repository.

.PARAMETER TargetDir
    Destination folder. Defaults to the Calypso folder in the user profile (%USERPROFILE%\Calypso).

.PARAMETER TokenOverride
    Optional. Tokens that override those of the files.

.EXAMPLE
    .\deploy\Deploy-EnvProperties.ps1 -Environment DEV

.EXAMPLE
    .\deploy\Deploy-EnvProperties.ps1 -Environment DEV, INT, PRE -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $Environment,

    [string] $TemplateDir,

    [string] $TargetDir = (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Calypso'),

    [hashtable] $TokenOverride = @{}
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'lib\Tokens.psm1') -Force

if (-not $TemplateDir) { $TemplateDir = Join-Path $repoRoot 'envProperties' }
if (-not (Test-Path -LiteralPath $TemplateDir -PathType Container)) {
    throw "Template folder not found: $TemplateDir"
}

$workDir = Join-Path ([System.IO.Path]::GetTempPath()) ('calypso-envprops-{0:yyyyMMdd-HHmmss}-{1}' -f (Get-Date), $PID)
New-Item -ItemType Directory -Path $workDir -Force -WhatIf:$false | Out-Null   # internal work: also with -WhatIf

try {
    # --- 1. Render everything into a temporary folder -------------------------------------------
    $rendered = @()
    foreach ($envName in $Environment) {
        $tokens    = Get-EnvironmentTokens -Environment $envName -RepoRoot $repoRoot -Override $TokenOverride
        $templates = @(Get-ChildItem -LiteralPath $TemplateDir -File |
                       Where-Object { $_.Name.EndsWith(".$envName", [StringComparison]::OrdinalIgnoreCase) })
        if ($templates.Count -eq 0) {
            throw "No templates for environment '$envName' in $TemplateDir (expected files named *.$envName)"
        }

        foreach ($t in $templates) {
            $format = Get-TemplateFormat -Path $t.Name
            $tmp    = Join-Path $workDir $t.Name
            Expand-TokenTemplate -Template $t.FullName -Destination $tmp -Tokens $tokens -Format $format
            $rendered += [pscustomobject]@{
                Environment = $envName
                Name        = $t.Name
                Format      = $format
                Rendered    = $tmp
                Target      = Join-Path $TargetDir $t.Name
            }
        }
    }

    # --- 2. Write into the target folder ------------------------------------------------------
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        if ($PSCmdlet.ShouldProcess($TargetDir, 'Create folder')) {
            New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        }
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($r in $rendered) {
        $newHash = (Get-FileHash -LiteralPath $r.Rendered -Algorithm SHA256).Hash
        if (Test-Path -LiteralPath $r.Target -PathType Leaf) {
            $oldHash = (Get-FileHash -LiteralPath $r.Target -Algorithm SHA256).Hash
            if ($oldHash -eq $newHash) {
                Write-Host ("[{0}] {1}: unchanged" -f $r.Environment, $r.Target)
                continue
            }
            $backup = "$($r.Target).$stamp.bak"
            if ($PSCmdlet.ShouldProcess($r.Target, "Back up to $backup and replace")) {
                Copy-Item -LiteralPath $r.Target -Destination $backup -Force
                Copy-Item -LiteralPath $r.Rendered -Destination $r.Target -Force
                Write-Host ("[{0}] {1}: updated (backup: {2})" -f $r.Environment, $r.Target, $backup)
            }
        } else {
            if ($PSCmdlet.ShouldProcess($r.Target, 'Create')) {
                Copy-Item -LiteralPath $r.Rendered -Destination $r.Target -Force
                Write-Host ("[{0}] {1}: created" -f $r.Environment, $r.Target)
            }
        }
    }
}
finally {
    # The rendered files contain passwords: never leave them in the temporary folder
    Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
}
