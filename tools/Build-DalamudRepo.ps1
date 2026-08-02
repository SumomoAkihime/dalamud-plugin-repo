param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [string]$SourceRoot = "",
    [string]$OutputRoot = "",
    [string]$ConfigPath = "",

    [string[]]$InternalName = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSScriptRoot) {
    $ScriptRoot = $PSScriptRoot
} else {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$RepoRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path

function Read-Utf8Text {
    param([string]$Path)

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return $text.TrimStart([char]0xFEFF)
}

function Write-Utf8Text {
    param(
        [string]$Path,
        [string]$Text
    )

    $normalized = ($Text -replace "`r?`n", "`r`n").TrimEnd("`r", "`n") + "`r`n"
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($Path, $normalized, $utf8Bom)
}

function Get-FileSha256 {
    param([string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = (Resolve-Path (Join-Path $RepoRoot "..")).Path
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepoRoot "plugin-repo"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $RepoRoot "repo-config.json"
}

function Normalize-BaseUrl {
    param([string]$Url)
    return $Url.TrimEnd("/")
}

function ConvertTo-UnixTimestamp {
    param([datetime]$Date)
    $offset = [DateTimeOffset]::new($Date.ToUniversalTime())
    return [int64]$offset.ToUnixTimeSeconds()
}

function Read-CsprojVersion {
    param([string]$CsprojPath)

    [xml]$xml = Read-Utf8Text -Path $CsprojPath
    $versionNode = $xml.SelectSingleNode("//Project/PropertyGroup/Version")
    if (-not $versionNode -or [string]::IsNullOrWhiteSpace($versionNode.InnerText)) {
        throw "Could not find <Version> in $CsprojPath"
    }

    return [string]$versionNode.InnerText
}

function Read-JsonManifest {
    param([string]$Path)
    return Read-Utf8Text -Path $Path | ConvertFrom-Json
}

function Read-RepoConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            excludedInternalNames = @()
        }
    }

    return Read-Utf8Text -Path $Path | ConvertFrom-Json
}

function Read-ZipManifest {
    param(
        [string]$ZipPath,
        [string]$InternalName
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entryName = "$InternalName.json"
        $entry = $archive.Entries | Where-Object { $_.FullName -eq $entryName } | Select-Object -First 1
        if (-not $entry) {
            $entry = $archive.Entries |
                Where-Object {
                    $_.FullName -notmatch '/' -and
                    $_.Name -like '*.json' -and
                    $_.Name -notlike '*.deps.json'
                } |
                Select-Object -First 1
        }

        if (-not $entry) {
            return $null
        }

        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
        try {
            $json = $reader.ReadToEnd()
        } finally {
            $reader.Dispose()
        }

        return $json | ConvertFrom-Json
    } finally {
        $archive.Dispose()
    }
}

function Read-SimpleYamlManifest {
    param([string]$Path)

    $result = @{}
    $currentListKey = $null

    foreach ($rawLine in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        $line = $rawLine.TrimEnd()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.TrimStart().StartsWith("#")) { continue }

        if ($line -match '^\s+-\s+(.*)$') {
            if (-not $currentListKey) {
                throw "Unexpected YAML list item in ${Path}: $line"
            }

            if (-not $result.ContainsKey($currentListKey)) {
                $result[$currentListKey] = @()
            }

            $item = $Matches[1].Trim()
            if (($item.StartsWith('"') -and $item.EndsWith('"')) -or ($item.StartsWith("'") -and $item.EndsWith("'"))) {
                $item = $item.Substring(1, $item.Length - 2)
            }

            $result[$currentListKey] += $item
            continue
        }

        if ($line -match '^\s*([A-Za-z0-9_]+)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $value = $Matches[2].Trim()

            if ([string]::IsNullOrEmpty($value)) {
                $result[$key] = @()
                $currentListKey = $key
                continue
            }

            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }

            $result[$key] = $value
            $currentListKey = $null
            continue
        }

        throw "Unsupported YAML syntax in ${Path}: $line"
    }

    return [pscustomobject]$result
}

