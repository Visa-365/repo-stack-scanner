#requires -Version 5.1
<#
.SYNOPSIS
    Inventory technologies used in a local or remote git project.

.DESCRIPTION
    Project Stack Scanner is a PowerShell CLI that detects runtimes, frameworks,
    databases, CI, containers and AI/RAG tooling from project markers
    (package.json, requirements.txt, Dockerfiles, etc.), extracts declared
    versions, and exports reports for resume / portfolio use.

    The tool does not build, run or test the project.

.PARAMETER Repository
    Local folder, HTTPS/SSH git URL, or GitHub shorthand owner/repo.

.PARAMETER TargetDirectory
    Clone destination for remote repositories. Default: <OutputDirectory>\source.
    Local folders are never copied.

.PARAMETER CleanupClone
    Delete the cloned source directory after the scan finishes (remote only).

.PARAMETER Subdirectories
    Limit scanning to these project-relative folders (monorepo). Empty = project root.

.PARAMETER Recurse
    Search marker files (requirements, package.json, Dockerfile, ...) recursively,
    skipping common vendor/cache directories.

.PARAMETER ReuseExisting
    Reuse an existing non-empty TargetDirectory instead of cloning again.

.PARAMETER ExtraKeywords
    Extra package/keyword markers to detect in dependency files.

.PARAMETER MinConfidence
    Filter findings: medium (default) keeps medium+high; high keeps high only.

.PARAMETER OutputFormat
    markdown | csv | json | resume | all

.PARAMETER OutputDirectory
    Directory for report files (and default remote clone under source\).
    Default: ./project-stack-YYYYMMDD-HHmmss

.PARAMETER ExcludeDirectories
    Directory names skipped when -Recurse is on.

.PARAMETER ShowHidden
    Include hidden files/directories while recursing.

.PARAMETER MarkersPath
    Path to markers.json catalog. Default: config/markers.json next to the CLI.

.PARAMETER CollapseImplied
    Hide technologies that are only implied by a more specific stack item
    from resume/stack summaries (still listed in the full inventory).

.PARAMETER MinScore
    Drop findings with score below this threshold (0-100). Default: 0.

.EXAMPLE
    .\project-stack.ps1 -Repository "C:\Projects\my-app" -OutputFormat all

.EXAMPLE
    .\project-stack.ps1 owner/repo -MinConfidence high -OutputFormat resume

.EXAMPLE
    .\project-stack.ps1 -Repository "https://github.com/owner/monorepo.git" `
        -Subdirectories "apps/web","apps/api" -OutputFormat all

.NOTES
    Requires git in PATH only when cloning remote repositories.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias("Path", "Repo")]
    [string]$Repository,

    [string]$TargetDirectory = "",

    [switch]$CleanupClone,

    [string[]]$Subdirectories = @(),

    [bool]$Recurse = $true,

    [switch]$ReuseExisting,

    [string[]]$ExtraKeywords = @(),

    [ValidateSet("low", "medium", "high")]
    [string]$MinConfidence = "medium",

    [ValidateRange(0, 100)]
    [int]$MinScore = 0,

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

    [string]$MarkersPath = "",

    [bool]$CollapseImplied = $true,

    [switch]$ShowHidden
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:CliName = "project-stack"
$script:MarkersCatalog = $null

function Resolve-RepositoryTarget {
    param([string]$Source)

    $trimmed = $Source.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Repository cannot be empty."
    }

    if (Test-Path -LiteralPath $trimmed -PathType Container) {
        $item = Get-Item -LiteralPath $trimmed
        return [pscustomobject]@{
            Kind = "local"
            Path = $item.FullName
        }
    }

    $uri = $null
    if ([Uri]::TryCreate($trimmed, [UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -in @("http", "https")) {
            return [pscustomobject]@{
                Kind = "remote"
                Path = $trimmed
            }
        }
    }

    if ($trimmed -match "^git@[^:]+:.+$") {
        return [pscustomobject]@{
            Kind = "remote"
            Path = $trimmed
        }
    }

    if ($trimmed -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
        return [pscustomobject]@{
            Kind = "remote"
            Path = ("https://github.com/" + $trimmed + ".git")
        }
    }

    if (Test-Path -LiteralPath $trimmed -PathType Leaf) {
        throw "Repository points to a file, not a folder: $trimmed"
    }

    throw ("Cannot resolve repository source: " + $trimmed)
}

function Get-RepositoryContent {
    param(
        [pscustomobject]$Target,
        [string]$TargetDirectory,
        [bool]$ReuseExisting
    )

    if ($Target.Kind -eq "local") {
        return $Target.Path
    }

    if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
        throw "TargetDirectory is required for remote repositories."
    }

    $TargetDirectory = [System.IO.Path]::GetFullPath($TargetDirectory)
    $parent = Split-Path -Parent $TargetDirectory
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [void](New-Item -ItemType Directory -Path $parent -Force)
    }

    if (Test-Path -LiteralPath $TargetDirectory) {
        $existingItems = @(
            Get-ChildItem -LiteralPath $TargetDirectory -Force -ErrorAction SilentlyContinue
        )

        if ($existingItems.Count -gt 0) {
            if ($ReuseExisting) {
                return $TargetDirectory
            }

            throw ("Target directory is not empty: " + $TargetDirectory)
        }
    }

    $gitExe = (Get-Command -Name git -ErrorAction Stop).Source
    $argumentList = @(
        "clone", "--depth", "1", "--quiet", "--",
        $Target.Path, $TargetDirectory
    )

    Write-Host ("Cloning: " + $Target.Path)
    Write-Host ("  into: " + $TargetDirectory)
    & $gitExe @argumentList

    if ($LASTEXITCODE -ne 0) {
        throw ("git clone failed with exit code " + $LASTEXITCODE + "." + `
            " For private repositories, configure GIT_TOKEN or git credentials before running this CLI.")
    }

    return $TargetDirectory
}

function Get-ProjectFile {
    param([string]$Root, [string]$RelativePath)

    $candidate = Join-Path $Root $RelativePath
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
    }

    return $null
}

function ConvertTo-ObjectArray {
    param($InputObject)

    if ($null -eq $InputObject) {
        return , @()
    }

    if ($InputObject -is [System.Array]) {
        return , $InputObject
    }

    return , @($InputObject)
}

function Flatten-StringList {
    param($InputObject)

    # Return List[string] (does not unwrap like Object[]).
    $result = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($InputObject)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()
        if ($null -eq $current) {
            continue
        }

        if ($current -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $result.Add($current)
            }
            continue
        }

        if ($current -is [System.Collections.IEnumerable] -and -not ($current -is [string])) {
            $buffer = New-Object System.Collections.Generic.List[object]
            foreach ($item in $current) {
                $buffer.Add($item)
            }
            for ($i = $buffer.Count - 1; $i -ge 0; $i--) {
                $stack.Push($buffer[$i])
            }
            continue
        }

        $text = [string]$current
        if (-not [string]::IsNullOrWhiteSpace($text) -and $text -ne "System.Object[]") {
            $result.Add($text)
        }
    }

    return $result
}

