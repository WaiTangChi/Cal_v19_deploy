<#
    Process utilities for the install and build scripts.
    They only act on Windows; on other systems they return nothing.
#>

Set-StrictMode -Version Latest

function Get-ProcessesUsing {
    <#
        Returns the processes (Win32_Process) whose executable or command line references $Dir.
        The current process is excluded. Processes from other users or elevated processes do not
        expose their command line and are therefore not detected.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Dir)

    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return @() }
    $prefixes = @(($Dir.TrimEnd('\') + '\'), ($Dir.TrimEnd('\').Replace('\', '/') + '/'))
    return @(Get-CimInstance -ClassName Win32_Process | Where-Object {
        $proc = $_
        $proc.ProcessId -ne $PID -and @($prefixes | Where-Object {
            ($proc.ExecutablePath -and $proc.ExecutablePath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase)) -or
            ($proc.CommandLine    -and $proc.CommandLine.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        }).Count -gt 0
    })
}

function Format-ProcessInfo($Proc) {
    $cmd = if ($Proc.CommandLine) { $Proc.CommandLine.Substring(0, [Math]::Min(150, $Proc.CommandLine.Length)) } else { '' }
    return "$($Proc.ProcessId) $($Proc.Name): $cmd"
}

function Stop-ProcessesUsing {
    <# Stops the processes that reference $Dir (see Get-ProcessesUsing). Returns how many were stopped. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Dir)

    $procs = @(Get-ProcessesUsing -Dir $Dir)
    foreach ($p in $procs) {
        Write-Host "Stopping process $(Format-ProcessInfo $p)"
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if ($procs.Count -gt 0) { Start-Sleep -Seconds 2 }
    return $procs.Count
}

function Invoke-ProcessAndWait {
    <#
        Starts an executable and waits ONLY for that process, not for its children.
        (Start-Process -Wait waits for the whole process tree: if the executable leaves a child alive,
         e.g. a Gradle daemon, it never returns.)
        Returns the exit code.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]   $FilePath,
        [string[]] $ArgumentList = @()
    )

    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru
    try { $null = $proc.Handle } catch { }   # in Windows PowerShell, without this ExitCode may be empty
    $proc.WaitForExit()
    return $proc.ExitCode
}

Export-ModuleMember -Function Get-ProcessesUsing, Format-ProcessInfo, Stop-ProcessesUsing, Invoke-ProcessAndWait