function Get-ManifestMetadata {
    param([string]$ProjectRoot)

    $jsonManifest = Get-ChildItem $ProjectRoot -Recurse -File -Filter *.json |
        Where-Object { $_.BaseName -eq $_.Directory.Name } |
        Select-Object -First 1

    if ($jsonManifest) {
        return @{
            Type = "json"
            Path = $jsonManifest.FullName
            Data = Read-JsonManifest -Path $jsonManifest.FullName
        }
    }

    $yamlManifest = Get-ChildItem $ProjectRoot -Recurse -File |
        Where-Object { $_.Extension -in @(".yaml", ".yml") -and $_.BaseName -eq $_.Directory.Name } |
        Select-Object -First 1

    if ($yamlManifest) {
        return @{
            Type = "yaml"
            Path = $yamlManifest.FullName
            Data = Read-SimpleYamlManifest -Path $yamlManifest.FullName
        }
    }

    return $null
}

function Get-ProjectEntry {
    param(
        [System.IO.DirectoryInfo]$ProjectDir,
        [string]$BaseUrl,
        [string]$OutputRoot,
        [string]$ExpectedInternalName = "",
        [psobject]$ExistingEntry = $null
    )

    $manifestInfo = $null
    $manifest = $null
    $internalName = $ExpectedInternalName

    if ([string]::IsNullOrWhiteSpace($internalName)) {
        $manifestInfo = Get-ManifestMetadata -ProjectRoot $ProjectDir.FullName
        if (-not $manifestInfo) {
            return $null
        }

        $manifest = $manifestInfo.Data
        $internalName = if ($manifest.PSObject.Properties.Name -contains "InternalName") {
            [string]$manifest.InternalName
        } else {
            [string]([System.IO.Path]::GetFileNameWithoutExtension($manifestInfo.Path))
        }
    }

    $packageCandidates = @(
        (Join-Path $ProjectDir.FullName "release\$internalName\latest.zip"),
        (Join-Path $ProjectDir.FullName "$internalName\bin\Release\$internalName\latest.zip"),
        (Join-Path $ProjectDir.FullName "bin\Release\$internalName\latest.zip")
    )

    $packagePath = $packageCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $packagePath) {
        Write-Warning "Skipping $internalName because no packaged latest.zip was found."
        return $null
    }

    $packageManifest = Read-ZipManifest -ZipPath $packagePath -InternalName $internalName
    if ($packageManifest) {
        $manifest = $packageManifest
        if ($packageManifest.PSObject.Properties.Name -contains "InternalName" -and $packageManifest.InternalName) {
            $packageInternalName = [string]$packageManifest.InternalName
            if ($ExpectedInternalName -and $packageInternalName -ne $ExpectedInternalName) {
                throw "Package InternalName '$packageInternalName' does not match configured name '$ExpectedInternalName'."
            }
            $internalName = $packageInternalName
        }
        $version = [string]$packageManifest.AssemblyVersion
    } else {
        if (-not $manifestInfo) {
            $manifestInfo = Get-ManifestMetadata -ProjectRoot $ProjectDir.FullName
            if (-not $manifestInfo) {
                throw "Could not find manifest under $($ProjectDir.FullName)"
            }
            $manifest = $manifestInfo.Data
        }

        $csproj = Get-ChildItem $ProjectDir.FullName -Recurse -File -Filter *.csproj |
            Where-Object { $_.BaseName -eq $_.Directory.Name } |
            Select-Object -First 1

        if (-not $csproj) {
            throw "Could not find matching .csproj under $($ProjectDir.FullName)"
        }

        $version = Read-CsprojVersion -CsprojPath $csproj.FullName
    }

    $outputPluginDir = Join-Path $OutputRoot "plugins\$internalName"
    New-Item -ItemType Directory -Path $outputPluginDir -Force | Out-Null
    $outputPackagePath = Join-Path $outputPluginDir "latest.zip"
    $sourceHash = Get-FileSha256 -Path $packagePath
    $outputHash = if (Test-Path -LiteralPath $outputPackagePath) {
        Get-FileSha256 -Path $outputPackagePath
    } else {
        ""
    }
    $packageChanged = $sourceHash -ne $outputHash

    if ($packageChanged) {
        Copy-Item -LiteralPath $packagePath -Destination $outputPackagePath -Force
        Write-Host "Updated package: $internalName"
    } else {
        Write-Host "Unchanged package: $internalName"
    }

    $downloadUrl = "{0}/plugins/{1}/latest.zip" -f $BaseUrl, $internalName
    $lastUpdate = if (
        -not $packageChanged -and
        $null -ne $ExistingEntry -and
        $ExistingEntry.PSObject.Properties.Name -contains "LastUpdate"
    ) {
        [int64]$ExistingEntry.LastUpdate
    } else {
        ConvertTo-UnixTimestamp -Date ([datetime]::UtcNow)
    }

    $tags = @()
    if ($manifest.PSObject.Properties.Name -contains "Tags" -and $null -ne $manifest.Tags) {
        if ($manifest.Tags -is [string]) {
            $tags = @([string]$manifest.Tags)
        } elseif ($manifest.Tags -is [System.Collections.IEnumerable] -and -not ($manifest.Tags -is [pscustomobject])) {
            $tags = @($manifest.Tags)
        }
    }

    $entry = [ordered]@{
        Author = [string]$manifest.Author
        Name = [string]$manifest.Name
        InternalName = $internalName
        AssemblyVersion = $version
        Description = [string]$manifest.Description
        ApplicableVersion = if ($manifest.PSObject.Properties.Name -contains "ApplicableVersion" -and $manifest.ApplicableVersion) { [string]$manifest.ApplicableVersion } else { "any" }
        RepoUrl = [string]$manifest.RepoUrl
        Tags = $tags
        DalamudApiLevel = [int]$manifest.DalamudApiLevel
        LoadRequiredState = if ($manifest.PSObject.Properties.Name -contains "LoadRequiredState") { [int]$manifest.LoadRequiredState } else { 0 }
        LoadSync = if ($manifest.PSObject.Properties.Name -contains "LoadSync") { [bool]$manifest.LoadSync } else { $false }
        CanUnloadAsync = if ($manifest.PSObject.Properties.Name -contains "CanUnloadAsync") { [bool]$manifest.CanUnloadAsync } else { $false }
        LoadPriority = if ($manifest.PSObject.Properties.Name -contains "LoadPriority") { [int]$manifest.LoadPriority } else { 0 }
        Punchline = [string]$manifest.Punchline
        Changelog = if ($manifest.PSObject.Properties.Name -contains "Changelog") { [string]$manifest.Changelog } else { "" }
        DownloadLinkInstall = $downloadUrl
        DownloadLinkUpdate = $downloadUrl
        LastUpdate = $lastUpdate
    }

    if ($manifest.PSObject.Properties.Name -contains "CategoryTags" -and $manifest.CategoryTags) {
        $entry["CategoryTags"] = @($manifest.CategoryTags)
    }

    if ($manifest.PSObject.Properties.Name -contains "ImageUrls" -and $manifest.ImageUrls) {
        $entry["ImageUrls"] = @($manifest.ImageUrls)
    }

    if ($manifest.PSObject.Properties.Name -contains "IconUrl" -and $manifest.IconUrl) {
        $entry["IconUrl"] = [string]$manifest.IconUrl
    }

    if ($manifest.PSObject.Properties.Name -contains "AcceptsFeedback") {
        $entry["AcceptsFeedback"] = [bool]$manifest.AcceptsFeedback
    }

    return [pscustomobject]$entry
}