function Get-RelativePathSafe {
    param([string]$Root, [string]$FullPath)

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $pathFull = [System.IO.Path]::GetFullPath($FullPath)

    if ($pathFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        $rel = $pathFull.Substring($rootFull.Length).TrimStart('\', '/')
        return ($rel -replace '\\', '/')
    }

    return ($FullPath -replace '\\', '/')
}

function Test-ExcludedPath {
    param(
        [string]$FullPath,
        [string]$Root,
        [string[]]$ExcludeDirectories
    )

    $rel = Get-RelativePathSafe -Root $Root -FullPath $FullPath
    $parts = @($rel -split '[\\/]')

    foreach ($part in $parts) {
        foreach ($excluded in $ExcludeDirectories) {
            if ($part -eq $excluded) {
                return $true
            }
        }
    }

    return $false
}

function Get-ExcludeSet {
    param([string[]]$ExcludeDirectories)

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $ExcludeDirectories) {
        [void]$set.Add($name)
    }

    return $set
}

function Find-NamedFiles {
    param(
        [string]$Root,
        [string[]]$FileNames,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden
    )

    $results = @()
    $nameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $FileNames) {
        [void]$nameSet.Add($name)
    }

    if (-not $Recurse) {
        foreach ($name in $FileNames) {
            $candidate = Join-Path $Root $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $results += $candidate
            }
        }

        return , $results
    }

    $excludeSet = Get-ExcludeSet -ExcludeDirectories $ExcludeDirectories
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        $fileParams = @{
            LiteralPath = $current
            File        = $true
            ErrorAction = "SilentlyContinue"
        }
        if ($ShowHidden) { $fileParams["Force"] = $true }

        foreach ($item in (Get-ChildItem @fileParams)) {
            if ($nameSet.Contains($item.Name)) {
                $results += $item.FullName
            }
        }

        $dirParams = @{
            LiteralPath = $current
            Directory   = $true
            ErrorAction = "SilentlyContinue"
        }
        if ($ShowHidden) { $dirParams["Force"] = $true }

        foreach ($dir in (Get-ChildItem @dirParams)) {
            if ($excludeSet.Contains($dir.Name)) {
                continue
            }
            $stack.Push($dir.FullName)
        }
    }

    return , $results
}

function Find-FilesByFilter {
    param(
        [string]$Root,
        [string]$Filter,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden
    )

    $results = @()

    if (-not $Recurse) {
        $gciParams = @{
            LiteralPath = $Root
            File        = $true
            Filter      = $Filter
            ErrorAction = "SilentlyContinue"
        }
        if ($ShowHidden) { $gciParams["Force"] = $true }
        foreach ($item in (Get-ChildItem @gciParams)) {
            $results += $item.FullName
        }
        return , $results
    }

    $excludeSet = Get-ExcludeSet -ExcludeDirectories $ExcludeDirectories
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $current = $stack.Pop()

        $fileParams = @{
            LiteralPath = $current
            File        = $true
            Filter      = $Filter
            ErrorAction = "SilentlyContinue"
        }
        if ($ShowHidden) { $fileParams["Force"] = $true }

        foreach ($item in (Get-ChildItem @fileParams)) {
            $results += $item.FullName
        }

        $dirParams = @{
            LiteralPath = $current
            Directory   = $true
            ErrorAction = "SilentlyContinue"
        }
        if ($ShowHidden) { $dirParams["Force"] = $true }

        foreach ($dir in (Get-ChildItem @dirParams)) {
            if ($excludeSet.Contains($dir.Name)) {
                continue
            }
            $stack.Push($dir.FullName)
        }
    }

    return , $results
}

function Normalize-DeclaredVersion {
    param([string]$RawVersion)

    if ([string]::IsNullOrWhiteSpace($RawVersion)) {
        return ""
    }

    $value = $RawVersion.Trim()
    $value = $value -replace '^(===|==|~=|!=|>=|<=|=|~|\^|>|<)\s*', ''
    return $value.Trim()
}

