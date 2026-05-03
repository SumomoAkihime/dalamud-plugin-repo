param(
    [string]$RepoRoot = "F:\Dalamud.Updater\mod-source"
)

$resolvedRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
git -C $resolvedRoot config core.hooksPath .githooks
Write-Host "Enabled hooksPath=.githooks for $resolvedRoot"
