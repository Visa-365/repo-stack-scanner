#requires -Version 5.1
[CmdletBinding()]
param(
    # Folder, git URL, or SSH URL.
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Repository,

    # Used for remote clone if Repository is a URL. Local copies are untouched.
    [string]$TargetDirectory = "",

    # Only files under these directories are scanned. Empty means root only.
    [string[]]$Subdirectories = @(),

    # If true, do not clone again if the target already exists.
    [switch]$ReuseExisting,

    # Extra keywords for detection, matched against file contents of marker files.
    [string[]]$ExtraKeywords = @(),

    [ValidateSet("csv", "markdown", "json", "all")]
    [string]$OutputFormat = "markdown",

    [string]$OutputDirectory = (
        Join-Path (Get-Location) (
            "project-stack-" + (Get-Date -Format "yyyyMMdd-HHmmss")
        )
    ),

    [switch]$ShowHidden
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Resolve-RepositoryTarget {
    param([string]$Source)

    $trimmed = $Source.Trim()

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw "Repository cannot be empty."
    }

    # Local directory.
    if (Test-Path -LiteralPath $trimmed -PathType Container) {
        $item = Get-Item -LiteralPath $trimmed
        return [pscustomobject]@{
            Kind = "local"
            Path = $item.FullName
        }
    }

    # URLs.
    $uri = $null

    if ([Uri]::TryCreate(
        $trimmed,
        [UriKind]::Absolute,
        [ref]$uri
    )) {
        if ($uri.Scheme -in @("http", "https")) {
            return [pscustomobject]@{
                Kind = "remote"
                Path = $trimmed
            }
        }
    }

    # SSH URLs like git@github.com:owner/repo.git
    if ($trimmed -match "^git@[^:]+:.+$") {
        return [pscustomobject]@{
            Kind = "remote"
            Path = $trimmed
        }
    }

    # Git shorthand like owner/repo (treated as GitHub by convention).
    if ($trimmed -match "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") {
        return [pscustomobject]@{
            Kind = "remote"
            Path = ("https://github.com/" + $trimmed + ".git")
        }
    }

    # Fallback: try as local path for clarity.
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
        $TargetDirectory = Join-Path $env:TEMP (
            "repo-" + $safeName
        )
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
        "clone",
        "--depth", "1",
        "--quiet",
        "--",
        $Target.Path,
        $TargetDirectory
    )

    Write-Host ("Cloning: " + $Target.Path)
    & $gitExe @argumentList

    if ($LASTEXITCODE -ne 0) {
        throw ("git clone failed with exit code " + $LASTEXITCODE + "." + `
            "For private repositories, configure GIT_TOKEN or git credentials before running this script.")
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

function ConvertFrom-JsonFile {
    param([string]$FilePath)

    try {
        return (Get-Content -LiteralPath $FilePath -Raw |
            ConvertFrom-Json)
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

    $lines = Get-Content -LiteralPath $DockerfilePath -ErrorAction SilentlyContinue

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#")) {
            continue
        }

        if ($trimmed -match "^(?i)FROM\s+(?<image>[^\s]+)") {
            $image = $Matches["image"]
            if ($image -match "^(?<base>[a-zA-Z0-9_.-]+):(?<tag>[0-9][0-9a-zA-Z_.-]*)$") {
                $versions += [pscustomobject]@{
                    Technology = $Matches["base"]
                    Version = $Matches["tag"]
                    Source = "Dockerfile FROM"
                }
            }
        }
    }

    $versions
}

function Get-NpmVersion {
    param([string]$PackageJsonPath)

    $json = ConvertFrom-JsonFile -FilePath $PackageJsonPath

    if ($null -eq $json) {
        return ""
    }

    $versionProperty = $json.PSObject.Properties["version"]

    if ($null -ne $versionProperty) {
        $version = [string]$versionProperty.Value
        if ($version -match "^\d+(\.\d+)*(\.\d+)?$") {
            return $version
        }
    }

    return ""
}

function Get-PythonVersion {
    param([string]$PyprojectTomlPath)

    $content = Get-Content -LiteralPath $PyprojectTomlPath -Raw `
        -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($content)) {
        return ""
    }

    $matchesList = @(
        [regex]::Matches(
            $content,
            '(?m)^python\s*=\s*"[^"]*(\d+\.\d+(?:\.\d+)?)',
            "IgnoreCase"
        )
    )

    if ($matchesList.Count -gt 0) {
        return $matchesList[0].Groups[1].Value
    }

    return ""
}