function Find-Dockerfiles {
    param(
        [string]$Root,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden
    )

    $names = @("Dockerfile", "Dockerfile.dev", "Dockerfile.prod")
    $files = ConvertTo-ObjectArray -InputObject (
        Find-NamedFiles -Root $Root -FileNames $names -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
    )

    # Always prefer classic root Dockerfile names even when not recursing.
    if (-not $Recurse) {
        foreach ($relativePath in @("Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")) {
            $candidate = Join-Path $Root $relativePath
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $files += $candidate
            }
        }
    }
    else {
        $composeNames = @("docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
        $composeFiles = ConvertTo-ObjectArray -InputObject (
            Find-NamedFiles -Root $Root -FileNames $composeNames -Recurse:$true `
                -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
        )
        $files += $composeFiles
    }

    return , @($files | Select-Object -Unique)
}

function ConvertFrom-JsonFile {
    param([string]$FilePath)

    try {
        return (Get-Content -LiteralPath $FilePath -Raw | ConvertFrom-Json)
    }
    catch {
        return $null
    }
}

function Get-DockerfileVersions {
    param([string]$DockerfilePath)

    $versions = @()

    if (-not (Test-Path -LiteralPath $DockerfilePath)) {
        return $versions
    }

    # Skip compose YAML — FROM extraction is Dockerfile-only.
    $leaf = [System.IO.Path]::GetFileName($DockerfilePath)
    if ($leaf -match '(?i)compose') {
        return $versions
    }

    $lines = Get-Content -LiteralPath $DockerfilePath -ErrorAction SilentlyContinue

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -match "^(?i)FROM\s+(?<image>[^\s]+)") {
            $image = $Matches["image"]
            if ($image -match "^(?<base>[a-zA-Z0-9_./-]+):(?<tag>[0-9][0-9a-zA-Z_.-]*)$") {
                $versions += [pscustomobject]@{
                    Technology = $Matches["base"]
                    Version    = $Matches["tag"]
                    Source     = "Dockerfile FROM"
                }
            }
        }
    }

    return $versions
}

function Get-NpmEnginesVersion {
    param([string]$PackageJsonPath)

    $json = ConvertFrom-JsonFile -FilePath $PackageJsonPath
    if ($null -eq $json) {
        return ""
    }

    $engines = $json.PSObject.Properties["engines"]
    if ($null -eq $engines -or $null -eq $engines.Value) {
        return ""
    }

    $node = $engines.Value.PSObject.Properties["node"]
    if ($null -eq $node) {
        return ""
    }

    return ([string]$node.Value).Trim()
}

function Get-NpmPackageConstraint {
    param(
        [string]$PackageJsonPath,
        [string[]]$PackageNames
    )

    $json = ConvertFrom-JsonFile -FilePath $PackageJsonPath
    if ($null -eq $json) {
        return $null
    }

    foreach ($sectionName in @("dependencies", "devDependencies", "peerDependencies", "optionalDependencies")) {
        $sectionProp = $json.PSObject.Properties[$sectionName]
        if ($null -eq $sectionProp -or $null -eq $sectionProp.Value) {
            continue
        }

        $section = $sectionProp.Value
        foreach ($packageName in $PackageNames) {
            $pkgProp = $section.PSObject.Properties[$packageName]
            if ($null -ne $pkgProp) {
                return [pscustomobject]@{
                    Package   = $packageName
                    Version   = ([string]$pkgProp.Value).Trim()
                    Source    = ("package.json:" + $sectionName)
                    Scope     = $sectionName
                }
            }
        }
    }

    return $null
}

function Get-RequirementPackageConstraint {
    param(
        [string]$RequirementsPath,
        [string[]]$PackageNames
    )

    $lines = Get-Content -LiteralPath $RequirementsPath -ErrorAction SilentlyContinue
    if ($null -eq $lines) {
        return $null
    }

    foreach ($packageName in $PackageNames) {
        $escaped = [regex]::Escape($packageName)
        $pattern = "(?i)^\s*$escaped(?:\[[^\]]*\])?\s*(?<op>===|==|~=|!=|>=|<=|>|<|=)?\s*(?<ver>[^\s;#]+)?"

        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith("#") -or [string]::IsNullOrWhiteSpace($trimmed)) {
                continue
            }

            if ($trimmed -match $pattern) {
                $version = ""
                if ($Matches.ContainsKey("ver") -and -not [string]::IsNullOrWhiteSpace($Matches["ver"])) {
                    $version = ($Matches["op"] + $Matches["ver"]).Trim()
                    if ($version.StartsWith("=") -and -not $version.StartsWith("==") -and -not $version.StartsWith("===")) {
                        $version = $Matches["ver"]
                    }
                }

                return [pscustomobject]@{
                    Package = $packageName
                    Version = $version
                    Source  = ([System.IO.Path]::GetFileName($RequirementsPath))
                    Scope   = "requirements"
                }
            }
        }
    }

    return $null
}

function Test-RequirementPackagePresent {
    param(
        [string]$Content,
        [string]$PackageName
    )

    $escaped = [regex]::Escape($PackageName)
    return [regex]::IsMatch(
        $Content,
        "(?im)^\s*$escaped(?:\[[^\]]*\])?\s*(?:[=<>!~]=|=|~=|!=|>=|<=|>|<|\s|$|#|;)",
        "Multiline"
    )
}

function Test-PackageJsonDependency {
    param(
        [string]$Content,
        [string]$PackageName
    )

    $escaped = [regex]::Escape($PackageName)
    return [regex]::IsMatch(
        $Content,
        ('"' + $escaped + '"\s*:')
    )
}

function Test-TomlPackagePresent {
    param(
        [string]$Content,
        [string]$PackageName
    )

    $escaped = [regex]::Escape($PackageName)
    if ([regex]::IsMatch($Content, ('(?im)^\s*' + $escaped + '\s*='))) {
        return $true
    }

    if ([regex]::IsMatch($Content, ('(?i)["'']' + $escaped + '(?:\[[^\]]*\])?["'']'))) {
        return $true
    }

    return $false
}

function Get-PythonRuntimeVersion {
    param([string]$Root, [bool]$Recurse, [string[]]$ExcludeDirectories, [bool]$ShowHidden)

    $pyprojectFiles = ConvertTo-ObjectArray -InputObject (
        Find-NamedFiles -Root $Root -FileNames @("pyproject.toml") -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
    )

    foreach ($pyproject in $pyprojectFiles) {
        $content = Get-Content -LiteralPath $pyproject -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) {
            continue
        }

        $matchesList = @(
            [regex]::Matches(
                $content,
                '(?im)^(?:requires-python|python)\s*=\s*["'']([^"'']+)["'']'
            )
        )

        if ($matchesList.Count -gt 0) {
            $raw = $matchesList[0].Groups[1].Value.Trim()
            if ($raw -match '(\d+\.\d+(?:\.\d+)?)') {
                return [pscustomobject]@{
                    Version = $Matches[1]
                    Source  = (Get-RelativePathSafe -Root $Root -FullPath $pyproject)
                }
            }

            return [pscustomobject]@{
                Version = $raw
                Source  = (Get-RelativePathSafe -Root $Root -FullPath $pyproject)
            }
        }
    }

    foreach ($name in @(".python-version", "runtime.txt")) {
        $files = ConvertTo-ObjectArray -InputObject (
            Find-NamedFiles -Root $Root -FileNames @($name) -Recurse:$Recurse `
                -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
        )

        foreach ($file in $files) {
            $line = (Get-Content -LiteralPath $file -ErrorAction SilentlyContinue |
                Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                $value = $line.Trim() -replace '^python-', ''
                return [pscustomobject]@{
                    Version = $value
                    Source  = (Get-RelativePathSafe -Root $Root -FullPath $file)
                }
            }
        }
    }

    return $null
}

function Get-CargoVersion {
    param([string]$CargoTomlPath)

    $content = Get-Content -LiteralPath $CargoTomlPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return ""
    }

    $matchesList = @(
        [regex]::Matches(
            $content,
            '(?m)^\s*version\s*=\s*"(?<v>\d+(\.\d+)*(?:\.\d+)?)\s*"',
            "IgnoreCase"
        )
    )

    if ($matchesList.Count -gt 0) {
        return $matchesList[0].Groups["v"].Value
    }

    return ""
}

function Get-GoVersion {
    param([string]$GoModPath)

    $content = Get-Content -LiteralPath $GoModPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($content)) {
        return ""
    }

    $matchesList = @(
        [regex]::Matches(
            $content,
            '(?m)^go\s+(?<v>\d+(\.\d+)*(?:\.\d+)?)\s*$',
            "IgnoreCase"
        )
    )

    if ($matchesList.Count -gt 0) {
        return $matchesList[0].Groups["v"].Value
    }

    return ""
}

