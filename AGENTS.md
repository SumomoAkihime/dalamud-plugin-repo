# Project Notes

## Known Pitfalls

- `ffxiv-characterstatus-refined` currently points `origin` to `https://github.com/Kouzukii/ffxiv-characterstatus-refined.git` instead of the maintainer's own GitHub namespace. Confirm or replace the remote before pushing.
- `ffxiv-characterstatus-refined` has an untracked `release/` directory that is not covered by its current `.gitignore`. Treat it as suspicious build output unless there is a clear reason to version it.
- Plugin manifest formats are inconsistent across sibling projects: `WrathCombo` uses `WrathCombo.json`, while `ffxiv-characterstatus-refined` uses `CharacterPanelRefined.yaml`. Any shared publishing/repository tooling must support both.
- `ffxiv-characterstatus-refined` already includes packaged release output (`release/CharacterPanelRefined/latest.zip`), but `WrathCombo` does not currently include equivalent plugin release artifacts or a plugin publish workflow in-repo. Do not assume every plugin here is ready to be listed in a live custom repo without an extra packaging step.
- After rebasing `WrathCombo` to newer upstream commits, `SMN_Helper.cs` can fail with `CS0104` because `AetherFlags` exists in both `Dalamud.Game.ClientState.JobGauge.Enums` and `FFXIVClientStructs.FFXIV.Client.Game.Gauge`. Prefer fully-qualified enum casts in that file to keep CI packaging green.
- `WrathCombo` upstream source repo version metadata may lag behind live published version (e.g., `.csproj` at `1.0.4.0` while `https://love.puni.sh/ment.json` publishes `1.0.4.1`). For CN variant versioning based on upstream release numbers, prefer the source repo index (`ment.json`) as version base instead of the packaged manifest alone.
- Avoid 5-part CN AssemblyVersion strings like `1.0.4.1.n`; Dalamud/.NET version comparison is safer with exactly 4 parts. Use derived 4-part form `a.b.c.(d*1000+n)` (for example upstream `1.0.4.1` + CN `12` -> `1.0.4.1012`).
- In this workspace, invoking `rg.exe` can fail with `Access is denied` even when PowerShell commands work normally. If fast file search unexpectedly fails, fall back to `Get-ChildItem` + `Select-String` instead of assuming missing files.
- `ffxiv_bossmod` hardcoded `Service.LuminaSheet<T>()` to `Lumina.Data.Language.English`; on CN/other non-English environments this can return null sheets and crash plugin init (e.g. `ActionDefinitions.RegisterSpell` NRE during startup). Prefer English-first with fallback to default/client language sheet.
- The root `sync-plugin-repo.yml` workflow fully regenerates `plugin-repo/repo.json` from repositories cloned into `_sources`. If a plugin source repo is not cloned there (or has no built `latest.zip`), that plugin will disappear from the published custom repo on the next sync even if it was manually committed before.
- During cross-repo module merge, some Dawntrail filenames can appear with mojibake in terminal output (for example `Tr?umerei` instead of `Träumerei`) due to console encoding. Use `-LiteralPath` and avoid renaming based on garbled output; verify real file names directly in filesystem before patching.
- `ffxiv_bossmod/BossMod/BossMod.json` can become invalid JSON after encoding-corrupted manual edits (mojibake + missing quote in `Description`). If `Build-DalamudRepo.ps1` fails at `ConvertFrom-Json`, validate this manifest first before troubleshooting build scripts.
- `BossmodReborn` Dawntrail module code currently targets a newer BossMod framework API surface than this fork (for example changed `GenericAOEs.ActiveAOEs` signatures, missing component classes, and enum/category members). Do not bulk-copy Reborn `Modules` into this fork unless framework/API compatibility is aligned first; otherwise compilation fails with hundreds of errors.
- Even when narrowing to seemingly isolated `Dawntrail/Alliance` trash modules (for example `A10Trash`, `A20Trash`), there are still broad helper/API mismatches (`PolygonCustom`, arena helpers, state helper methods, additional component abstractions). Treat these as framework-port tasks, not data-only merges.
- In this fork's geometry API, `RelPolygonWithHoles` / `AddHole` expect concrete `List<WDir>` inputs; passing `CurveApprox.*` enumerables directly can fail to compile. Convert with `.ToList()` when constructing custom AOE polygons.
- `tools/Build-DalamudRepo.ps1` prefers source-side packaged artifacts in `ffxiv_bossmod/release/BossMod/latest.zip` over `plugin-repo/plugins/BossMod/latest.zip`; if that release zip is stale, `repo.json` will keep the old `AssemblyVersion` even after copying a newer plugin zip into `plugin-repo`. Always refresh `ffxiv_bossmod/release/BossMod/latest.zip` from the latest build before regenerating `repo.json`.
- `tools/Build-DalamudRepo.ps1` now requires explicit `-BaseUrl`; running it without that mandatory parameter fails immediately. Reuse the workflow value: `https://raw.githubusercontent.com/SumomoAkihime/dalamud-plugin-repo/master/plugin-repo`.
- Reborn merge conflict resolution can occasionally leave C# files with embedded NUL (`0x00`) bytes (seen in `M07SBruteAbombinatorConfig.cs`), causing garbled display and unreliable diffs. If syntax suddenly looks blank/corrupt, inspect raw bytes and rewrite the file as clean UTF-8 text before building.
- In this workspace, pushing `ffxiv_bossmod` can succeed on GitHub while local tracking ref update fails with `update_ref failed ... refs/remotes/origin/master ... reference broken`. Treat this as local ref corruption (not remote push failure) and verify by checking remote commit presence, then refresh local remote refs as needed.
- `ffxiv_bossmod/EX_MISSING_AFTER_PHASE4.txt` can over-report missing files because several mechanics were already implemented under different filenames/classes in this fork. Before porting from Reborn, normalize the list by checking both file existence and equivalent class/mechanic coverage; otherwise you may attempt duplicate ports and hit unnecessary compile conflicts.

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
- When searching version strings with PowerShell Get-ChildItem -Recurse | Select-String, unfiltered scans can hit in/ binaries and dump huge garbled output; restrict to source files (for example *.csproj, *.json, *.cs) to avoid misleading noise and terminal slowdowns.
- Root repo now includes .githooks/pre-push to block accidental multi-plugin payload pushes; this guardrail only works after setting core.hooksPath=.githooks (run 	ools/Enable-RepoIsolation.ps1 once per clone).
- Do not run Copy-Item ... latest.zip and 	ools/Build-DalamudRepo.ps1 in parallel: Build-DalamudRepo.ps1 can fail with file-lock IO exception on fxiv_bossmod/release/BossMod/latest.zip. Run these steps sequentially.
