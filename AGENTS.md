# Project Notes

## Known Pitfalls

- `ffxiv-characterstatus-refined` currently points `origin` to `https://github.com/Kouzukii/ffxiv-characterstatus-refined.git` instead of the maintainer's own GitHub namespace. Confirm or replace the remote before pushing.
- `ffxiv-characterstatus-refined` has an untracked `release/` directory that is not covered by its current `.gitignore`. Treat it as suspicious build output unless there is a clear reason to version it.
- Plugin manifest formats are inconsistent across sibling projects: `WrathCombo` uses `WrathCombo.json`, while `ffxiv-characterstatus-refined` uses `CharacterPanelRefined.yaml`. Any shared publishing/repository tooling must support both.
- `ffxiv-characterstatus-refined` already includes packaged release output (`release/CharacterPanelRefined/latest.zip`), but `WrathCombo` does not currently include equivalent plugin release artifacts or a plugin publish workflow in-repo. Do not assume every plugin here is ready to be listed in a live custom repo without an extra packaging step.