function Resolve-DependencyVersion {
    param(
        [string]$Root,
        [string[]]$PackageNames,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden
    )

    if ($null -eq $PackageNames -or $PackageNames.Count -eq 0) {
        return $null
    }

    $requirementNames = @(
        "requirements.txt", "requirements-dev.txt", "requirements-test.txt",
        "requirements-prod.txt", "req.txt"
    )

    $reqFiles = ConvertTo-ObjectArray -InputObject (
        Find-NamedFiles -Root $Root -FileNames $requirementNames -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
    )

    $extraReq = ConvertTo-ObjectArray -InputObject (
        Find-FilesByFilter -Root $Root -Filter "requirements*.txt" -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
    )
    foreach ($item in $extraReq) {
        if ($reqFiles -notcontains $item) {
            $reqFiles += $item
        }
    }

    foreach ($reqFile in $reqFiles) {
        $hit = Get-RequirementPackageConstraint -RequirementsPath $reqFile -PackageNames $PackageNames
        if ($null -ne $hit) {
            $hit.Source = Get-RelativePathSafe -Root $Root -FullPath $reqFile
            return $hit
        }
    }

    $packageJsonFiles = ConvertTo-ObjectArray -InputObject (
        Find-NamedFiles -Root $Root -FileNames @("package.json") -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
    )

    foreach ($packageJson in $packageJsonFiles) {
        $hit = Get-NpmPackageConstraint -PackageJsonPath $packageJson -PackageNames $PackageNames
        if ($null -ne $hit) {
            $rel = Get-RelativePathSafe -Root $Root -FullPath $packageJson
            $hit.Source = ($rel + ":" + $hit.Scope)
            return $hit
        }
    }

    $pyprojectFiles = ConvertTo-ObjectArray -InputObject (
        Find-NamedFiles -Root $Root -FileNames @("pyproject.toml") -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
    )

    foreach ($pyproject in $pyprojectFiles) {
        $content = Get-Content -LiteralPath $pyproject -Raw -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($content)) {
            continue
        }

        foreach ($packageName in $PackageNames) {
            $escaped = [regex]::Escape($packageName)
            $patterns = @(
                ('(?im)^\s*' + $escaped + '\s*=\s*["''](?<ver>[^"'']+)["'']'),
                ('(?i)["'']' + $escaped + '(?:\[[^\]]*\])?\s*(?<op>==|>=|<=|~=|!=|>|<)?\s*(?<ver>[0-9][^"'']*)["'']')
            )

            foreach ($pattern in $patterns) {
                $m = [regex]::Match($content, $pattern)
                if ($m.Success) {
                    $ver = ""
                    if ($m.Groups["ver"].Success) {
                        $ver = $m.Groups["ver"].Value.Trim()
                    }

                    return [pscustomobject]@{
                        Package = $packageName
                        Version = $ver
                        Source  = (Get-RelativePathSafe -Root $Root -FullPath $pyproject)
                        Scope   = "pyproject"
                    }
                }
            }
        }
    }

    return $null
}

function Get-JsonStringArray {
    param($Value)

    $result = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Value) {
        return $result
    }

    foreach ($item in @($Value)) {
        if ($null -eq $item) {
            continue
        }

        if ($item -is [System.Array]) {
            foreach ($inner in $item) {
                if ($null -ne $inner -and -not [string]::IsNullOrWhiteSpace([string]$inner)) {
                    $result.Add([string]$inner)
                }
            }
            continue
        }

        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $result.Add($text)
        }
    }

    return $result
}

function Import-MarkersCatalog {
    param([string]$MarkersPath)

    if ([string]::IsNullOrWhiteSpace($MarkersPath)) {
        $MarkersPath = Join-Path $PSScriptRoot "config\markers.json"
    }

    if (-not (Test-Path -LiteralPath $MarkersPath -PathType Leaf)) {
        throw ("Markers catalog not found: " + $MarkersPath)
    }

    $raw = Get-Content -LiteralPath $MarkersPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $markers = @()

    foreach ($m in (ConvertTo-ObjectArray -InputObject $raw.markers)) {
        $directories = $false
        if ($null -ne $m.PSObject.Properties["directories"] -and $m.directories) {
            $directories = [bool]$m.directories
        }

        $markers += [pscustomobject]@{
            Name         = [string]$m.name
            Category     = [string]$m.category
            Files        = (Get-JsonStringArray -Value $m.files)
            Keywords     = (Get-JsonStringArray -Value $m.keywords)
            Packages     = (Get-JsonStringArray -Value $m.packages)
            Directories  = $directories
            Confidence   = [string]$m.confidence
            Description  = [string]$m.description
            Implies      = (Get-JsonStringArray -Value $m.implies)
            Capabilities = (Get-JsonStringArray -Value $m.capabilities)
        }
    }

    $rules = @()
    if ($null -ne $raw.PSObject.Properties["capabilityRules"]) {
        foreach ($rule in (ConvertTo-ObjectArray -InputObject $raw.capabilityRules)) {
            $requireEvidence = ""
            if ($null -ne $rule.PSObject.Properties["requireEvidenceContains"]) {
                $requireEvidence = [string]$rule.requireEvidenceContains
            }

            $rules += [pscustomobject]@{
                Capability              = [string]$rule.capability
                AnyOf                   = (Get-JsonStringArray -Value $rule.anyOf)
                RequireEvidenceContains = $requireEvidence
            }
        }
    }

    Write-Verbose ("{0}: loaded {1} markers from {2}" -f $script:CliName, $markers.Count, $MarkersPath)

    return [pscustomobject]@{
        Path             = $MarkersPath
        Markers          = $markers
        CapabilityRules  = $rules
    }
}

function Find-TechnologyMarkers {
    param(
        [string]$Root,
        [string[]]$Subdirectories,
        [string[]]$ExtraKeywords,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden,
        $Catalog
    )

    $findings = @()
    $scanRoots = @($Root)

    if ($Subdirectories.Count -gt 0) {
        $scanRoots = @(
            foreach ($subdirectory in $Subdirectories) {
                Join-Path $Root $subdirectory
            }
        )
    }

    $markers = ConvertTo-ObjectArray -InputObject $Catalog.Markers
    $keyFileNames = @(
        "package.json", "requirements.txt", "requirements-dev.txt",
        "requirements-test.txt", "pyproject.toml", "Pipfile", "setup.py",
        "go.mod", "Cargo.toml", "composer.json", "Gemfile"
    )

    foreach ($root in $scanRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        $dependencyFiles = ConvertTo-ObjectArray -InputObject (
            Find-NamedFiles -Root $root -FileNames $keyFileNames -Recurse:$Recurse `
                -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
        )

        $extraReq = ConvertTo-ObjectArray -InputObject (
            Find-FilesByFilter -Root $root -Filter "requirements*.txt" -Recurse:$Recurse `
                -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
        )
        foreach ($item in $extraReq) {
            if ($dependencyFiles -notcontains $item) {
                $dependencyFiles += $item
            }
        }

        foreach ($marker in $markers) {
            $found = $false
            $evidence = @()
            $detectionKinds = @()
            $packages = ConvertTo-ObjectArray -InputObject $marker.Packages
            $files = ConvertTo-ObjectArray -InputObject $marker.Files
            $keywords = ConvertTo-ObjectArray -InputObject $marker.Keywords

            if ($marker.Directories) {
                foreach ($directoryName in $files) {
                    $candidate = Join-Path $root $directoryName
                    if (Test-Path -LiteralPath $candidate -PathType Container) {
                        $found = $true
                        $detectionKinds += "directory"
                        $evidence += (Get-RelativePathSafe -Root $Root -FullPath $candidate) + "/"
                    }
                }
            }
            elseif ($files.Count -gt 0) {
                $literalNames = @()
                $globs = @()
                foreach ($relativePath in $files) {
                    if ($relativePath -like "*.*" -and $relativePath.Contains("*")) {
                        $globs += $relativePath
                    }
                    elseif ($relativePath.StartsWith("*")) {
                        $globs += $relativePath
                    }
                    else {
                        $literalNames += $relativePath
                    }
                }

                foreach ($glob in $globs) {
                    $globFiles = ConvertTo-ObjectArray -InputObject (
                        Find-FilesByFilter -Root $root -Filter $glob -Recurse:$Recurse `
                            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
                    )
                    if ($globFiles.Count -gt 0) {
                        $found = $true
                        $detectionKinds += "file"
                        $evidence += Get-RelativePathSafe -Root $Root -FullPath $globFiles[0]
                    }
                }

                if ($literalNames.Count -gt 0) {
                    $matchedFiles = ConvertTo-ObjectArray -InputObject (
                        Find-NamedFiles -Root $root -FileNames $literalNames -Recurse:$Recurse `
                            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
                    )

                    foreach ($matched in $matchedFiles) {
                        $found = $true
                        $detectionKinds += "file"
                        $evidence += Get-RelativePathSafe -Root $Root -FullPath $matched
                    }
                }
            }

            if (-not $found -and ($keywords.Count -gt 0 -or $ExtraKeywords.Count -gt 0 -or $packages.Count -gt 0)) {
                $searchTerms = @()
                $searchTerms += $packages
                $searchTerms += $keywords
                $searchTerms += $ExtraKeywords
                $searchTerms = @($searchTerms | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)

                foreach ($depFile in $dependencyFiles) {
                    $content = Get-Content -LiteralPath $depFile -Raw -ErrorAction SilentlyContinue
                    if ([string]::IsNullOrWhiteSpace($content)) {
                        continue
                    }

                    $leaf = [System.IO.Path]::GetFileName($depFile)
                    foreach ($term in $searchTerms) {
                        $matched = $false

                        if ($leaf -like "requirements*.txt" -or $leaf -eq "req.txt") {
                            $matched = Test-RequirementPackagePresent -Content $content -PackageName $term
                        }
                        elseif ($leaf -eq "package.json") {
                            $matched = Test-PackageJsonDependency -Content $content -PackageName $term
                        }
                        elseif ($leaf -eq "pyproject.toml" -or $leaf -eq "Pipfile" -or $leaf -eq "setup.py" -or $leaf -eq "go.mod" -or $leaf -eq "Cargo.toml" -or $leaf -eq "composer.json" -or $leaf -eq "Gemfile") {
                            $matched = Test-TomlPackagePresent -Content $content -PackageName $term
                        }
                        else {
                            $matched = $content -match [regex]::Escape($term)
                        }

                        if ($matched) {
                            $found = $true
                            $detectionKinds += "package"
                            $evidence += ("Package: " + $term + " in " + (Get-RelativePathSafe -Root $Root -FullPath $depFile))
                            break
                        }
                    }

                    if ($found) {
                        break
                    }
                }
            }

            if ($found) {
                $findings += [pscustomobject]@{
                    Name           = $marker.Name
                    Category       = $marker.Category
                    Confidence     = $marker.Confidence
                    Description    = $marker.Description
                    Packages       = @(Flatten-StringList -InputObject $packages)
                    Implies        = @(Flatten-StringList -InputObject $marker.Implies)
                    Capabilities   = @(Flatten-StringList -InputObject $marker.Capabilities)
                    DetectionKinds = @($detectionKinds | Select-Object -Unique)
                    Evidence       = (($evidence | Select-Object -Unique) -join "; ")
                }
            }
        }
    }

    return $findings
}

