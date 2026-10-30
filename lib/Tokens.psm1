<#
    Per-environment token system.

    Token files (load order; each one overrides the previous):
        tokens/tokens.COMMON              optional, values shared by all environments
        tokens/tokens.<ENV>               mandatory (DEV, PRE, PRO, BUILD, ...)
        secrets/tokens.<ENV>.secrets      optional, NOT versioned (passwords, etc.)
        -Override @{ KEY = 'value' }      optional, from the command line

    Token file format:
        # comment
        KEY=value
      - KEY: [A-Z0-9_]+
      - value: everything after the first '=', literal (no escaping). Surrounding spaces are trimmed.
        Windows paths are written as-is: INSTALL_DIR=D:\calypso_v19\DEV
      - A key with an empty value is considered NOT defined.

    Templates: tokens are written as @@@KEY@@@. On rendering, the value is escaped according to the
    extension of the destination file:
        .varfile .properties  -> Java/install4j .properties format  ( \ -> \\ , : -> \: , non-ASCII -> \uXXXX )
        .xml                  -> XML escaping  ( & < > " ' )
        anything else         -> literal
#>

Set-StrictMode -Version Latest

$script:TokenPattern = '@@@([A-Z0-9_]+)@@@'

function Read-TokenFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    $tokens = [ordered]@{}
    $n = 0
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $n++
        $trimmed = $line.Trim()
        if ($trimmed -eq '' -or $trimmed.StartsWith('#')) { continue }

        $eq = $trimmed.IndexOf('=')
        if ($eq -lt 1) { throw "${Path}:${n}: invalid line (expected KEY=value): $line" }

        $key   = $trimmed.Substring(0, $eq).Trim()
        $value = $trimmed.Substring($eq + 1).Trim()

        if ($key -cnotmatch '^[A-Z0-9_]+$') { throw "${Path}:${n}: invalid key '$key' (only A-Z, 0-9 and _)" }
        if ($tokens.Contains($key))         { throw "${Path}:${n}: duplicate key '$key'" }

        $tokens[$key] = $value
    }
    return $tokens
}

function Get-EnvironmentTokens {
    <#
        Returns the tokens of an environment, merging COMMON, <ENV>, secrets and overrides.
        Tokens with an empty value are removed (considered not defined).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Environment,
        [Parameter(Mandatory = $true)] [string] $RepoRoot,
        [hashtable] $Override = @{}
    )

    $envFile = Join-Path $RepoRoot "tokens\tokens.$Environment"
    if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) {
        throw "Token file for environment '$Environment' not found: $envFile"
    }

    $sources = @(
        (Join-Path $RepoRoot 'tokens\tokens.COMMON'),
        $envFile,
        (Join-Path $RepoRoot "secrets\tokens.$Environment.secrets")
    )

    $result = [ordered]@{}
    foreach ($src in $sources) {
        if (Test-Path -LiteralPath $src -PathType Leaf) {
            $t = Read-TokenFile -Path $src
            foreach ($k in $t.Keys) { $result[$k] = $t[$k] }
        }
    }
    foreach ($k in $Override.Keys) {
        if ($k -cnotmatch '^[A-Z0-9_]+$') { throw "Invalid override key '$k'" }
        $result[$k] = [string] $Override[$k]
    }

    foreach ($k in @($result.Keys)) {
        if ([string]::IsNullOrWhiteSpace($result[$k])) { $result.Remove($k) }
    }
    return $result
}

function ConvertTo-PropertiesValue([string] $Value) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Value.ToCharArray()) {
        switch ($c) {
            '\'     { [void] $sb.Append('\\') }
            ':'     { [void] $sb.Append('\:') }
            default {
                if ([int] $c -gt 126) { [void] $sb.AppendFormat('\u{0:x4}', [int] $c) }
                else                  { [void] $sb.Append($c) }
            }
        }
    }
    return $sb.ToString()
}

function ConvertTo-XmlValue([string] $Value) {
    return [System.Security.SecurityElement]::Escape($Value)
}

function Get-TemplateTokens {
    <# Returns the token names used in a template. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Path)

    $text = [System.IO.File]::ReadAllText($Path)
    return @([regex]::Matches($text, $script:TokenPattern) | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

function Expand-TokenTemplate {
    <#
        Renders a template replacing @@@KEY@@@ with its value (escaped according to the extension of
        -Destination). Fails if any token is missing or if any '@@@' remains unresolved.
        Preserves the template line endings. Writes UTF-8 without BOM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Template,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [Parameter(Mandatory = $true)] [System.Collections.IDictionary] $Tokens
    )

    if (-not (Test-Path -LiteralPath $Template -PathType Leaf)) { throw "Template not found: $Template" }

    $missing = @(Get-TemplateTokens -Path $Template | Where-Object { -not $Tokens.Contains($_) })
    if ($missing.Count -gt 0) {
        throw "Undefined tokens for '$Template': $($missing -join ', ')"
    }

    $ext = [System.IO.Path]::GetExtension($Destination).ToLowerInvariant()
    $escape = switch ($ext) {
        { $_ -in '.varfile', '.properties' } { ${function:ConvertTo-PropertiesValue}; break }
        '.xml'                                { ${function:ConvertTo-XmlValue};        break }
        default                               { { param($v) $v } }
    }

    $text = [System.IO.File]::ReadAllText($Template)
    $out  = [regex]::Replace($text, $script:TokenPattern, {
        param($m)
        & $escape ([string] $Tokens[$m.Groups[1].Value])
    })

    if ($out.Contains('@@@')) {
        throw "Unresolved '@@@' markers left in '$Template' (lowercase token name or not properly closed?)"
    }

    $dir = Split-Path -Parent $Destination
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Destination, $out, (New-Object System.Text.UTF8Encoding($false)))
}

Export-ModuleMember -Function Read-TokenFile, Get-EnvironmentTokens, Get-TemplateTokens, Expand-TokenTemplate
