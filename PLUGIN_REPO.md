# Dalamud Custom Repo

This workspace can be turned into a custom Dalamud plugin repository, similar to `https://love.puni.sh/ment.json`.

## How it works

Dalamud custom repositories do not read your source code directly.

They read one public JSON file that contains an array of plugin entries. Each entry points to a downloadable `latest.zip` package for one plugin.

In practice, each plugin needs:

- a plugin manifest (`.json` or `.yaml`)
- a packaged `latest.zip`
- a public URL where that zip can be downloaded
- a public `repo.json` that lists all plugins

## What this workspace now provides

The script [tools/Build-DalamudRepo.ps1](D:\Dalamud.Updater\mod-source\tools\Build-DalamudRepo.ps1) scans sibling plugin projects and generates:

- `plugin-repo/repo.json`
- `plugin-repo/plugins/<InternalName>/latest.zip`

It also respects [repo-config.json](D:\Dalamud.Updater\mod-source\repo-config.json), which can exclude selected plugins from your custom repo when needed.

It currently supports:

- source manifests in `json`
- source manifests in `yaml`
- packaged plugin zips already present under a project `release/<InternalName>/latest.zip`
- packaged plugin zips already present under common `bin/Release/.../latest.zip` layouts

If a project does not have a packaged `latest.zip`, it is skipped on purpose so the repo does not advertise a plugin that cannot actually install/update.

## Current status in this workspace

- `ffxiv-characterstatus-refined` is already close to publishable because it has `release/CharacterPanelRefined/latest.zip`
- `WrathCombo` has a valid plugin manifest, but there is no packaged `latest.zip` checked into this workspace right now, so it will be skipped until you generate or publish that package

## Upstream Sync Strategy

If a plugin is already maintained in a well-known upstream custom repo and you want to keep following that upstream for frequent updates, do not publish the exact same `InternalName` from your own custom repo unless you intentionally want to override it.

In this workspace, `WrathCombo` follows a safer pattern:

- source code stays synced from upstream in your fork
- GitHub Actions builds a normal upstream-compatible package
- the workflow also derives a separate `WrathComboCN` package for your custom repo

That keeps upstream compatibility while avoiding Dalamud de-duplication conflicts with the upstream `WrathCombo`.

Use your custom repo mainly for:

- plugins that are not available in your existing upstream sources
- your own forks when you intentionally want to diverge
- CN/test/private variants that should coexist with upstream entries

## Generate the repo

Run this from the workspace root:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Build-DalamudRepo.ps1 -BaseUrl "https://raw.githubusercontent.com/<your-user>/<your-repo>/<your-branch>/plugin-repo"
```

Replace the `BaseUrl` with the real public base URL where the generated `plugin-repo` folder will be hosted.

After that, the in-game custom repository URL will be:

```text
https://raw.githubusercontent.com/<your-user>/<your-repo>/<your-branch>/plugin-repo/repo.json
```

## Recommended publishing flow

1. Build each plugin in `Release` so a fresh `latest.zip` exists.
2. Run `Build-DalamudRepo.ps1` with your public base URL.
3. Commit the generated `plugin-repo` folder to the hosting repository.
4. Add the final `repo.json` URL in Dalamud custom repositories.

## Important update rule

For Dalamud to detect updates reliably:

- the plugin `AssemblyVersion` must change
- `LastUpdate` must change
- the `latest.zip` contents must reflect the new build

The script derives `AssemblyVersion` from the plugin `.csproj` and `LastUpdate` from the zip file timestamp.