function Get-VersionedFindings {
    param(
        [string]$Root,
        [string[]]$Subdirectories,
        [string[]]$ExtraKeywords,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden,
        $Catalog
    )

    $findings = ConvertTo-ObjectArray -InputObject (
        Find-TechnologyMarkers `
            -Root $Root `
            -Subdirectories $Subdirectories `
            -ExtraKeywords $ExtraKeywords `
            -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories `
            -ShowHidden:$ShowHidden `
            -Catalog $Catalog
    )

    $versionedFindings = @()

    foreach ($finding in $findings) {
        $version = ""
        $versionSource = ""
        $packages = ConvertTo-ObjectArray -InputObject $finding.Packages

        if ($finding.Name -eq "Node.js") {
            $packageJsonFiles = ConvertTo-ObjectArray -InputObject (
                Find-NamedFiles -Root $Root -FileNames @("package.json") -Recurse:$Recurse `
                    -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
            )

            foreach ($packageJson in $packageJsonFiles) {
                $engines = Get-NpmEnginesVersion -PackageJsonPath $packageJson
                if (-not [string]::IsNullOrWhiteSpace($engines)) {
                    $version = $engines
                    $versionSource = ((Get-RelativePathSafe -Root $Root -FullPath $packageJson) + ":engines.node")
                    break
                }
            }
        }
        elseif ($finding.Name -eq "Python") {
            $py = Get-PythonRuntimeVersion -Root $Root -Recurse:$Recurse `
                -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
            if ($null -ne $py) {
                $version = $py.Version
                $versionSource = $py.Source
            }
        }
        elseif ($finding.Name -eq "Go") {
            $goMod = Get-ProjectFile -Root $Root -RelativePath "go.mod"
            if ($null -eq $goMod -and $Recurse) {
                $goFiles = ConvertTo-ObjectArray -InputObject (
                    Find-NamedFiles -Root $Root -FileNames @("go.mod") -Recurse:$true `
                        -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
                )
                if ($goFiles.Count -gt 0) { $goMod = $goFiles[0] }
            }

            if ($null -ne $goMod) {
                $version = Get-GoVersion -GoModPath $goMod
                $versionSource = Get-RelativePathSafe -Root $Root -FullPath $goMod
            }
        }
        elseif ($finding.Name -eq "Rust") {
            $cargoToml = Get-ProjectFile -Root $Root -RelativePath "Cargo.toml"
            if ($null -eq $cargoToml -and $Recurse) {
                $cargoFiles = ConvertTo-ObjectArray -InputObject (
                    Find-NamedFiles -Root $Root -FileNames @("Cargo.toml") -Recurse:$true `
                        -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
                )
                if ($cargoFiles.Count -gt 0) { $cargoToml = $cargoFiles[0] }
            }

            if ($null -ne $cargoToml) {
                $version = Get-CargoVersion -CargoTomlPath $cargoToml
                $versionSource = Get-RelativePathSafe -Root $Root -FullPath $cargoToml
            }
        }
        elseif ($finding.Name -eq "Docker") {
            $dockerFiles = ConvertTo-ObjectArray -InputObject (
                Find-Dockerfiles -Root $Root -Recurse:$Recurse `
                    -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
            )

            $allDockerVersions = @()
            foreach ($dockerFile in $dockerFiles) {
                $dockerVersions = ConvertTo-ObjectArray -InputObject (
                    Get-DockerfileVersions -DockerfilePath $dockerFile
                )
                foreach ($dv in $dockerVersions) {
                    $allDockerVersions += [pscustomobject]@{
                        Technology = $dv.Technology
                        Version    = $dv.Version
                        Source     = ((Get-RelativePathSafe -Root $Root -FullPath $dockerFile) + " FROM")
                    }
                }
            }

            if ($allDockerVersions.Count -gt 0) {
                $first = $allDockerVersions[0]
                $version = $first.Version
                $versionSource = ($first.Source + " (" + $first.Technology + ")")
            }
        }

        if ([string]::IsNullOrWhiteSpace($version) -and $packages.Count -gt 0) {
            $dep = Resolve-DependencyVersion -Root $Root -PackageNames $packages `
                -Recurse:$Recurse -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden

            if ($null -ne $dep -and -not [string]::IsNullOrWhiteSpace($dep.Version)) {
                $version = Normalize-DeclaredVersion -RawVersion $dep.Version
                $versionSource = ($dep.Source + " (" + $dep.Package + ")")
            }
            elseif ($null -ne $dep) {
                $versionSource = ($dep.Source + " (" + $dep.Package + "; version not pinned)")
            }
        }

        if ($finding.Name -eq "Python" -and [string]::IsNullOrWhiteSpace($version)) {
            $dockerFiles = ConvertTo-ObjectArray -InputObject (
                Find-Dockerfiles -Root $Root -Recurse:$Recurse `
                    -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
            )
            foreach ($dockerFile in $dockerFiles) {
                $dockerVersions = ConvertTo-ObjectArray -InputObject (
                    Get-DockerfileVersions -DockerfilePath $dockerFile
                )
                foreach ($dv in $dockerVersions) {
                    if ($dv.Technology -match '(?i)(^|/)python$') {
                        $version = Normalize-DeclaredVersion -RawVersion $dv.Version
                        $versionSource = ((Get-RelativePathSafe -Root $Root -FullPath $dockerFile) + " FROM python")
                        break
                    }
                }
                if (-not [string]::IsNullOrWhiteSpace($version)) { break }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($version)) {
            $version = Normalize-DeclaredVersion -RawVersion $version
        }

        $versionedFindings += [pscustomobject]@{
            Technology     = $finding.Name
            Category       = $finding.Category
            Version        = $version
            VersionSource  = $versionSource
            Confidence     = $finding.Confidence
            Description    = $finding.Description
            Evidence       = $finding.Evidence
            Packages       = $finding.Packages
            Implies        = $finding.Implies
            Capabilities   = $finding.Capabilities
            DetectionKinds = $finding.DetectionKinds
            Score          = 0
            Relation       = ""
            Uses           = ""
            IsPrimary      = $true
            ResumeLine     = ""
        }
    }

    foreach ($item in $versionedFindings) {
        $label = $item.Technology
        if (-not [string]::IsNullOrWhiteSpace($item.Version)) {
            $label = $label + " " + $item.Version
        }
        $item.ResumeLine = $label
    }

    return $versionedFindings
}

function Get-ConfidenceRank {
    param([string]$Confidence)

    switch ($Confidence) {
        "high" { return 3 }
        "medium" { return 2 }
        "low" { return 1 }
        default { return 0 }
    }
}

function ConvertFrom-ScoreToConfidence {
    param([int]$Score)

    if ($Score -ge 75) { return "high" }
    if ($Score -ge 45) { return "medium" }
    return "low"
}

function Get-FindingScore {
    param($Finding)

    $score = 0
    $kinds = ConvertTo-ObjectArray -InputObject $Finding.DetectionKinds
    $evidenceParts = @()
    if (-not [string]::IsNullOrWhiteSpace($Finding.Evidence)) {
        $evidenceParts = @($Finding.Evidence -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }

    if ($kinds -contains "file" -or $kinds -contains "directory") {
        $score += 50
    }
    if ($kinds -contains "package") {
        $score += 35
    }
    if (-not [string]::IsNullOrWhiteSpace($Finding.Version)) {
        $score += 15
    }
    if ($evidenceParts.Count -ge 2) {
        $score += 10
    }

    # Keep a floor from catalog confidence for sparse-but-explicit markers.
    $floor = switch ($Finding.Confidence) {
        "high" { 75 }
        "medium" { 50 }
        default { 25 }
    }

    if ($score -lt $floor -and ($kinds -contains "file" -or $kinds -contains "directory" -or $kinds -contains "package")) {
        $score = $floor
    }

    if ($score -gt 100) { $score = 100 }
    return $score
}

function Enrich-Findings {
    param(
        [array]$Findings,
        $Catalog
    )

    $items = ConvertTo-ObjectArray -InputObject $Findings
    $byName = @{}
    foreach ($item in $items) {
        $byName[$item.Technology] = $item
    }

    foreach ($item in $items) {
        $item.Score = Get-FindingScore -Finding $item
        $item.Confidence = ConvertFrom-ScoreToConfidence -Score $item.Score
    }

    # Hierarchy: mark implied technologies and parent "Uses" chains.
    foreach ($item in $items) {
        $implies = @(Flatten-StringList -InputObject $item.Implies)
        $item.Implies = $implies
        $used = @()
        foreach ($parentName in $implies) {
            if ($byName.ContainsKey($parentName)) {
                $used += $parentName
                $child = $byName[$parentName]
                $relation = ("implied by " + $item.Technology)
                if ([string]::IsNullOrWhiteSpace($child.Relation)) {
                    $child.Relation = $relation
                }
                else {
                    $child.Relation = ($child.Relation + "; " + $relation)
                }
                $child.IsPrimary = $false
            }
        }
        if ($used.Count -gt 0) {
            $item.Uses = ($used -join ", ")
            $suffix = (" (uses " + $item.Uses + ")")
            if (-not $item.ResumeLine.EndsWith($suffix)) {
                $item.ResumeLine = $item.ResumeLine + $suffix
            }
        }
    }

    # Project-level capabilities from marker tags + rules.
    $capabilitySet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $items) {
        $item.Capabilities = @(Flatten-StringList -InputObject $item.Capabilities)
        $item.Implies = @(Flatten-StringList -InputObject $item.Implies)
        foreach ($cap in $item.Capabilities) {
            [void]$capabilitySet.Add($cap)
        }
    }

    foreach ($rule in (ConvertTo-ObjectArray -InputObject $Catalog.CapabilityRules)) {
        $matched = $false
        foreach ($name in @(Flatten-StringList -InputObject $rule.AnyOf)) {
            if (-not $byName.ContainsKey($name)) {
                continue
            }

            if (-not [string]::IsNullOrWhiteSpace($rule.RequireEvidenceContains)) {
                $needle = [string]$rule.RequireEvidenceContains
                if ($byName[$name].Evidence -notmatch [regex]::Escape($needle)) {
                    continue
                }
            }

            $matched = $true
            break
        }

        if ($matched) {
            [void]$capabilitySet.Add([string]$rule.Capability)
        }
    }

    $projectCapabilities = @($capabilitySet | Sort-Object)

    return [pscustomobject]@{
        Findings     = $items
        Capabilities = $projectCapabilities
    }
}

function Select-FindingsByConfidence {
    param(
        [array]$Findings,
        [string]$MinConfidence,
        [int]$MinScore = 0
    )

    $minRank = Get-ConfidenceRank -Confidence $MinConfidence
    $filtered = @(
        $Findings | Where-Object {
            (Get-ConfidenceRank -Confidence $_.Confidence) -ge $minRank -and $_.Score -ge $MinScore
        }
    )

    return , $filtered
}

function Get-ResumeSummary {
    param(
        [array]$Findings,
        [string[]]$Capabilities = @(),
        [bool]$CollapseImplied = $true
    )

    if ($Findings.Count -eq 0) {
        return [ordered]@{
            StackLine    = ""
            Bullets      = @()
            ByCategory   = @()
            Capabilities = @()
        }
    }

    $primary = @($Findings)
    if ($CollapseImplied) {
        $primary = @($Findings | Where-Object { $_.IsPrimary })
        if ($primary.Count -eq 0) {
            $primary = @($Findings)
        }
    }

    $ordered = @($primary | Sort-Object @{Expression = "Score"; Descending = $true}, Category, Technology)
    $stackParts = @(
        foreach ($f in $ordered) {
            if ([string]::IsNullOrWhiteSpace($f.Version)) {
                if ([string]::IsNullOrWhiteSpace($f.Uses)) { $f.Technology }
                else { ($f.Technology + " (uses " + $f.Uses + ")") }
            }
            else {
                if ([string]::IsNullOrWhiteSpace($f.Uses)) { ($f.Technology + " " + $f.Version) }
                else { ($f.Technology + " " + $f.Version + " (uses " + $f.Uses + ")") }
            }
        }
    )

    $byCategory = @(
        $ordered | Group-Object Category | ForEach-Object {
            $names = @(
                $_.Group | ForEach-Object {
                    if ([string]::IsNullOrWhiteSpace($_.Version)) { $_.Technology }
                    else { ($_.Technology + " " + $_.Version) }
                }
            )
            [ordered]@{
                Category = $_.Name
                Items    = ($names -join ", ")
            }
        }
    )

    $bullets = @()
    $ai = @($ordered | Where-Object { $_.Category -like "AI*" -or ($_.Capabilities -contains "RAG") -or ($_.Capabilities -contains "AI") })
    $web = @($ordered | Where-Object { $_.Category -in @("Web framework", "Frontend framework") })
    $runtime = @($ordered | Where-Object { $_.Category -eq "Runtime" })
    $containers = @($ordered | Where-Object { $_.Category -eq "Containerization" })

    if ($web.Count -gt 0 -or $runtime.Count -gt 0) {
        $parts = @($runtime + $web | ForEach-Object { $_.Technology + $(if ($_.Version) { " $($_.Version)" } else { "" }) })
        $bullets += ("Developed application stack with " + ($parts -join ", ") + ".")
    }

    if ($Capabilities -contains "RAG" -or $ai.Count -gt 0) {
        $parts = @($ai | ForEach-Object { $_.Technology + $(if ($_.Version) { " $($_.Version)" } else { "" }) })
        if ($parts.Count -eq 0) {
            $parts = @($Capabilities | Where-Object { $_ -in @("RAG", "Agents", "AI") })
        }
        $bullets += ("Implemented AI/RAG capabilities using " + ($parts -join ", ") + ".")
    }

    if ($containers.Count -gt 0) {
        $parts = @($containers | ForEach-Object { $_.Technology + $(if ($_.Version) { " $($_.Version)" } else { "" }) })
        $suffix = ""
        if ($Capabilities -contains "Multi-service") {
            $suffix = " in a multi-service setup"
        }
        $bullets += ("Packaged and ran services with " + ($parts -join ", ") + $suffix + ".")
    }

    if ($bullets.Count -eq 0) {
        $bullets += ("Worked with " + ($stackParts -join ", ") + ".")
    }

    return [ordered]@{
        StackLine    = ($stackParts -join " · ")
        Bullets      = $bullets
        ByCategory   = $byCategory
        Capabilities = @($Capabilities)
    }
}

function ConvertTo-MarkdownReport {
    param(
        [array]$Findings,
        [string[]]$Capabilities = @(),
        [bool]$CollapseImplied = $true
    )

    $lines = @()
    $lines += "# Project Technology Inventory"
    $lines += ""
    $lines += ("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $lines += ("Tool: " + $script:CliName)
    $lines += ""

    $summary = Get-ResumeSummary -Findings $Findings -Capabilities $Capabilities -CollapseImplied:$CollapseImplied
    $lines += "## Resume Summary"
    $lines += ""
    if ([string]::IsNullOrWhiteSpace($summary.StackLine)) {
        $lines += "_No technologies detected._"
    }
    else {
        $lines += ("**Stack:** " + $summary.StackLine)
        $lines += ""
        if ($Capabilities.Count -gt 0) {
            $lines += ("**Capabilities:** " + ($Capabilities -join " · "))
            $lines += ""
        }
        $lines += "### Suggested bullets"
        $lines += ""
        foreach ($bullet in $summary.Bullets) {
            $lines += ("- " + $bullet)
        }
        $lines += ""
        $lines += "### By category"
        $lines += ""
        foreach ($group in $summary.ByCategory) {
            $lines += ("- **" + $group.Category + ":** " + $group.Items)
        }
    }
    $lines += ""

    $lines += "## Technologies Detected"
    $lines += ""

    if ($Findings.Count -eq 0) {
        $lines += "_No technologies detected._"
        $lines += ""
    }
    else {
        $lines += "| Technology | Category | Version | Score | Confidence | Relation | Capabilities | Evidence |"
        $lines += "|---|---|---|---|---|---|---|---|"

        foreach ($finding in ($Findings | Sort-Object @{Expression = "Score"; Descending = $true}, Category, Technology)) {
            $version = if ([string]::IsNullOrWhiteSpace($finding.Version)) { "-" } else { $finding.Version }
            $relation = if ([string]::IsNullOrWhiteSpace($finding.Relation)) { "-" } else { $finding.Relation }
            $caps = (@(Flatten-StringList -InputObject $finding.Capabilities) -join ", ")
            if ([string]::IsNullOrWhiteSpace($caps)) { $caps = "-" }

            $lines += (
                "| " + $finding.Technology + " | " +
                $finding.Category + " | " +
                $version + " | " +
                $finding.Score + " | " +
                $finding.Confidence + " | " +
                $relation + " | " +
                $caps + " | " +
                $finding.Evidence + " |"
            )
        }

        $lines += ""
    }

    return ($lines -join "`n")
}

function ConvertTo-ResumeMarkdown {
    param(
        [array]$Findings,
        [string[]]$Capabilities = @(),
        [bool]$CollapseImplied = $true
    )

    $summary = Get-ResumeSummary -Findings $Findings -Capabilities $Capabilities -CollapseImplied:$CollapseImplied
    $lines = @()
    $lines += "# Resume Technology Snapshot"
    $lines += ""
    $lines += ("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $lines += ""
    $lines += "## Stack"
    $lines += ""
    $lines += $summary.StackLine
    $lines += ""
    if ($Capabilities.Count -gt 0) {
        $lines += "## Capabilities"
        $lines += ""
        $lines += ($Capabilities -join " · ")
        $lines += ""
    }
    $lines += "## Bullets"
    $lines += ""
    foreach ($bullet in $summary.Bullets) {
        $lines += ("- " + $bullet)
    }
    $lines += ""
    $lines += "## Skills list"
    $lines += ""
    $skillFindings = @($Findings)
    if ($CollapseImplied) {
        $skillFindings = @($Findings | Where-Object { $_.IsPrimary })
        if ($skillFindings.Count -eq 0) { $skillFindings = @($Findings) }
    }
    foreach ($finding in ($skillFindings | Sort-Object @{Expression = "Score"; Descending = $true}, Category, Technology)) {
        $version = if ([string]::IsNullOrWhiteSpace($finding.Version)) { "" } else { (" (" + $finding.Version + ")") }
        $uses = if ([string]::IsNullOrWhiteSpace($finding.Uses)) { "" } else { (" — uses " + $finding.Uses) }
        $lines += ("- " + $finding.Technology + $version + " — " + $finding.Category + " [score " + $finding.Score + "]" + $uses)
    }
    $lines += ""

    return ($lines -join "`n")
}

function ConvertTo-ResumeJson {
    param(
        [array]$Findings,
        [string[]]$Capabilities = @(),
        [bool]$CollapseImplied = $true
    )

    $summary = Get-ResumeSummary -Findings $Findings -Capabilities $Capabilities -CollapseImplied:$CollapseImplied

    [ordered]@{
        Technologies = @(
            foreach ($finding in $Findings) {
                [ordered]@{
                    Name          = $finding.Technology
                    Category      = $finding.Category
                    Version       = $finding.Version
                    VersionSource = $finding.VersionSource
                    Confidence    = $finding.Confidence
                    Score         = $finding.Score
                    Relation      = $finding.Relation
                    Uses          = $finding.Uses
                    IsPrimary     = $finding.IsPrimary
                    Capabilities  = @($finding.Capabilities)
                    Evidence      = $finding.Evidence
                    ResumeLine    = $finding.ResumeLine
                }
            }
        )
        Capabilities = @($Capabilities)
        Summary      = $summary
        GeneratedAt  = (Get-Date).ToString("o")
        Total        = $Findings.Count
        Categories   = @(
            $Findings | Group-Object -Property Category |
                Select-Object Name, Count
        )
        Tool         = $script:CliName
    }
}

# --- Main ---

$clonedSourcePath = $null
$exitCode = 0

try {
    Write-Host ("{0}: resolving repository..." -f $script:CliName)

    $script:MarkersCatalog = Import-MarkersCatalog -MarkersPath $MarkersPath

    $target = Resolve-RepositoryTarget -Source $Repository

    [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)

    $cloneDirectory = $TargetDirectory
    if ($target.Kind -eq "remote" -and [string]::IsNullOrWhiteSpace($cloneDirectory)) {
        $cloneDirectory = Join-Path $OutputDirectory "source"
    }

    $projectRoot = Get-RepositoryContent `
        -Target $target `
        -TargetDirectory $cloneDirectory `
        -ReuseExisting:$ReuseExisting.IsPresent

    if ($target.Kind -eq "remote") {
        $clonedSourcePath = $projectRoot
    }

    Write-Host ("{0}: analyzing {1}" -f $script:CliName, $projectRoot)
    Write-Host ("{0}: markers catalog {1}" -f $script:CliName, $script:MarkersCatalog.Path)
    if ($Recurse) {
        Write-Host ("{0}: recursive scan enabled" -f $script:CliName)
    }

    $findings = ConvertTo-ObjectArray -InputObject (
        Get-VersionedFindings `
            -Root $projectRoot `
            -Subdirectories $Subdirectories `
            -ExtraKeywords $ExtraKeywords `
            -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories `
            -ShowHidden:$ShowHidden.IsPresent `
            -Catalog $script:MarkersCatalog
    )

    $enriched = Enrich-Findings -Findings $findings -Catalog $script:MarkersCatalog
    $findings = ConvertTo-ObjectArray -InputObject $enriched.Findings
    $capabilities = @(Flatten-StringList -InputObject $enriched.Capabilities)

    $findings = ConvertTo-ObjectArray -InputObject (
        Select-FindingsByConfidence -Findings $findings -MinConfidence $MinConfidence -MinScore $MinScore
    )

    $findings |
        Select-Object Technology, Category, Version, VersionSource, Confidence, Score, Relation, Uses, IsPrimary, Description, Evidence, ResumeLine, @{
            Name = "Capabilities"; Expression = { (@($_.Capabilities) -join "; ") }
        } |
        Export-Csv -LiteralPath (Join-Path $OutputDirectory "technologies.csv") `
            -NoTypeInformation -Encoding UTF8

    $writeMarkdown = $OutputFormat -in @("markdown", "all")
    $writeJson = $OutputFormat -in @("json", "resume", "all")
    $writeResume = $OutputFormat -in @("resume", "all")

    if ($writeMarkdown) {
        ConvertTo-MarkdownReport -Findings $findings -Capabilities $capabilities -CollapseImplied:$CollapseImplied |
            Set-Content -LiteralPath (Join-Path $OutputDirectory "README.md") `
                -Encoding UTF8
    }

    if ($writeResume) {
        ConvertTo-ResumeMarkdown -Findings $findings -Capabilities $capabilities -CollapseImplied:$CollapseImplied |
            Set-Content -LiteralPath (Join-Path $OutputDirectory "resume.md") `
                -Encoding UTF8
    }

    if ($writeJson) {
        ConvertTo-ResumeJson -Findings $findings -Capabilities $capabilities -CollapseImplied:$CollapseImplied |
            ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath (Join-Path $OutputDirectory "technologies.json") `
                -Encoding UTF8
    }

    if ($OutputFormat -in @("csv", "all")) {
        Write-Host ("CSV: " + (Join-Path $OutputDirectory "technologies.csv"))
    }
    if ($writeMarkdown) {
        Write-Host ("Markdown: " + (Join-Path $OutputDirectory "README.md"))
    }
    if ($writeResume) {
        Write-Host ("Resume: " + (Join-Path $OutputDirectory "resume.md"))
    }
    if ($writeJson) {
        Write-Host ("JSON: " + (Join-Path $OutputDirectory "technologies.json"))
    }

    if ($findings.Count -eq 0) {
        Write-Warning "No technologies detected for the current filters."
        $exitCode = 2
    }
    else {
        Write-Host ""
        Write-Host ("Detected {0} technologies:" -f $findings.Count)
        Write-Host ""

        $findings |
            Sort-Object @{Expression = "Score"; Descending = $true}, Category, Technology |
            Format-Table Technology, Category, Version, Score, Confidence, Relation -AutoSize -Wrap

        $summary = Get-ResumeSummary -Findings $findings -Capabilities $capabilities -CollapseImplied:$CollapseImplied
        Write-Host "Capabilities:"
        if ($capabilities.Count -gt 0) {
            Write-Host ("  " + ($capabilities -join " · "))
        }
        else {
            Write-Host "  (none)"
        }
        Write-Host "Resume stack:"
        Write-Host ("  " + $summary.StackLine)
        Write-Host ""
        Write-Host ("Reports: " + (Get-Item -LiteralPath $OutputDirectory).FullName)
        $exitCode = 0
    }
}
catch {
    Write-Error ("{0}: {1}" -f $script:CliName, $_.Exception.Message)
    $exitCode = 1
}
finally {
    if ($CleanupClone.IsPresent -and -not [string]::IsNullOrWhiteSpace($clonedSourcePath)) {
        if (Test-Path -LiteralPath $clonedSourcePath) {
            Write-Host ("{0}: cleaning up clone {1}" -f $script:CliName, $clonedSourcePath)
            Remove-Item -LiteralPath $clonedSourcePath -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $exitCode


