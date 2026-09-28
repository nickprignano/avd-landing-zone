# Deployment portal

[`index.html`](index.html) is a static page (GitHub Pages: <https://nickprignano.github.io/avd-landing-zone/portal/>) that walks an operator through a deployment:

1. **Choose a region.** Latency measured from the browser; the closest region is selected.
2. **Pre-deployment preflight.**
3. **Deploy the landing zone.**
4. **Post-deployment setup.**
5. **Sign in** (and optionally the demo host pool).

At each step it gives a self-contained Cloud Shell block (clone or update the repo, move into it, run the command). The operator pastes the output back and the portal works out what happened and what to run next. It keeps progress and settings in the browser's local storage. **Pasted output is never sent anywhere**: the only network requests are the latency test's.

**Report a problem** opens a GitHub issue with the pasted output and the portal's analysis. [`report.js`](report.js) redacts it in the browser first (decision [0008](../decisions/0008-portal-issue-reports.md)). The reporter reviews it and submits it on GitHub.

The logic lives in [`portal-core.js`](portal-core.js), which runs in the browser and in Node, so it is tested against real Cloud Shell output: `node --test "tests/portal/*.test.mjs"` (CI job *Deployment portal tests*).

## The state line

Every script ends its run with one line the portal reads (anything around it is ignored; if a terminal copy breaks the line, the portal rejoins it):

```
<<<AVDLZ-STATE {"v":1,"stage":"predeploy","status":"notready",...} AVDLZ-STATE>>>
```

Written by `Write-AvdPortalState` (PowerShell scripts) and `portal_state` (`deploy.sh`).

| Field | Meaning |
|---|---|
| `v` | Schema version (1). |
| `stage` | `predeploy`, `deploy`, `postdeploy`, `demo` or `cleanup`. |
| `status` | `ready` / `notready` (preflight, demo, cleanup); `started` / `succeeded` / `failed` / `whatif` (`deploy.sh`). A deployment prints `started` before it begins, so output cut off by a disconnect still says what is running. |
| `fix` | Whether the run used `-Fix`. |
| `context` | What the next command needs: `parameterFile`, `location`, `usersGroup`, `adminsGroup`, `namePrefix`, `environment`, `deploymentName`, `storageAccount`, `testUserUpn`, `workspace`, `includeLandingZone`, `wellArchitected` (whichever apply). |
| `counts` | `pass`, `fail`, `warn`, `fixed`, `skip`. |
| `failures`, `warnings` | `{ id, area, check, detail, remediation, data }` for each. `id` is set where the portal needs to recognise the check: `quota` (data: `location`, `quotaName`, `limit`, `used`, `needed`), `hostpool-region` (`regions`), `lz-region` (`deployedIn`), `lz-missing` (`found`), `kv-softdeleted` (`vaults`), `registering`, and `waf-<check>` for the Well-Architected review (`pillar`, and `accepted` when the parameter file makes that trade-off on purpose). |

Add fields; don't rename or remove them without bumping `v` and keeping the old reading in `portal-core.js`.

## Issue reports

`report.js` builds the report and redacts it:

| Removed | Placeholder |
|---|---|
| Tokens, keys, SAS signatures, passwords, device codes | `<token>`, `<secret>`, `<device-code>` |
| Email addresses and UPNs (guests too), their domains, `*.onmicrosoft.com` tenant names | `<email-N>`, `<domain-N>`, `<tenant-N>` |
| Subscription names, storage account and key vault names | `<subscription-N>`, `<storage-N>`, `<vault-N>` |
| GUIDs, except the ones in `PUBLIC_IDS` (the same in every tenant) | `<id-N>` |
| Public IPv4 addresses (private ranges stay) | `<ip-N>` |
| The user name in `/home/...` and `C:\Users\...` | `<user-N>` |
| Name prefix, group names, test user and storage account from the settings or the state line; terms the reporter adds | `<name-N>`, `<custom-N>` |

The same value always gets the same placeholder. Reports carry `<!-- avdlz-portal-report v1 -->`, and `.github/workflows/portal-report.yml` labels them `portal-report`.

**Triage:** a report whose analysis is wrong is a fixture waiting to happen. The retro routine applies. Check the output for anything private the patterns missed, then save it to `tests/portal/fixtures/`.

## Changing it

- **A script's output or parameters change:** run the portal tests. One of them checks that every parameter the portal puts in a command exists in the script.
- **A real paste is analysed wrongly:** add it (redacted) to `tests/portal/fixtures/`, add a test, then fix `portal-core.js`. This is the retro routine (`.claude/skills/retro`).
- **A new kind of private value turns up in a report:** add it to `fixtures/pii-sample.txt` and to the `PRIVATE` list in `tests/portal/report.test.mjs`, then add the pattern to `report.js`. A new GUID in `bicep/` or `scripts/` must go into `PUBLIC_IDS`, and a test checks this.
- **A new known error:** add it to `ARM_ERRORS` (deployment errors) or `shellProblems` (errors before a script can report) in `portal-core.js`, with a fixture.