function Get-CargoVersion {
    param([string]$CargoTomlPath)

    $content = Get-Content -LiteralPath $CargoTomlPath -Raw `
        -ErrorAction SilentlyContinue

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

    $content = Get-Content -LiteralPath $GoModPath -Raw `
        -ErrorAction SilentlyContinue

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

function Find-TechnologyMarkers {
    param(
        [string]$Root,
        [string[]]$Subdirectories,
        [string[]]$ExtraKeywords
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

    # Common frameworks, runtimes and tools. Extend as needed.
    $markers = @(
        [pscustomobject]@{
            Name = "Docker"
            Category = "Containerization"
            Files = @("Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")
            Keywords = @()
            Confidence = "high"
            Description = "Docker containerization"
        },
        [pscustomobject]@{
            Name = "Kubernetes"
            Category = "Containerization"
            Files = @("k8s", "kubernetes", "charts", "manifests")
            Directories = $true
            Keywords = @()
            Confidence = "medium"
            Description = "Kubernetes orchestration"
        },
        [pscustomobject]@{
            Name = "Node.js"
            Category = "Runtime"
            Files = @("package.json")
            Keywords = @("node", "npm", "yarn", "pnpm")
            Confidence = "high"
            Description = "Node.js runtime"
        },
        [pscustomobject]@{
            Name = "Python"
            Category = "Runtime"
            Files = @("requirements.txt", "pyproject.toml", "setup.py", "Pipfile", "poetry.lock", ".python-version")
            Keywords = @()
            Confidence = "high"
            Description = "Python runtime"
        },
        [pscustomobject]@{
            Name = "Go"
            Category = "Runtime"
            Files = @("go.mod", "go.sum")
            Keywords = @()
            Confidence = "high"
            Description = "Go runtime"
        },
        [pscustomobject]@{
            Name = "Rust"
            Category = "Runtime"
            Files = @("Cargo.toml", "Cargo.lock")
            Keywords = @()
            Confidence = "high"
            Description = "Rust runtime"
        },
        [pscustomobject]@{
            Name = "React"
            Category = "Frontend framework"
            Files = @("package.json")
            Keywords = @("react")
            Confidence = "high"
            Description = "React frontend framework"
        },
        [pscustomobject]@{
            Name = "Vue"
            Category = "Frontend framework"
            Files = @("package.json")
            Keywords = @("vue")
            Confidence = "high"
            Description = "Vue frontend framework"
        },
        [pscustomobject]@{
            Name = "Angular"
            Category = "Frontend framework"
            Files = @("package.json")
            Keywords = @("@angular/core")
            Confidence = "high"
            Description = "Angular frontend framework"
        },
        [pscustomobject]@{
            Name = "Svelte"
            Category = "Frontend framework"
            Files = @("package.json")
            Keywords = @("svelte")
            Confidence = "medium"
            Description = "Svelte frontend framework"
        },
        [pscustomobject]@{
            Name = "Next.js"
            Category = "Frontend framework"
            Files = @("package.json")
            Keywords = @("next")
            Confidence = "high"
            Description = "Next.js full-stack framework"
        },
        [pscustomobject]@{
            Name = "TypeScript"
            Category = "Language"
            Files = @("tsconfig.json")
            Keywords = @("typescript")
            Confidence = "high"
            Description = "TypeScript language"
        },
        [pscustomobject]@{
            Name = "Tailwind CSS"
            Category = "Styling"
            Files = @("tailwind.config.js", "tailwind.config.ts", "tailwind.config.cjs", "tailwind.config.mjs")
            Keywords = @("tailwindcss")
            Confidence = "high"
            Description = "Tailwind CSS utility framework"
        },
        [pscustomobject]@{
            Name = "PostgreSQL"
            Category = "Database"
            Files = @()
            Keywords = @("postgres", "postgresql")
            Confidence = "medium"
            Description = "PostgreSQL relational database"
        },
        [pscustomobject]@{
            Name = "MySQL"
            Category = "Database"
            Files = @()
            Keywords = @("mysql")
            Confidence = "medium"
            Description = "MySQL relational database"
        },
        [pscustomobject]@{
            Name = "MongoDB"
            Category = "Database"
            Files = @()
            Keywords = @("mongodb", "mongoose")
            Confidence = "medium"
            Description = "MongoDB document database"
        },
        [pscustomobject]@{
            Name = "Redis"
            Category = "Database"
            Files = @()
            Keywords = @("redis", "ioredis")
            Confidence = "medium"
            Description = "Redis in-memory database"
        },
        [pscustomobject]@{
            Name = "GraphQL"
            Category = "API"
            Files = @("schema.graphql")
            Keywords = @("graphql", "apollo", "urql")
            Confidence = "medium"
            Description = "GraphQL API layer"
        },
        [pscustomobject]@{
            Name = "FastAPI"
            Category = "Web framework"
            Files = @()
            Keywords = @("fastapi")
            Confidence = "high"
            Description = "FastAPI Python web framework"
        },
        [pscustomobject]@{
            Name = "Django"
            Category = "Web framework"
            Files = @()
            Keywords = @("django")
            Confidence = "high"
            Description = "Django Python web framework"
        },
        [pscustomobject]@{
            Name = "Flask"
            Category = "Web framework"
            Files = @()
            Keywords = @("flask")
            Confidence = "medium"
            Description = "Flask Python web framework"
        },
        [pscustomobject]@{
            Name = "Express"
            Category = "Web framework"
            Files = @()
            Keywords = @("express")
            Confidence = "medium"
            Description = "Express Node.js web framework"
        },
        [pscustomobject]@{
            Name = "NestJS"
            Category = "Web framework"
            Files = @()
            Keywords = @("@nestjs/core")
            Confidence = "high"
            Description = "NestJS Node.js framework"
        },
        [pscustomobject]@{
            Name = "GitHub Actions"
            Category = "CI/CD"
            Files = @(".github/workflows")
            Directories = $true
            Keywords = @()
            Confidence = "high"
            Description = "GitHub Actions CI"
        },
        [pscustomobject]@{
            Name = "GitLab CI"
            Category = "CI/CD"
            Files = @(".gitlab-ci.yml")
            Keywords = @()
            Confidence = "high"
            Description = "GitLab CI"
        },
        [pscustomobject]@{
            Name = "Jenkins"
            Category = "CI/CD"
            Files = @("Jenkinsfile")
            Keywords = @()
            Confidence = "high"
            Description = "Jenkins CI"
        },
        [pscustomobject]@{
            Name = "Terraform"
            Category = "Infrastructure"
            Files = @("*.tf")
            Keywords = @()
            Confidence = "high"
            Description = "Terraform infrastructure-as-code"
        },
        [pscustomobject]@{
            Name = "AWS CDK"
            Category = "Infrastructure"
            Files = @("cdk.json")
            Keywords = @("aws-cdk")
            Confidence = "high"
            Description = "AWS CDK infrastructure-as-code"
        },
        [pscustomobject]@{
            Name = "LangChain"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("langchain", "langchain-core", "@langchain/core")
            Confidence = "high"
            Description = "LangChain LLM framework"
        },
        [pscustomobject]@{
            Name = "LlamaIndex"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("llama-index", "llama_index")
            Confidence = "high"
            Description = "LlamaIndex data framework for LLM applications"
        },
        [pscustomobject]@{
            Name = "ChromaDB"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("chromadb")
            Confidence = "high"
            Description = "ChromaDB vector database for embeddings"
        },
        [pscustomobject]@{
            Name = "Pinecone"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("@pinecone-database/pinecone", "pinecone-client", "pinecone")
            Confidence = "high"
            Description = "Pinecone managed vector database"
        },
        [pscustomobject]@{
            Name = "Qdrant"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("qdrant")
            Confidence = "high"
            Description = "Qdrant vector database"
        },
        [pscustomobject]@{
            Name = "Weaviate"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("weaviate-client")
            Confidence = "high"
            Description = "Weaviate vector database"
        },
        [pscustomobject]@{
            Name = "pgvector"
            Category = "AI / RAG"
            Files = @()
            Keywords = @("pgvector")
            Confidence = "high"
            Description = "pgvector vector-similarity extension for PostgreSQL"
        },
        [pscustomobject]@{
            Name = "MCP"
            Category = "AI / Tooling"
            Files = @()
            Keywords = @("modelcontextprotocol", "@modelcontextprotocol/sdk", "mcp-server", "mcp_sdk")
            Confidence = "high"
            Description = "Model Context Protocol integration"
        },
        [pscustomobject]@{
            Name = "OpenAI API"
            Category = "AI / API"
            Files = @()
            Keywords = @("openai")
            Confidence = "medium"
            Description = "OpenAI API integration"
        },
        [pscustomobject]@{
            Name = "Anthropic API"
            Category = "AI / API"
            Files = @()
            Keywords = @("anthropic", "@anthropic-ai/sdk")
            Confidence = "medium"
            Description = "Anthropic Claude API integration"
        },
        [pscustomobject]@{
            Name = "Pytest"
            Category = "Testing"
            Files = @()
            Keywords = @("pytest")
            Confidence = "high"
            Description = "Pytest testing framework"
        },
        [pscustomobject]@{
            Name = "Jest"
            Category = "Testing"
            Files = @()
            Keywords = @("jest")
            Confidence = "medium"
            Description = "Jest testing framework"
        },
        [pscustomobject]@{
            Name = "Vitest"
            Category = "Testing"
            Files = @()
            Keywords = @("vitest")
            Confidence = "medium"
            Description = "Vitest testing framework"
        },
        [pscustomobject]@{
            Name = "Playwright"
            Category = "Testing"
            Files = @("playwright.config.ts", "playwright.config.js")
            Keywords = @("@playwright/test")
            Confidence = "high"
            Description = "Playwright end-to-end testing"
        },
        [pscustomobject]@{
            Name = "Cypress"
            Category = "Testing"
            Files = @("cypress.config.ts", "cypress.config.js", "cypress.json")
            Keywords = @("cypress")
            Confidence = "medium"
            Description = "Cypress end-to-end testing"
        },
        [pscustomobject]@{
            Name = "ESLint"
            Category = "Linting"
            Files = @(".eslintrc", ".eslintrc.json", ".eslintrc.js", ".eslintrc.cjs", ".eslintrc.yml", ".eslintrc.yaml", "eslint.config.js", "eslint.config.mjs", "eslint.config.cjs")
            Keywords = @("eslint")
            Confidence = "high"
            Description = "ESLint linter"
        },
        [pscustomobject]@{
            Name = "Prettier"
            Category = "Formatting"
            Files = @(".prettierrc", ".prettierrc.json", ".prettierrc.js", ".prettierrc.cjs", ".prettierrc.yml", ".prettierrc.yaml", "prettier.config.js")
            Keywords = @("prettier")
            Confidence = "high"
            Description = "Prettier code formatter"
        }
    )

    foreach ($root in $scanRoots) {
        if (-not (Test-Path -LiteralPath $root)) {
            continue
        }

        foreach ($marker in $markers) {
            $found = $false
            $evidence = @()

            foreach ($relativePath in $marker.Files) {
                $candidate = Join-Path $root $relativePath
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $found = $true
                    $evidence += $relativePath
                }
            }

            if ($marker.Directories) {
                foreach ($directoryName in $marker.Files) {
                    $candidate = Join-Path $root $directoryName
                    if (Test-Path -LiteralPath $candidate -PathType Container) {
                        $found = $true
                        $evidence += ($directoryName + "/")
                    }
                }
            }

            if (-not $found) {
                # Scan the text of key marker files for keywords.
                $keyFiles = @(
                    "package.json",
                    "requirements.txt",
                    "pyproject.toml",
                    "Pipfile",
                    "setup.py",
                    "go.mod",
                    "Cargo.toml"
                )

                foreach ($relativePath in $keyFiles) {
                    $candidate = Join-Path $root $relativePath

                    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                        continue
                    }

                    $content = Get-Content -LiteralPath $candidate -Raw `
                        -ErrorAction SilentlyContinue

                    if ([string]::IsNullOrWhiteSpace($content)) {
                        continue
                    }

                    foreach ($keyword in $marker.Keywords + $ExtraKeywords) {
                        if ($content -match [regex]::Escape($keyword)) {
                            $found = $true
                            $evidence += ("Keyword: " + $keyword + " in " + $relativePath)
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
                    Name = $marker.Name
                    Category = $marker.Category
                    Confidence = $marker.Confidence
                    Description = $marker.Description
                    Evidence = ($evidence -join "; ")
                }
            }
        }
    }

    $findings
}

function Get-VersionedFindings {
    param(
        [string]$Root,
        [string[]]$Subdirectories,
        [string[]]$ExtraKeywords
    )

    $findings = Find-TechnologyMarkers `
        -Root $Root `
        -Subdirectories $Subdirectories `
        -ExtraKeywords $ExtraKeywords

    $versionedFindings = @()

    foreach ($finding in $findings) {
        $version = ""
        $versionSource = ""

        # Node.js / npm projects: package.json version.
        if ($finding.Name -eq "Node.js") {
            $packageJson = Get-ProjectFile -Root $Root -RelativePath "package.json"

            if ($null -ne $packageJson) {
                $version = Get-NpmVersion -PackageJsonPath $packageJson
                $versionSource = "package.json"
            }
        }

        # Python: pyproject.toml or .python-version.
        if ($finding.Name -eq "Python") {
            $pyproject = Get-ProjectFile -Root $Root -RelativePath "pyproject.toml"

            if ($null -ne $pyproject) {
                $version = Get-PythonVersion -PyprojectTomlPath $pyproject
                $versionSource = "pyproject.toml"
            }

            if ([string]::IsNullOrWhiteSpace($version)) {
                $pythonVersionFile = Get-ProjectFile `
                    -Root $Root -RelativePath ".python-version"

                if ($null -ne $pythonVersionFile) {
                    $version = (Get-Content -LiteralPath $pythonVersionFile -ErrorAction SilentlyContinue |
                        Select-Object -First 1).Trim()
                    $versionSource = ".python-version"
                }
            }
        }

        # Go.
        if ($finding.Name -eq "Go") {
            $goMod = Get-ProjectFile -Root $Root -RelativePath "go.mod"

            if ($null -ne $goMod) {
                $version = Get-GoVersion -GoModPath $goMod
                $versionSource = "go.mod"
            }
        }

        # Rust.
        if ($finding.Name -eq "Rust") {
            $cargoToml = Get-ProjectFile -Root $Root -RelativePath "Cargo.toml"

            if ($null -ne $cargoToml) {
                $version = Get-CargoVersion -CargoTomlPath $cargoToml
                $versionSource = "Cargo.toml"
            }
        }

        # Docker: versions from FROM lines.
        if ($finding.Name -eq "Docker") {
            $dockerfile = $null
            foreach ($relativePath in @("Dockerfile", "docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml")) {
                $candidate = Join-Path $Root $relativePath
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $dockerfile = $candidate
                    break
                }
            }

            if ($null -ne $dockerfile) {
                $dockerVersions = Get-DockerfileVersions -DockerfilePath $dockerfile

                if ($dockerVersions.Count -gt 0) {
                    $finding | Add-Member -NotePropertyName DockerImages `
                        -NotePropertyValue $dockerVersions -Force

                    $first = $dockerVersions[0]
                    $version = $first.Version
                    $versionSource = ("Dockerfile FROM (" + $first.Technology + ")")
                }
            }
        }

        $versionedFindings += [pscustomobject]@{
            Technology = $finding.Name
            Category = $finding.Category
            Version = $version
            VersionSource = $versionSource
            Confidence = $finding.Confidence
            Description = $finding.Description
            Evidence = $finding.Evidence
        }
    }

    $versionedFindings
}

function ConvertTo-MarkdownReport {
    param([array]$Findings)

    $lines = @()
    $lines += "# Project Technology Inventory"
    $lines += ""
    $lines += ("Generated: " + (Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
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
            $version = if ([string]::IsNullOrWhiteSpace($finding.Version)) {
                "-"
            }
            else {
                $finding.Version
            }

            $lines += (
                "| " + $finding.Technology + " | " +
                $finding.Category + " | " +
                $version + " | " +
                $finding.VersionSource + " | " +
                $finding.Confidence + " | " +
                $finding.Evidence + " |"
            )
        }

        $lines += ""
    }

    return ($lines -join "`n")
}

function ConvertTo-ResumeJson {
    param([array]$Findings)

    $resumeData = [ordered]@{
        Technologies = @(
            foreach ($finding in $Findings) {
                [ordered]@{
                    Name = $finding.Technology
                    Category = $finding.Category
                    Version = $finding.Version
                    VersionSource = $finding.VersionSource
                    Confidence = $finding.Confidence
                    Evidence = $finding.Evidence
                }
            }
        )
        GeneratedAt = (Get-Date).ToString("o")
        Total = $Findings.Count
        Categories = @(
            $Findings | Group-Object -Property Category |
                Select-Object Name, Count
        )
    }

    $resumeData
}

# --- Main ---

$target = Resolve-RepositoryTarget -Source $Repository

$projectRoot = Get-RepositoryContent `
    -Target $target `
    -TargetDirectory $TargetDirectory `
    -ReuseExisting:$ReuseExisting.IsPresent

Write-Host ("Analyzing: " + $projectRoot)

$findings = @(Get-VersionedFindings `
    -Root $projectRoot `
    -Subdirectories $Subdirectories `
    -ExtraKeywords $ExtraKeywords)

[void](New-Item -ItemType Directory -Path $OutputDirectory -Force)

$findings |
    Export-Csv -LiteralPath (Join-Path $OutputDirectory "technologies.csv") `
        -NoTypeInformation -Encoding UTF8

if ($OutputFormat -in @("markdown", "all")) {
    ConvertTo-MarkdownReport -Findings $findings |
        Set-Content -LiteralPath (
            Join-Path $OutputDirectory "README.md")
        -Encoding UTF8
}

if ($OutputFormat -in @("json", "all")) {
    ConvertTo-ResumeJson -Findings $findings |
        ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (
            Join-Path $OutputDirectory "technologies.json")
        -Encoding UTF8
}

if ($OutputFormat -in @("csv", "all")) {
    Write-Host ("CSV report saved to: " + (Join-Path $OutputDirectory "technologies.csv"))
}

if ($OutputFormat -in @("markdown", "all")) {
    Write-Host ("Markdown report saved to: " + (Join-Path $OutputDirectory "README.md"))
}

if ($OutputFormat -in @("json", "all")) {
    Write-Host ("JSON report saved to: " + (Join-Path $OutputDirectory "technologies.json"))
}

if ($findings.Count -eq 0) {
    Write-Warning "No technologies detected in the specified project."
}
else {
    Write-Host ""
    Write-Host ("Detected " + $findings.Count + " technologies:")
    Write-Host ""

    $findings |
        Sort-Object Category, Technology |
        Format-Table Technology, Category, Version, Confidence -AutoSize -Wrap

    Write-Host ""
    Write-Host ("Full reports: " + (Get-Item -LiteralPath $OutputDirectory).FullName)
}
