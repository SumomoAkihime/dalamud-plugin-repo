param(
    [Parameter(Mandatory = $true)]
    [string]$BaseUrl,

    [string]$SourceRoot = "",
    [string]$OutputRoot = "",
    [string]$ConfigPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($PSScriptRoot) {
    $ScriptRoot = $PSScriptRoot
} else {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    $SourceRoot = (Resolve-Path (Join-Path $ScriptRoot "..")).Path
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $SourceRoot "plugin-repo"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $SourceRoot "repo-config.json"
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

    [xml]$xml = Get-Content $CsprojPath
    $versionNode = $xml.SelectSingleNode("//Project/PropertyGroup/Version")
    if (-not $versionNode -or [string]::IsNullOrWhiteSpace($versionNode.InnerText)) {
        throw "Could not find <Version> in $CsprojPath"
    }

    return [string]$versionNode.InnerText
}

function Read-JsonManifest {
    param([string]$Path)
    return Get-Content $Path -Raw | ConvertFrom-Json
}

function Read-RepoConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        return [pscustomobject]@{
            excludedInternalNames = @()
        }
    }

    return Get-Content $Path -Raw | ConvertFrom-Json
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

        $reader = New-Object System.IO.StreamReader($entry.Open())
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

    foreach ($rawLine in Get-Content $Path) {
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
        [string]$OutputRoot
    )

    $manifestInfo = Get-ManifestMetadata -ProjectRoot $ProjectDir.FullName
    if (-not $manifestInfo) {
        return $null
    }

    $csproj = Get-ChildItem $ProjectDir.FullName -Recurse -File -Filter *.csproj |
        Where-Object { $_.BaseName -eq $_.Directory.Name } |
        Select-Object -First 1

    if (-not $csproj) {
        throw "Could not find matching .csproj under $($ProjectDir.FullName)"
    }

    $manifest = $manifestInfo.Data

    $internalName = if ($manifest.PSObject.Properties.Name -contains "InternalName") {
        [string]$manifest.InternalName
    } else {
        [string]([System.IO.Path]::GetFileNameWithoutExtension($manifestInfo.Path))
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
            $internalName = [string]$packageManifest.InternalName
        }
        $version = [string]$packageManifest.AssemblyVersion
    } else {
        $version = Read-CsprojVersion -CsprojPath $csproj.FullName
    }

    $outputPluginDir = Join-Path $OutputRoot "plugins\$internalName"
    New-Item -ItemType Directory -Path $outputPluginDir -Force | Out-Null
    Copy-Item $packagePath (Join-Path $outputPluginDir "latest.zip") -Force

    $downloadUrl = "{0}/plugins/{1}/latest.zip" -f $BaseUrl, $internalName
    $lastUpdate = ConvertTo-UnixTimestamp -Date (Get-Item $packagePath).LastWriteTimeUtc

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

New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
$pluginsOutputRoot = Join-Path $OutputRoot "plugins"
if (Test-Path $pluginsOutputRoot) {
    Remove-Item $pluginsOutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $pluginsOutputRoot -Force | Out-Null

$projectDirs = Get-ChildItem $SourceRoot -Directory |
    Where-Object { $_.Name -notin @("plugin-repo", "tools", ".git") }

$entries = @()
foreach ($projectDir in $projectDirs) {
    $entry = Get-ProjectEntry -ProjectDir $projectDir -BaseUrl $BaseUrl -OutputRoot $OutputRoot
    if ($entry) {
        if ($excludedInternalNames -contains $entry.InternalName) {
            Write-Host "Excluded plugin: $($entry.InternalName)"
            continue
        }
        $entries += $entry
    }
}

$repoJsonPath = Join-Path $OutputRoot "repo.json"
$entryArray = @($entries)
if ($entryArray.Count -eq 1) {
    $repoJson = "[`r`n" + (ConvertTo-Json -InputObject $entryArray[0] -Depth 6) + "`r`n]"
} else {
    $repoJson = ConvertTo-Json -InputObject $entryArray -Depth 6
}
Set-Content -Path $repoJsonPath -Value $repoJson -Encoding UTF8

Write-Host "Generated $repoJsonPath"
Write-Host "Included plugins: $($entries.InternalName -join ', ')"
