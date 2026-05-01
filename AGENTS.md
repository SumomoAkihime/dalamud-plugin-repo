# Project Notes

## Known Pitfalls

- `ffxiv-characterstatus-refined` currently points `origin` to `https://github.com/Kouzukii/ffxiv-characterstatus-refined.git` instead of the maintainer's own GitHub namespace. Confirm or replace the remote before pushing.
- `ffxiv-characterstatus-refined` has an untracked `release/` directory that is not covered by its current `.gitignore`. Treat it as suspicious build output unless there is a clear reason to version it.
- Plugin manifest formats are inconsistent across sibling projects: `WrathCombo` uses `WrathCombo.json`, while `ffxiv-characterstatus-refined` uses `CharacterPanelRefined.yaml`. Any shared publishing/repository tooling must support both.
- `ffxiv-characterstatus-refined` already includes packaged release output (`release/CharacterPanelRefined/latest.zip`), but `WrathCombo` does not currently include equivalent plugin release artifacts or a plugin publish workflow in-repo. Do not assume every plugin here is ready to be listed in a live custom repo without an extra packaging step.
- After rebasing `WrathCombo` to newer upstream commits, `SMN_Helper.cs` can fail with `CS0104` because `AetherFlags` exists in both `Dalamud.Game.ClientState.JobGauge.Enums` and `FFXIVClientStructs.FFXIV.Client.Game.Gauge`. Prefer fully-qualified enum casts in that file to keep CI packaging green.
- `WrathCombo` upstream source repo version metadata may lag behind live published version (e.g., `.csproj` at `1.0.4.0` while `https://love.puni.sh/ment.json` publishes `1.0.4.1`). For CN variant versioning based on upstream release numbers, prefer the source repo index (`ment.json`) as version base instead of the packaged manifest alone.

## Dalamud Dev Environment

- Base references for future work:
  - `goatcorp/Dalamud`: framework and API
  - `goatcorp/DalamudPlugins`: legacy official plugin repo format (`plugin.json` + `latest.zip`)
  - `goatcorp/DalamudPluginsD17`: current official manifest repo (`manifest.toml` pointing at a source repository commit)
- The most relevant starter template is `goatcorp/SamplePlugin`, not `DalamudPlugins` itself. Follow its local dev flow unless a project intentionally uses a more advanced custom layout.
- Local machine state checked here: only `.NET SDK 8.0.419` is installed, and `DALAMUD_HOME` is not set.
- Several repos in this workspace target `.NET 10` / `net10.0-windows`, so local builds will fail until a .NET 10-capable SDK is installed.
- SamplePlugin prerequisites from goatcorp:
  - XIVLauncher, FFXIV, and Dalamud must be installed and run at least once.
  - If Dalamud is not in the default location, set `DALAMUD_HOME` explicitly.
  - For default local dev, add the built plugin DLL path in `/xlsettings` -> `Experimental` -> `Dev Plugin Locations`, then enable it from `/xlplugins` -> `Dev Tools`.
- For new or modern plugin projects, prefer the latest `Dalamud.NET.Sdk` in the `.csproj`.
- For advanced/manual packaging flows, `DalamudPackager` is still valid, but then manifest generation and zip contents must be checked carefully.

## Publish Rules

- `goatcorp/DalamudPluginsD17` is the current official submission target. It expects a `manifest.toml` that points to:
  - a public git repository
  - a fixed commit hash
  - the plugin `project_path`
  - owners / maintainers
- `goatcorp/DalamudPlugins` documents the older packaging model and is still useful as a compatibility reference:
  - plugin definition JSON
  - `latest.zip`
  - icon under `images/icon.png`
- Official and custom repos both rely on deterministic versions. Never use timestamp-based or ever-changing build-number versions for `AssemblyVersion`.
- When a custom repo or official repo manifest says one `AssemblyVersion` but the downloadable zip contains another, installs/updates may fail. Prefer reading the packaged plugin manifest from inside `latest.zip` when generating repository metadata.
- New official submissions should go to testing first (`testing/live` in D17, `testing` in the legacy repo flow) before moving to stable.
- Plugin icons should exist in `images/` and stay within the documented size range: minimum `64x64`, maximum `512x512`.
- When a plugin is already distributed from an upstream custom repo that the user still keeps enabled, avoid re-publishing the same `InternalName` from this custom repo unless the goal is to override upstream deliberately. Dalamud may de-duplicate or prefer one source, which makes frequent upstream-sync workflows confusing.
- For upstream-synced forks that still need a distinct listing in the custom repo, prefer a derived variant package with a different `InternalName` instead of overriding the upstream one. In this workspace, `WrathCombo` is published to the custom repo as `WrathComboCN` / `Wrath Combo CN`.
- The root repo now has `.github/workflows/sync-plugin-repo.yml`, which is the preferred refresh path for the hosted custom repo. It pulls source repositories from GitHub, downloads the latest successful `WrathComboCN-package` artifact, regenerates `plugin-repo`, and commits the result back to `dalamud-plugin-repo`.