$BaseUrl = Normalize-BaseUrl -Url $BaseUrl
$repoConfig = Read-RepoConfig -Path $ConfigPath
$excludedInternalNames = @($repoConfig.excludedInternalNames)
$requestedInternalNames = @(
    $InternalName |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
)
$repoJsonPath = Join-Path $OutputRoot "repo.json"

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$pluginsOutputRoot = Join-Path $OutputRoot "plugins"
New-Item -ItemType Directory -Path $pluginsOutputRoot -Force | Out-Null

$existingEntries = @()
if (Test-Path -LiteralPath $repoJsonPath) {
    $existingEntries = @(
        (Read-Utf8Text -Path $repoJsonPath | ConvertFrom-Json) |
            ForEach-Object { $_ }
    )
}

$existingByInternalName = @{}
foreach ($existingEntry in $existingEntries) {
    $existingName = [string]$existingEntry.InternalName
    if ($existingName) {
        $existingByInternalName[$existingName] = $existingEntry
    }
}

$entries = @()
$configuredProjects = if ($repoConfig.PSObject.Properties.Name -contains "projects") {
    @($repoConfig.projects)
} else {
    @()
}

if ($configuredProjects.Count -gt 0) {
    foreach ($requestedName in $requestedInternalNames) {
        if (-not ($configuredProjects.internalName -contains $requestedName)) {
            throw "No project directory is configured for requested plugin '$requestedName'."
        }
    }

    foreach ($project in $configuredProjects) {
        $configuredName = [string]$project.internalName
        if ($requestedInternalNames.Count -gt 0 -and -not ($requestedInternalNames -contains $configuredName)) {
            continue
        }
        if ($excludedInternalNames -contains $configuredName) {
            Write-Host "Excluded plugin: $configuredName"
            continue
        }

        $projectPath = Join-Path $SourceRoot ([string]$project.directory)
        if (-not (Test-Path -LiteralPath $projectPath -PathType Container)) {
            if ($requestedInternalNames -contains $configuredName) {
                throw "Configured project directory does not exist: $projectPath"
            }
            Write-Warning "Configured project directory does not exist; preserving existing plugin if available: $projectPath"
            continue
        }

        try {
            $entry = Get-ProjectEntry `
                -ProjectDir (Get-Item -LiteralPath $projectPath) `
                -BaseUrl $BaseUrl `
                -OutputRoot $OutputRoot `
                -ExpectedInternalName $configuredName `
                -ExistingEntry $existingByInternalName[$configuredName]
        } catch {
            if ($requestedInternalNames -contains $configuredName) {
                throw
            }
            Write-Warning "Skipping $configuredName because repository metadata could not be read: $($_.Exception.Message)"
            continue
        }

        if ($entry) {
            $entries += $entry
        }
    }
} else {
    $projectDirs = Get-ChildItem $SourceRoot -Directory |
        Where-Object { $_.Name -notin @("dalamud-plugin-repo", "plugin-repo", "tools", ".git") }

    foreach ($projectDir in $projectDirs) {
        try {
            $entry = Get-ProjectEntry -ProjectDir $projectDir -BaseUrl $BaseUrl -OutputRoot $OutputRoot
        } catch {
            Write-Warning "Skipping $($projectDir.Name) because repository metadata could not be read: $($_.Exception.Message)"
            continue
        }
        if ($entry) {
            if ($requestedInternalNames.Count -gt 0 -and -not ($requestedInternalNames -contains $entry.InternalName)) {
                continue
            }
            if ($excludedInternalNames -contains $entry.InternalName) {
                Write-Host "Excluded plugin: $($entry.InternalName)"
                continue
            }
            $entries += $entry
        }
    }
}

foreach ($requestedName in $requestedInternalNames) {
    if (-not ($entries.InternalName -contains $requestedName)) {
        throw "Requested plugin was not generated: $requestedName"
    }
}

$generatedEntries = @($entries)
$entries = @()
$addedInternalNames = @{}
foreach ($existingEntry in $existingEntries) {
    $existingName = [string]$existingEntry.InternalName
    if (-not $existingName -or $excludedInternalNames -contains $existingName) {
        continue
    }

    $generatedEntry = $generatedEntries |
        Where-Object { $_.InternalName -eq $existingName } |
        Select-Object -First 1
    if ($generatedEntry) {
        $entries += $generatedEntry
        $addedInternalNames[$existingName] = $true
        continue
    }

    $packagePath = Join-Path $OutputRoot "plugins\$existingName\latest.zip"
    if (Test-Path -LiteralPath $packagePath) {
        Write-Host "Preserved existing plugin: $existingName"
        $entries += $existingEntry
        $addedInternalNames[$existingName] = $true
    }
}

foreach ($generatedEntry in $generatedEntries) {
    $generatedName = [string]$generatedEntry.InternalName
    if (-not $addedInternalNames.ContainsKey($generatedName)) {
        $entries += $generatedEntry
        $addedInternalNames[$generatedName] = $true
    }
}

$entryArray = @($entries)
if ($entryArray.Count -eq 0) {
    $repoJson = "[]"
} elseif ($entryArray.Count -eq 1) {
    $repoJson = "[`r`n" + (ConvertTo-Json -InputObject $entryArray[0] -Depth 6) + "`r`n]"
} else {
    $repoJson = ConvertTo-Json -InputObject $entryArray -Depth 6
}

$writeRepoJson = $true
if (Test-Path -LiteralPath $repoJsonPath) {
    $existingJsonObject = Read-Utf8Text -Path $repoJsonPath | ConvertFrom-Json
    $generatedJsonObject = $repoJson | ConvertFrom-Json
    $existingCanonicalJson = ConvertTo-Json -InputObject $existingJsonObject -Depth 10 -Compress
    $generatedCanonicalJson = ConvertTo-Json -InputObject $generatedJsonObject -Depth 10 -Compress
    $writeRepoJson = $existingCanonicalJson -ne $generatedCanonicalJson
}

if ($writeRepoJson) {
    Write-Utf8Text -Path $repoJsonPath -Text $repoJson
    Write-Host "Updated repo index."
} else {
    Write-Host "Unchanged repo index."
}

Write-Host "Generated $repoJsonPath"
Write-Host "Included plugins: $($entries.InternalName -join ', ')"
