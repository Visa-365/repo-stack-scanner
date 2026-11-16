#requires -Version 5.1
<#
.SYNOPSIS
    Backward-compatible shim for project-stack CLI.

.DESCRIPTION
    Forwards all bound parameters to .\project-stack.ps1.
    Prefer calling project-stack.ps1 directly.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("Path", "Repo")]
    [string]$Repository,

    [string]$TargetDirectory = "",

    [string[]]$Subdirectories = @(),

    [bool]$Recurse = $true,

    [switch]$ReuseExisting,

    [string[]]$ExtraKeywords = @(),

    [ValidateSet("medium", "high")]
    [string]$MinConfidence = "medium",

    [ValidateSet("csv", "markdown", "json", "resume", "all")]
    [Alias("Format")]
    [string]$OutputFormat = "markdown",

    [Alias("o", "Out")]
    [string]$OutputDirectory = (
        Join-Path (Get-Location) (
            "project-stack-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        )
    ),

    [string[]]$ExcludeDirectories = @(
        ".git", "node_modules", ".venv", "venv", "dist", "build",
        "__pycache__", ".tox", "vendor", "target", ".idea", ".vscode",
        ".pytest_cache", ".mypy_cache", ".next", "coverage", "htmlcov",
        ".chroma", ".agents", ".langgraph", ".cache", "Pods"
    ),

    [switch]$ShowHidden
)

$target = Join-Path $PSScriptRoot "project-stack.ps1"

if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
    throw "CLI entry not found: $target"
}

Write-Warning "Test-ProjectStack.ps1 is a compatibility shim. Use .\project-stack.ps1 instead."

& $target @PSBoundParameters
exit $LASTEXITCODE
