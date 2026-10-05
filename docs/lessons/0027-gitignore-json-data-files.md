# 0027. A repo-wide `*.json` ignore rule kept the image pipeline's data files out of git

- **Area:** CI
- **Found in / fixed by:** #37 (introduced) / #39 (fixed), found by CI after #37 and #38 merged

## What happened
After #37 merged, `validate` failed on master and on every later PR:

```
bicep/images/build.bicep(96,32) : Error BCP091: An error occurred reading file. Could not find file
'.../scripts/image/wdot/wdot.lock.json'.
ItemNotFoundException: Cannot find path '.../scripts/image/wdot/wdot.lock.json' because it does not exist.
```

17 Pester failures followed: `ImageScripts.Tests.ps1`, the *Golden image build* scenario and the template test that inlines the WDOT profile. Locally, in the session that wrote #37, everything passed.

## Why
`.gitignore` had `*.json` under "Bicep build output", with exceptions only for `.github/` and `bicepconfig.json`. The image pipeline added nine JSON data files that `build.bicep` loads at compile time: `wdot.lock.json`, `protected-services.json` and seven WDOT profile files. They existed on disk, so every local check passed. `git add` skipped them without a word. Only `profile/Autologgers.Json` reached the repo, because its upper-case extension doesn't match `*.json` on a case-sensitive file system.

## Fix
- `.gitignore` ignores JSON only where Bicep writes build output: `bicep/**/*.json` and `parameters/**/*.json`.
- The nine files were rebuilt, because no copy survived. Their source is WDOT `v1.1` (commit `f20d6b7748d01e6e6c55518e8a9496af2749ca41`), and the choices come from `scripts/image/wdot/README.md` and `docs/image-pipeline-spec.md` §5.5:
  - **The profile:** WDOT's `Configurations/Templates`, with `OptimizationState` set as the README's table says (Services 19 of 23, ScheduledTasks 26 of 29, DefaultUserSettings 53 of 60; categories that don't run left as WDOT ships them), and written as `json.dumps(indent=2)` plus a newline. That recipe reproduces the surviving `Autologgers.Json` byte for byte.
  - **The lock:** the SHA-256 of `Windows_Optimization.ps1` and each `Functions/*` file at that commit, taken from the git blobs. WDOT has no `.gitattributes` there, so GitHub's archive serves the same bytes. `profileSha256` comes from `Get-AvdWdotProfileHash`.
  - **The protected services:** the list in spec §5.5. "The Defender services" became `WinDefend`, `WdNisSvc`, `Sense`, `SecurityHealthService` and `mpssvc`.

## Guard
A template test (`tests/Template.Tests.ps1`, *Files the templates load are committed*) finds every `loadTextContent`, `loadJsonContent`, `loadFileAsBase64` and `loadYamlContent` path in `bicep/` and fails unless git tracks it. It runs in a local checkout too, so an ignored data file fails before the push, not after the merge. Run against the broken tree, it named all nine files.

## Rule
Ignore build output where it's written, never by extension across the repo. A file a template loads at compile time must be committed. If `git status` doesn't show a new data file, check `git check-ignore -v <file>`.
