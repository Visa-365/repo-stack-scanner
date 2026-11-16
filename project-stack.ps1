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
    Clone destination for remote repositories. Local folders are never copied.

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
    Directory for report files. Default: ./project-stack-YYYYMMDD-HHmmss

.PARAMETER ExcludeDirectories
    Directory names skipped when -Recurse is on.

.PARAMETER ShowHidden
    Include hidden files/directories while recursing.

.EXAMPLE
    .\project-stack.ps1 -Repository "C:\Projects\my-app" -Recurse -OutputFormat all

.EXAMPLE
    .\project-stack.ps1 owner/repo -Recurse -MinConfidence high -OutputFormat resume

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

    [string[]]$Subdirectories = @(),

    [switch]$Recurse = $true,

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

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$script:CliName = "project-stack"

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
        $safeName = $Target.Path -replace "[^A-Za-z0-9_.-]", "_"
        $TargetDirectory = Join-Path $env:TEMP ("repo-" + $safeName)
    }

    $existing = @(Get-ChildItem -LiteralPath $TargetDirectory `
        -Directory -ErrorAction SilentlyContinue)

    if ($existing.Count -gt 0) {
        if ($ReuseExisting) {
            return $existing[0].FullName
        }

        throw ("Target directory is not empty: " + $TargetDirectory)
    }

    $gitExe = (Get-Command -Name git -ErrorAction Stop).Source
    $argumentList = @(
        "clone", "--depth", "1", "--quiet", "--",
        $Target.Path, $TargetDirectory
    )

    Write-Host ("Cloning: " + $Target.Path)
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

function Get-TechnologyMarkersCatalog {
    @(
        [pscustomobject]@{ Name = "Docker"; Category = "Containerization"; Files = @("Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Docker containerization"; Directories = $false },
        [pscustomobject]@{ Name = "Kubernetes"; Category = "Containerization"; Files = @("k8s", "kubernetes", "charts", "manifests"); Keywords = @(); Packages = @(); Confidence = "medium"; Description = "Kubernetes orchestration"; Directories = $true },
        [pscustomobject]@{ Name = "Node.js"; Category = "Runtime"; Files = @("package.json"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Node.js runtime"; Directories = $false },
        [pscustomobject]@{ Name = "Python"; Category = "Runtime"; Files = @("requirements.txt", "pyproject.toml", "setup.py", "Pipfile", "poetry.lock", ".python-version", "runtime.txt"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Python runtime"; Directories = $false },
        [pscustomobject]@{ Name = "Go"; Category = "Runtime"; Files = @("go.mod", "go.sum"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Go runtime"; Directories = $false },
        [pscustomobject]@{ Name = "Rust"; Category = "Runtime"; Files = @("Cargo.toml", "Cargo.lock"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Rust runtime"; Directories = $false },
        [pscustomobject]@{ Name = "React"; Category = "Frontend framework"; Files = @(); Keywords = @("react"); Packages = @("react"); Confidence = "high"; Description = "React frontend framework"; Directories = $false },
        [pscustomobject]@{ Name = "Vue"; Category = "Frontend framework"; Files = @(); Keywords = @("vue"); Packages = @("vue"); Confidence = "high"; Description = "Vue frontend framework"; Directories = $false },
        [pscustomobject]@{ Name = "Angular"; Category = "Frontend framework"; Files = @(); Keywords = @("@angular/core"); Packages = @("@angular/core"); Confidence = "high"; Description = "Angular frontend framework"; Directories = $false },
        [pscustomobject]@{ Name = "Svelte"; Category = "Frontend framework"; Files = @(); Keywords = @("svelte"); Packages = @("svelte"); Confidence = "medium"; Description = "Svelte frontend framework"; Directories = $false },
        [pscustomobject]@{ Name = "Next.js"; Category = "Frontend framework"; Files = @(); Keywords = @("next"); Packages = @("next"); Confidence = "high"; Description = "Next.js full-stack framework"; Directories = $false },
        [pscustomobject]@{ Name = "TypeScript"; Category = "Language"; Files = @("tsconfig.json"); Keywords = @("typescript"); Packages = @("typescript"); Confidence = "high"; Description = "TypeScript language"; Directories = $false },
        [pscustomobject]@{ Name = "Tailwind CSS"; Category = "Styling"; Files = @("tailwind.config.js", "tailwind.config.ts", "tailwind.config.cjs", "tailwind.config.mjs"); Keywords = @("tailwindcss"); Packages = @("tailwindcss"); Confidence = "high"; Description = "Tailwind CSS utility framework"; Directories = $false },
        [pscustomobject]@{ Name = "PostgreSQL"; Category = "Database"; Files = @(); Keywords = @("postgres", "postgresql", "psycopg2", "psycopg"); Packages = @("psycopg2", "psycopg2-binary", "psycopg", "pg", "postgres"); Confidence = "medium"; Description = "PostgreSQL relational database"; Directories = $false },
        [pscustomobject]@{ Name = "MySQL"; Category = "Database"; Files = @(); Keywords = @("mysql"); Packages = @("mysql", "mysql2", "mysqlclient", "pymysql"); Confidence = "medium"; Description = "MySQL relational database"; Directories = $false },
        [pscustomobject]@{ Name = "MongoDB"; Category = "Database"; Files = @(); Keywords = @("mongodb", "mongoose"); Packages = @("mongodb", "mongoose", "pymongo"); Confidence = "medium"; Description = "MongoDB document database"; Directories = $false },
        [pscustomobject]@{ Name = "Redis"; Category = "Database"; Files = @(); Keywords = @("redis", "ioredis"); Packages = @("redis", "ioredis"); Confidence = "medium"; Description = "Redis in-memory database"; Directories = $false },
        [pscustomobject]@{ Name = "GraphQL"; Category = "API"; Files = @("schema.graphql"); Keywords = @("graphql", "apollo", "urql"); Packages = @("graphql", "@apollo/client", "apollo-server", "urql"); Confidence = "medium"; Description = "GraphQL API layer"; Directories = $false },
        [pscustomobject]@{ Name = "FastAPI"; Category = "Web framework"; Files = @(); Keywords = @("fastapi"); Packages = @("fastapi"); Confidence = "high"; Description = "FastAPI Python web framework"; Directories = $false },
        [pscustomobject]@{ Name = "Django"; Category = "Web framework"; Files = @(); Keywords = @("django"); Packages = @("django"); Confidence = "high"; Description = "Django Python web framework"; Directories = $false },
        [pscustomobject]@{ Name = "Flask"; Category = "Web framework"; Files = @(); Keywords = @("flask"); Packages = @("flask"); Confidence = "medium"; Description = "Flask Python web framework"; Directories = $false },
        [pscustomobject]@{ Name = "Express"; Category = "Web framework"; Files = @(); Keywords = @("express"); Packages = @("express"); Confidence = "medium"; Description = "Express Node.js web framework"; Directories = $false },
        [pscustomobject]@{ Name = "NestJS"; Category = "Web framework"; Files = @(); Keywords = @("@nestjs/core"); Packages = @("@nestjs/core"); Confidence = "high"; Description = "NestJS Node.js framework"; Directories = $false },
        [pscustomobject]@{ Name = "GitHub Actions"; Category = "CI/CD"; Files = @(".github/workflows"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "GitHub Actions CI"; Directories = $true },
        [pscustomobject]@{ Name = "GitLab CI"; Category = "CI/CD"; Files = @(".gitlab-ci.yml"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "GitLab CI"; Directories = $false },
        [pscustomobject]@{ Name = "Jenkins"; Category = "CI/CD"; Files = @("Jenkinsfile"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Jenkins CI"; Directories = $false },
        [pscustomobject]@{ Name = "Terraform"; Category = "Infrastructure"; Files = @("*.tf"); Keywords = @(); Packages = @(); Confidence = "high"; Description = "Terraform infrastructure-as-code"; Directories = $false },
        [pscustomobject]@{ Name = "AWS CDK"; Category = "Infrastructure"; Files = @("cdk.json"); Keywords = @("aws-cdk"); Packages = @("aws-cdk-lib", "aws-cdk"); Confidence = "high"; Description = "AWS CDK infrastructure-as-code"; Directories = $false },
        [pscustomobject]@{ Name = "LangChain"; Category = "AI / RAG"; Files = @(); Keywords = @("langchain", "langchain-core", "@langchain/core"); Packages = @("langchain", "langchain-core", "@langchain/core"); Confidence = "high"; Description = "LangChain LLM framework"; Directories = $false },
        [pscustomobject]@{ Name = "LlamaIndex"; Category = "AI / RAG"; Files = @(); Keywords = @("llama-index", "llama_index"); Packages = @("llama-index", "llama_index"); Confidence = "high"; Description = "LlamaIndex data framework for LLM applications"; Directories = $false },
        [pscustomobject]@{ Name = "ChromaDB"; Category = "AI / RAG"; Files = @(); Keywords = @("chromadb"); Packages = @("chromadb"); Confidence = "high"; Description = "ChromaDB vector database for embeddings"; Directories = $false },
        [pscustomobject]@{ Name = "Pinecone"; Category = "AI / RAG"; Files = @(); Keywords = @("@pinecone-database/pinecone", "pinecone-client", "pinecone"); Packages = @("@pinecone-database/pinecone", "pinecone-client", "pinecone"); Confidence = "high"; Description = "Pinecone managed vector database"; Directories = $false },
        [pscustomobject]@{ Name = "Qdrant"; Category = "AI / RAG"; Files = @(); Keywords = @("qdrant"); Packages = @("qdrant-client", "qdrant"); Confidence = "high"; Description = "Qdrant vector database"; Directories = $false },
        [pscustomobject]@{ Name = "Weaviate"; Category = "AI / RAG"; Files = @(); Keywords = @("weaviate-client"); Packages = @("weaviate-client", "weaviate"); Confidence = "high"; Description = "Weaviate vector database"; Directories = $false },
        [pscustomobject]@{ Name = "pgvector"; Category = "AI / RAG"; Files = @(); Keywords = @("pgvector"); Packages = @("pgvector"); Confidence = "high"; Description = "pgvector vector-similarity extension for PostgreSQL"; Directories = $false },
        [pscustomobject]@{ Name = "MCP"; Category = "AI / Tooling"; Files = @(); Keywords = @("modelcontextprotocol", "@modelcontextprotocol/sdk", "mcp-server", "mcp_sdk"); Packages = @("modelcontextprotocol", "@modelcontextprotocol/sdk", "mcp"); Confidence = "high"; Description = "Model Context Protocol integration"; Directories = $false },
        [pscustomobject]@{ Name = "OpenAI API"; Category = "AI / API"; Files = @(); Keywords = @("openai"); Packages = @("openai"); Confidence = "medium"; Description = "OpenAI API integration"; Directories = $false },
        [pscustomobject]@{ Name = "Anthropic API"; Category = "AI / API"; Files = @(); Keywords = @("anthropic", "@anthropic-ai/sdk"); Packages = @("anthropic", "@anthropic-ai/sdk"); Confidence = "medium"; Description = "Anthropic Claude API integration"; Directories = $false },
        [pscustomobject]@{ Name = "Pytest"; Category = "Testing"; Files = @(); Keywords = @("pytest"); Packages = @("pytest"); Confidence = "high"; Description = "Pytest testing framework"; Directories = $false },
        [pscustomobject]@{ Name = "Jest"; Category = "Testing"; Files = @(); Keywords = @("jest"); Packages = @("jest"); Confidence = "medium"; Description = "Jest testing framework"; Directories = $false },
        [pscustomobject]@{ Name = "Vitest"; Category = "Testing"; Files = @(); Keywords = @("vitest"); Packages = @("vitest"); Confidence = "medium"; Description = "Vitest testing framework"; Directories = $false },
        [pscustomobject]@{ Name = "Playwright"; Category = "Testing"; Files = @("playwright.config.ts", "playwright.config.js"); Keywords = @("@playwright/test"); Packages = @("@playwright/test", "playwright"); Confidence = "high"; Description = "Playwright end-to-end testing"; Directories = $false },
        [pscustomobject]@{ Name = "Cypress"; Category = "Testing"; Files = @("cypress.config.ts", "cypress.config.js", "cypress.json"); Keywords = @("cypress"); Packages = @("cypress"); Confidence = "medium"; Description = "Cypress end-to-end testing"; Directories = $false },
        [pscustomobject]@{ Name = "ESLint"; Category = "Linting"; Files = @(".eslintrc", ".eslintrc.json", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.yml", ".eslintrc.yaml", "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs"); Keywords = @("eslint"); Packages = @("eslint"); Confidence = "high"; Description = "ESLint linter"; Directories = $false },
        [pscustomobject]@{ Name = "Prettier"; Category = "Formatting"; Files = @(".prettierrc", ".prettierrc.json", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.yml", ".prettierrc.yaml", "prettier.config.js"); Keywords = @("prettier"); Packages = @("prettier"); Confidence = "high"; Description = "Prettier code formatter"; Directories = $false }
    )
}

function Find-TechnologyMarkers {
    param(
        [string]$Root,
        [string[]]$Subdirectories,
        [string[]]$ExtraKeywords,
        [bool]$Recurse,
        [string[]]$ExcludeDirectories,
        [bool]$ShowHidden
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

    $markers = Get-TechnologyMarkersCatalog
    $keyFileNames = @(
        "package.json", "requirements.txt", "requirements-dev.txt",
        "requirements-test.txt", "pyproject.toml", "Pipfile", "setup.py",
        "go.mod", "Cargo.toml"
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
            $packages = ConvertTo-ObjectArray -InputObject $marker.Packages

            if ($marker.Directories) {
                foreach ($directoryName in $marker.Files) {
                    $candidate = Join-Path $root $directoryName
                    if (Test-Path -LiteralPath $candidate -PathType Container) {
                        $found = $true
                        $evidence += (Get-RelativePathSafe -Root $Root -FullPath $candidate) + "/"
                    }
                }
            }
            elseif ($marker.Files.Count -gt 0) {
                if ($marker.Files -contains "*.tf") {
                    $tfFiles = ConvertTo-ObjectArray -InputObject (
                        Find-FilesByFilter -Root $root -Filter "*.tf" -Recurse:$Recurse `
                            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
                    )
                    if ($tfFiles.Count -gt 0) {
                        $found = $true
                        $evidence += Get-RelativePathSafe -Root $Root -FullPath $tfFiles[0]
                    }
                }
                else {
                    $matchedFiles = ConvertTo-ObjectArray -InputObject (
                        Find-NamedFiles -Root $root -FileNames $marker.Files -Recurse:$Recurse `
                            -ExcludeDirectories $ExcludeDirectories -ShowHidden:$ShowHidden
                    )

                    foreach ($matched in $matchedFiles) {
                        $found = $true
                        $evidence += Get-RelativePathSafe -Root $Root -FullPath $matched
                    }
                }
            }

            if (-not $found -and ($marker.Keywords.Count -gt 0 -or $ExtraKeywords.Count -gt 0 -or $packages.Count -gt 0)) {
                $searchTerms = @()
                $searchTerms += $packages
                $searchTerms += $marker.Keywords
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
                        elseif ($leaf -eq "pyproject.toml" -or $leaf -eq "Pipfile" -or $leaf -eq "setup.py" -or $leaf -eq "go.mod" -or $leaf -eq "Cargo.toml") {
                            $matched = Test-TomlPackagePresent -Content $content -PackageName $term
                        }
                        else {
                            $matched = $content -match [regex]::Escape($term)
                        }

                        if ($matched) {
                            $found = $true
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
                    Name        = $marker.Name
                    Category    = $marker.Category
                    Confidence  = $marker.Confidence
                    Description = $marker.Description
                    Packages    = $packages
                    Evidence    = (($evidence | Select-Object -Unique) -join "; ")
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
        [bool]$ShowHidden
    )

    $findings = ConvertTo-ObjectArray -InputObject (
        Find-TechnologyMarkers `
            -Root $Root `
            -Subdirectories $Subdirectories `
            -ExtraKeywords $ExtraKeywords `
            -Recurse:$Recurse `
            -ExcludeDirectories $ExcludeDirectories `
            -ShowHidden:$ShowHidden
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
            Technology    = $finding.Name
            Category      = $finding.Category
            Version       = $version
            VersionSource = $versionSource
            Confidence    = $finding.Confidence
            Description   = $finding.Description
            Evidence      = $finding.Evidence
            ResumeLine    = ""
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

function Select-FindingsByConfidence {
    param(
        [array]$Findings,
        [string]$MinConfidence
    )

    if ($MinConfidence -eq "high") {
        return , @($Findings | Where-Object { $_.Confidence -eq "high" })
    }

    return , @($Findings)
}

function Get-ResumeSummary {
    param([array]$Findings)

    if ($Findings.Count -eq 0) {
        return [ordered]@{
            StackLine = ""
            Bullets   = @()
            ByCategory = @()
        }
    }

    $ordered = @($Findings | Sort-Object Category, Technology)
    $stackParts = @(
        foreach ($f in $ordered) {
            if ([string]::IsNullOrWhiteSpace($f.Version)) {
                $f.Technology
            }
            else {
                ($f.Technology + " " + $f.Version)
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
    $ai = @($ordered | Where-Object { $_.Category -like "AI*" })
    $web = @($ordered | Where-Object { $_.Category -in @("Web framework", "Frontend framework") })
    $runtime = @($ordered | Where-Object { $_.Category -eq "Runtime" })
    $containers = @($ordered | Where-Object { $_.Category -eq "Containerization" })

    if ($web.Count -gt 0 -or $runtime.Count -gt 0) {
        $parts = @($runtime + $web | ForEach-Object { $_.ResumeLine })
        $bullets += ("Developed application stack with " + ($parts -join ", ") + ".")
    }

    if ($ai.Count -gt 0) {
        $parts = @($ai | ForEach-Object { $_.ResumeLine })
        $bullets += ("Implemented AI/RAG capabilities using " + ($parts -join ", ") + ".")
    }

    if ($containers.Count -gt 0) {
        $parts = @($containers | ForEach-Object { $_.ResumeLine })
        $bullets += ("Packaged and ran services with " + ($parts -join ", ") + ".")
    }

    if ($bullets.Count -eq 0) {
        $bullets += ("Worked with " + ($stackParts -join ", ") + ".")
    }

    return [ordered]@{
        StackLine  = ($stackParts -join " · ")
        Bullets    = $bullets
        ByCategory = $byCategory
    }
}

function ConvertTo-MarkdownReport {
    param(
        [array]$Findings,
        [switch]$IncludeResume
    )

    $lines = @()
    $lines += "# Project Technology Inventory"
    $lines += ""
    $lines += ("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $lines += ("Tool: " + $script:CliName)
    $lines += ""

    $summary = Get-ResumeSummary -Findings $Findings
    $lines += "## Resume Summary"
    $lines += ""
    if ([string]::IsNullOrWhiteSpace($summary.StackLine)) {
        $lines += "_No technologies detected._"
    }
    else {
        $lines += ("**Stack:** " + $summary.StackLine)
        $lines += ""
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
        $lines += "| Technology | Category | Version | Version Source | Confidence | Evidence |"
        $lines += "|---|---|---|---|---|---|"

        foreach ($finding in $Findings) {
            $version = if ([string]::IsNullOrWhiteSpace($finding.Version)) { "-" } else { $finding.Version }
            $source = if ([string]::IsNullOrWhiteSpace($finding.VersionSource)) { "-" } else { $finding.VersionSource }

            $lines += (
                "| " + $finding.Technology + " | " +
                $finding.Category + " | " +
                $version + " | " +
                $source + " | " +
                $finding.Confidence + " | " +
                $finding.Evidence + " |"
            )
        }

        $lines += ""
    }

    return ($lines -join "`n")
}

function ConvertTo-ResumeMarkdown {
    param([array]$Findings)

    $summary = Get-ResumeSummary -Findings $Findings
    $lines = @()
    $lines += "# Resume Technology Snapshot"
    $lines += ""
    $lines += ("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
    $lines += ""
    $lines += "## Stack"
    $lines += ""
    $lines += $summary.StackLine
    $lines += ""
    $lines += "## Bullets"
    $lines += ""
    foreach ($bullet in $summary.Bullets) {
        $lines += ("- " + $bullet)
    }
    $lines += ""
    $lines += "## Skills list"
    $lines += ""
    foreach ($finding in ($Findings | Sort-Object Category, Technology)) {
        $version = if ([string]::IsNullOrWhiteSpace($finding.Version)) { "" } else { (" (" + $finding.Version + ")") }
        $lines += ("- " + $finding.Technology + $version + " — " + $finding.Category)
    }
    $lines += ""

    return ($lines -join "`n")
}

function ConvertTo-ResumeJson {
    param([array]$Findings)

    $summary = Get-ResumeSummary -Findings $Findings

    [ordered]@{
        Technologies = @(
            foreach ($finding in $Findings) {
                [ordered]@{
                    Name          = $finding.Technology
                    Category      = $finding.Category
                    Version       = $finding.Version
                    VersionSource = $finding.VersionSource
                    Confidence    = $finding.Confidence
                    Evidence      = $finding.Evidence
                    ResumeLine    = $finding.ResumeLine
                }
            }
        )
        Summary     = $summary
        GeneratedAt = (Get-Date).ToString("o")
        Total       = $Findings.Count
        Categories  = @(
            $Findings | Group-Object -Property Category |
                Select-Object Name, Count
        )
        Tool        = $script:CliName
    }
}

# --- Main ---

try {
    Write-Host ("{0}: resolving repository..." -f $script:CliName)

    $target = Resolve-RepositoryTarget -Source $Repository

    $projectRoot = Get-RepositoryContent `
        -Target $target `
        -TargetDirectory $TargetDirectory `
        -ReuseExisting:$ReuseExisting.IsPresent

    Write-Host ("{0}: analyzing {1}" -f $script:CliName, $projectRoot)
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
            -ShowHidden:$ShowHidden.IsPresent
    )

    $findings = ConvertTo-ObjectArray -InputObject (
        Select-FindingsByConfidence -Findings $findings -MinConfidence $MinConfidence
    )

    [void](New-Item -ItemType Directory -Path $OutputDirectory -Force)

    $findings |
        Select-Object Technology, Category, Version, VersionSource, Confidence, Description, Evidence, ResumeLine |
        Export-Csv -LiteralPath (Join-Path $OutputDirectory "technologies.csv") `
            -NoTypeInformation -Encoding UTF8

    $writeMarkdown = $OutputFormat -in @("markdown", "all")
    $writeJson = $OutputFormat -in @("json", "resume", "all")
    $writeResume = $OutputFormat -in @("resume", "all")

    if ($writeMarkdown) {
        ConvertTo-MarkdownReport -Findings $findings -IncludeResume |
            Set-Content -LiteralPath (Join-Path $OutputDirectory "README.md") `
                -Encoding UTF8
    }

    if ($writeResume) {
        ConvertTo-ResumeMarkdown -Findings $findings |
            Set-Content -LiteralPath (Join-Path $OutputDirectory "resume.md") `
                -Encoding UTF8
    }

    if ($writeJson) {
        ConvertTo-ResumeJson -Findings $findings |
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
        exit 2
    }

    Write-Host ""
    Write-Host ("Detected {0} technologies:" -f $findings.Count)
    Write-Host ""

    $findings |
        Sort-Object Category, Technology |
        Format-Table Technology, Category, Version, Confidence -AutoSize -Wrap

    $summary = Get-ResumeSummary -Findings $findings
    Write-Host "Resume stack:"
    Write-Host ("  " + $summary.StackLine)
    Write-Host ""
    Write-Host ("Reports: " + (Get-Item -LiteralPath $OutputDirectory).FullName)
    exit 0
}
catch {
    Write-Error ("{0}: {1}" -f $script:CliName, $_.Exception.Message)
    exit 1
}
