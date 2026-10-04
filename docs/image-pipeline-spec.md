# Spec: golden image pipeline and host rotation

- **Status:** Proposed (see [decision 0013](decisions/0013-image-pipeline.md)); red-team findings open in [image-pipeline-redteam.md](image-pipeline-redteam.md)
- **Date:** 2026-10-04
- **Scope:** landing zones built from this repo. This is phase 0b of the [second brain spec](second-brain-spec.md), built before its phase 1 (Q6).

This is a personal project, not for production, provided as is. Nothing in this spec has run against a real tenant yet; §11 lists what to verify at build time.

## 1. Summary

Session hosts are built from the marketplace image today (`MicrosoftWindowsDesktop/office-365/win11-24h2-avd-m365`, `version: latest`). Two hosts deployed a week apart can therefore differ, and nobody can say which build a host runs. Replacing hosts is a manual procedure in [deploy.md](deploy.md#7-day-2-operations): a new `sessionHostNamePrefix`, drain, delete.

This spec adds:

1. **A golden image.** Azure Image Builder (AIB) builds it monthly from the marketplace image. It applies updates, the WDOT optimizations and a small set of generic customizations, validates the result inside the build VM, and publishes it as a version in an Azure Compute Gallery. Hosts don't update themselves; the image carries the patches (§5.6).
2. **A one-host QA pool in every landing zone.** It is a validation environment that gets AVD service and agent updates first, the canary for every new image, and the place for maintenance work (§6.2).
3. **Automated validation, then promotion by a person.** A new version is excluded from `latest` until it passes automated validation in `test`'s and then `prod`'s QA pools, with a 24-hour soak in each. Nobody has to run anything. A person then promotes it to a production pool, with the validation results and the QA users' real sign-ins in front of them.
4. **Host rotation.** A resumable script replaces hosts blue/green: it deploys new hosts from the promoted version, drains the old ones, waits for sessions to end, and removes the old VMs, their session host objects and their Entra ID and Intune device objects.

The rule that holds it together: **the image is generic, and the landing zone configures it.** Nothing tenant- or landing-zone-specific goes into the image: no share path, no registration token, no domain, no secrets. The same version serves dev, test, prod and any adopter. Per-landing-zone configuration stays in the managed Run Commands that already exist (`Configure-FSLogix`, `Register-AvdAgent`).

## 2. Goals and non-goals

### Goals

1. Every host's software is known: an image version traceable to a commit, a source image version and a build run.
2. A monthly image with current updates, built and validated without anyone at a keyboard, and promoted only by a person.
3. Hosts replaced without users losing work, from Cloud Shell, surviving a disconnect (lesson 0015).
4. The second brain's `replace-host` playbook and its detections can rely on a known image (second brain spec §8).

### Non-goals

- **App delivery.** App Attach, Intune apps and line-of-business installers stay a separate layer ([out-of-scope.md](out-of-scope.md)). The pipeline has an optional customization folder for adopters, empty by default.
- **Multi-region replication for DR.** The gallery replicates to the landing zone's region only.
- **Personal host pools** and **brownfield images.** Same scope as the landing zone (decision 0001).
- **Forced log-offs by default.** Rotation waits for users unless the operator opts in (§6.5).
- **A shared community image.** The project doesn't publish images. Each adopter builds their own in their own subscription (§10, Q4).

## 3. Principles

| # | Principle | Source |
|---|---|---|
| I1 | The image is generic; configuration is applied per landing zone at host creation | decision 0001 (no post-deployment scripts on the host: configuration stays declarative in the template) |
| I2 | Build and validate automatically; a person promotes to a production pool | second brain spec P10 |
| I3 | Every script that reaches a build VM or a host is pinned: the commit for authenticity, SHA-256 for integrity in transit | red-team H6 |
| I4 | Validate with positive evidence: Available hosts, passing health checks, and a real sign-in, not "the build succeeded" | red-team H5, M9 |
| I5 | Anything slow prints a line before it starts; a long wait is a resumable phase, not a blocked Cloud Shell | lessons 0006, 0015 |
| I6 | Test a region without availability zones | lessons 0001, 0021 |
| I7 | Host and build scripts run in Windows PowerShell 5.1 | lesson 0011 |

## 4. Architecture

```
┌──── rg-<prefix>-images (shared by every environment) ───────────────────────────────────────┐
│ Azure Compute Gallery  gal<prefix>                                                          │
│   image definition  win11-avd-m365  (Windows, Generalized, V2, TrustedLaunch, accel. net.)  │
│   versions  YYYY.MMDD.N  (tags: commit, source image version, run; excludeFromLatest)       │
│ User-assigned identity  id-<prefix>-aib  (custom roles: gallery write, subnet join)         │
│ Per-build image template  it-<prefix>-<version>  (created, run, logs saved, deleted)        │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ distribute (replica in the landing zone's region; ZRS where zones exist, else LRS)
┌───────┴────── build network: the build environment's spoke (default: dev) ──────────────────┐
│ snet-image-build  10.100.2.128/27  build VM, egress through the NAT Gateway or hub firewall │
│ snet-image-aci    10.100.2.160/27  AIB isolated build container (delegated to ACI)          │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
        │ version ID
┌───────▼────── each landing zone ────────────────────────────────────────────────────────────┐
│ AVD_SESSION_HOST_IMAGE_ID → sessionHosts.bicep imageReference { id }                        │
│ sessionHostGeneration a|b → host names <prefix10><gen>-NNN, rotated blue/green              │
│ Run Commands (unchanged): Configure-FSLogix → Register-AvdAgent                             │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.1 Resources

`bicep/images/main.bicep` is a new entry point at subscription scope, like `bicep/demo/main.bicep`, and carries the project notice (`tests/portal/disclaimer.test.mjs`). It deploys:

| Resource | Notes |
|---|---|
| `rg-<prefix>-images` | One per name prefix, shared by dev, test and prod, so every environment runs the same artifact |
| Azure Compute Gallery `gal<prefix>` | Gallery names allow letters, digits, underscores and periods: the prefix is normalized the way `sessionHostNamePrefix` is |
| Image definition `win11-avd-m365` | `osType: Windows`, `osState: Generalized`, `hyperVGeneration: V2`, features `SecurityType = TrustedLaunch` and `IsAcceleratedNetworkSupported = true`, because hosts are Trusted Launch with accelerated networking (`sessionHosts.bicep`). Publisher, offer and SKU: `avdlz`, `win11-avd-m365`, `24h2` |
| `id-<prefix>-aib` | User-assigned identity for AIB |
| Custom role "AVD LZ image distributor" | Read the gallery and the definition; write and read versions. Scoped to the images resource group |
| Custom role "AVD LZ image build network" | `virtualNetworks/read` and `subnets/join/action`. Scoped to the two build subnets |
| Contributor on the staging resource group | `rg-<prefix>-images-staging`, which AIB uses for the build VM, its disk and its logs. AIB requires this role there; nothing else lives in that group |

The two build subnets go into the **build environment's** spoke (`AVD_IMAGE_BUILD_ENVIRONMENT`, default `dev`). They are added by `network.bicep` when `deployImageBuildSubnets` is true. They reuse that spoke's egress, the NAT Gateway or the hub firewall, so the build VM has no public IP (decision 0001), and no second NAT Gateway is needed. In hub mode, the firewall must allow Windows Update, the Microsoft 365 CDN, Defender updates, `raw.githubusercontent.com` for the customizer scripts, and the AIB service endpoints.

### 4.2 Image versions

- **Name:** `YYYY.MMDD.N`, for example `2026.1004.1`. Gallery versions are three integers, and this keeps them sortable by date.
- **Tags on every version:**
  - `avdlz-commit`: the repo commit of the template and the scripts;
  - `avdlz-source-image`: the marketplace version AIB resolved from `latest`;
  - `avdlz-run`: the Actions run URL;
  - `avdlz-validation`: the automated validation stage, or the failed check (§6.3);
  - `avdlz-validated`: `false` until validation passes, then the date.
- **`excludeFromLatest: true`** at build. Promotion flips it, so nothing that asks for "latest" picks up an unvalidated build.
- **Replicas:** one replica in the landing zone's region. Storage is `Standard_ZRS` where the region has availability zones and `Standard_LRS` where it doesn't. A template test compiles both cases (lesson 0001).
- **Retention:** the last three validated versions plus anything newer. An `endOfLifeDate` six months out is set at build. `image-build.yml` deletes versions beyond retention, never one that a host still runs: it checks every landing zone's hosts first.

## 5. Build

### 5.1 Trigger

`.github/workflows/image-build.yml`:
- **Schedule:** monthly, about a week after Patch Tuesday, when updated marketplace images are usually out.

  The schedule is a daily cron on days 15–21, and the job exits unless it's Monday. In a cron expression where both day-of-month and day-of-week are restricted, either field matches, so `0 6 15-21 * 1` alone would run every day from the 15th to the 21st and every Monday.
- **`workflow_dispatch`** for out-of-band builds, such as a security fix.

The workflow uses OIDC to Azure through the `images` GitHub Environment. Its identity can deploy into the images resource group and run image templates there, and nothing else. Building doesn't change any landing zone: a new version is excluded from `latest`, and no host uses it until a person promotes it. So a scheduled build needs no approval.

### 5.2 Steps

1. **Resolve and print:** the source image version that `latest` resolves to, the commit, and the new version name. If the source version and the commit both match the newest existing version, stop: nothing changed.
2. **Hash the customizer scripts** at that commit (SHA-256).
3. **Deploy a per-build image template** (`bicep/images/build.bicep`). Templates are immutable, so each build gets its own, named after its version:
   - **source:** the platform image, at the version resolved in step 1;
   - **`vmProfile`:** the AIB default build VM size, OS disk 127 GB, `vnetConfig` with `subnetId` = `snet-image-build` and `containerInstanceSubnetId` = `snet-image-aci` (isolated build, no proxy VM);
   - **`customize`:** §5.3, each script by `scriptUri` at the commit with its `sha256Checksum`;
   - **`validate`:** §5.4, with `continueDistributeOnFailure: false`;
   - **`distribute`:** the gallery version from §4.2, with its tags;
   - **`buildTimeoutInMinutes`:** 240.
4. **Run it.** Print a line before starting (lesson 0006), then poll `lastRunStatus` with a capped loop that ends on error (lesson 0008).
5. **Save the logs.** Copy AIB's `customization.log` from the staging storage into the run's artifacts, whatever the result. On a failure, report the step, status, error code and log tail (lesson 0012).
6. **Delete the template.** Deleting it also removes its staging resources.
7. **Open an issue** with the version, the source image version, the build-time validation results. Automated validation then starts on its own (§6.3).

### 5.3 Customizations

Each customization is a Windows PowerShell 5.1 script in `scripts/image/`, covered by PSScriptAnalyzer like every other script. Defaults:

| Order | Customization | Why |
|---|---|---|
| 1 | Windows Update (AIB's `WindowsUpdate` customizer; security and critical updates, no previews, no drivers), then restart | The month's patches in the image, not at first boot |
| 2 | `Disable-StorageSense.ps1` | Storage Sense can delete files inside FSLogix profiles; Microsoft's AVD guidance turns it off |
| 3 | `Enable-TimeZoneRedirection.ps1` | Sessions use the client's time zone |
| 4 | `Disable-AutomaticUpdates.ps1`: Windows and Microsoft 365 Apps automatic updates off | The image is the source of patches (§5.6) |
| 5 | `Invoke-Wdot.ps1`: WDOT with the reviewed profile, then restart | VDI performance tuning (§5.5) |
| 6 | `Update-DefenderSignature.ps1` | Hosts start with current signatures |
| 7 | Adopter scripts from `scripts/image/custom/`, in name order; empty in this repo | Apps and settings that belong to the adopter |
| 8 | `Invoke-ImageCleanup.ps1`: DISM component cleanup, temp and update download folders | Smaller image, faster deployments |

Never in the image:
- the AVD agent and Boot Loader. `Register-AvdAgent` installs the current version at host creation, and it handles a preinstalled agent if an adopter adds one (Q1);
- FSLogix **configuration**. FSLogix itself ships in the marketplace image; `Configure-FSLogix` writes the share path per landing zone;
- domain or Entra ID joins, local accounts or passwords, registration tokens, tenant IDs;
- Appx package removal, unless opted in after a tested build (§5.5). Removing them for some users breaks sysprep.

AIB generalizes the VM (sysprep) after the last customizer, with its default deprovisioning command.

### 5.4 Build-time validation

`scripts/image/Test-GoldenImage.ps1` runs in the build VM as AIB's `validate` step. Any failure stops distribution. It checks:

- the OS build matches the expected release (24H2) and is at least the source image's build;
- FSLogix is installed (`frx.exe`), at or above a minimum version;
- Microsoft 365 Apps are installed with shared computer activation on;
- Storage Sense is off and time zone redirection is on;
- no AVD agent or Boot Loader is installed, unless the adopter opted in (Q1);
- no reboot is pending, and no update failed in this build;
- no local user account exists beyond the built-ins;
- Defender is enabled, with signatures less than 24 hours old;
- WDOT ran with the `avdlz` profile at the pinned version and reported success, and no protected service (§5.5) is Disabled;
- Windows and Microsoft 365 Apps automatic updates are off (§5.6).

It prints one `RESULT <check> <Pass|Fail> <detail>` line per check, the format of the offline scenarios, so the build issue can quote it.

### 5.5 WDOT optimizations

The pipeline runs the [Windows Desktop Optimization Tool](https://github.com/The-Virtual-Desktop-Team/Windows-Desktop-Optimization-Tool) (WDOT) on every build. WDOT is the Virtual Desktop Team's successor to VDOT, which gets no more updates. It tunes Windows for multi-session hosts: it removes or disables services, scheduled tasks and autologgers that a VDI host doesn't need, and sets default-user and network settings. All its settings are applied to the image once, never to running hosts.

**Pinned, not vendored.** WDOT is downloaded at build time, at a pinned release. `scripts/image/wdot/wdot.lock.json` records its version, the release archive URL and the archive's SHA-256. `Invoke-Wdot.ps1` refuses an archive whose hash differs. A newer release reaches the image only through a PR that updates the lock file, which is a guardrail-style change reviewed like any other. A monthly check in `image-build.yml` opens an issue when a newer release exists.

**Our profile, reviewed in Git.** WDOT reads a configuration profile: JSON files in which each item's `OptimizationState` is `Apply` or `Skip`. The profile was generated once with WDOT's `New-WVDConfigurationFiles.ps1` and is kept in `scripts/image/wdot/profile/`. Every change to it is a diff someone can read. `Invoke-Wdot.ps1` copies it into WDOT's `Configurations` folder as `avdlz`, then runs:

```
Windows_Optimization.ps1 -ConfigProfile avdlz -AcceptEULA -Optimizations Services,ScheduledTasks,DefaultUserSettings,LocalPolicy,Autologgers,NetworkOptimizations,DiskCleanup
```

It doesn't pass `-Restart`; an AIB restart customizer follows instead.

| Category | Default | Why |
|---|---|---|
| Services, ScheduledTasks, Autologgers | Apply, with the protected list below kept `Skip` | The bulk of the CPU, memory and logon-time savings |
| DefaultUserSettings, LocalPolicy, NetworkOptimizations, DiskCleanup | Apply | Generic, and every new FSLogix profile starts from the default user |
| WindowsMediaPlayer | Skip | Little gain, and some line-of-business apps still use it |
| AppxPackages | **Skip** | Removing Appx packages is the classic sysprep breaker: a package installed for a user but not provisioned for all users fails generalization. It becomes opt-in (`imageWdotAppx = true`) once one build has passed with it and a lesson is written |
| Advanced: Edge, RemoveLegacyIE, RemoveOneDrive | **Skip** | WDOT itself marks them aggressive. RemoveLegacyIE is irreversible, and OneDrive matters with FSLogix profiles |

**Protected items.** These must stay `Skip` in the profile, because the landing zone depends on them:
- `dmwappushservice`: Intune MDM push;
- `WinDefend` and the Defender services;
- `wuauserv` and `BITS`: Defender signature updates, the Intune management extension, and the agent download;
- `WSearch`: Start and Outlook search in multi-session;
- `W32Time`, `CryptSvc`, `Schedule`;
- `TermService`, `SessionEnv`, `UmRdpService`: the RDP stack.

A Pester test reads the profile and fails if any protected item is `Apply`. `Test-GoldenImage.ps1` confirms after the build that none of these services is Disabled. Two independent guards cover this, because a disabled `dmwappushservice` breaks Intune enrollment silently on every host.

**Order in the build:** Windows Update → restart → our settings (§5.3) → **WDOT** → restart → Defender signatures → adopter scripts → cleanup. WDOT runs after updates, so it tunes the patched system, and before the adopter's apps, so their own services aren't touched. The WDOT version and the profile's hash are tagged on the image version (`avdlz-wdot`).

### 5.6 Updates on hosts: off, by design

With a golden image, **hosts don't update themselves.** The image is the single source of truth for patches: Microsoft's golden image guidance turns automatic updates off, so hosts don't reboot unplanned and don't drift to different patch levels ([golden image](https://learn.microsoft.com/en-us/azure/virtual-desktop/set-up-golden-image)). Patches arrive monthly through a new image and a rotation (§6). This applies to every pool, including the QA pool (§6.2), which must mirror production to be useful.

| Update | On hosts | How |
|---|---|---|
| Windows Update (quality and feature) | **Off** | `Disable-AutomaticUpdates.ps1` sets the policy `NoAutoUpdate = 1`. The `wuauserv` service stays available for Defender and Intune |
| Microsoft 365 Apps | **Off** | Office update policy `enableautomaticupdates = 0`; the image carries the month's build |
| Defender signatures | **On** | Security content, not software: it doesn't reboot and doesn't change the patch level |
| AVD agent and side-by-side stack | **On, scheduled** | The AVD service always updates the agent. The host pool's scheduled agent updates choose the window, and the QA pool gets new agents first (§6.2) |

**Intune can override this.** Windows Update rings are the platform's job ([out-of-scope.md](out-of-scope.md)). If an update ring targets these devices, Intune's policy wins over the image's. The adopter excludes the AVD hosts' device group from update rings, or assigns them a ring with automatic updates off. The host readiness check reports the effective setting, from both the policy key and the Intune policy manager, as a warning when updates are on.

## 6. Promotion and rotation

### 6.1 Parameters

- **`AVD_SESSION_HOST_IMAGE_ID`:** the gallery image **version** resource ID. The parameter files read it with an `empty(...)` guard (lesson 0004).
  - When it's set, `sessionHostImage` becomes `{ id: <version id> }`.
  - When it's empty, the marketplace image stays the default, so a landing zone without the pipeline behaves exactly as today.
  - It is always a pinned version, never `latest` or a definition ID, so a redeploy never changes software silently (decision 0010's rule against silent changes).
- **`AVD_SESSION_HOST_GENERATION`:** `''`, `a` or `b`.
  - Empty keeps today's names (`take(<base>, 11)-NNN`), so existing hosts aren't replaced.
  - `a` or `b` gives `take(<base>, 10)<gen>-NNN`, still 15 characters at most.
  - A template test checks that the default leaves names unchanged and that each generation yields valid, distinct names.
- `deploy.sh` gains `--image-id` and `--generation`. The preflight gains `-SessionHostImageId`, which checks that the version exists, is replicated to the region, and has a Trusted Launch definition. The portal's commands carry both (decision 0007: `portal-core.js` and its tests change with them).
- **`AVD_QA_POOL`** (default on), **`AVD_QA_GROUP_ID`** (default: the AVD Admins group) and **`AVD_QA_SESSION_HOST_IMAGE_ID`** (default: the main pool's version). The QA pool can run a newer version than the main pool, and that's how a canary works (§6.3).
- GitHub's `deploy.yml` reads `vars.AVD_SESSION_HOST_IMAGE_ID` and `vars.AVD_QA_SESSION_HOST_IMAGE_ID` from the target environment. Promotion sets them (§6.4).

### 6.2 The QA pool: a one-host maintenance ring

Every landing zone gets a **QA pool**: a second pooled host pool with **one host**, built from the same image and size as production. It is the landing zone's maintenance ring, the place every change lands first:

- **AVD service and agent updates.** The QA pool is a **validation environment** (`validationEnvironment: true`), so the AVD service rolls out service and agent updates to it before the production pool ([validation environments](https://learn.microsoft.com/en-us/azure/virtual-desktop/terminology)).
  - Its scheduled agent update window is **Wednesday 02:00**, host local time, before production's Saturday 02:00 (`controlPlane.bicep`). A bad agent version shows up there first.
  - Today `validationEnvironment` is already on for dev and test pools but off in prod (`main.bicep`), so prod has no early warning. The QA pool gives prod one without making its main pool a validation pool.
- **New image versions.** Automated validation runs in each environment's QA pool (§6.3).
- **Maintenance work.** Admins test settings, apps and Run Commands on a host that matches production, without touching users.

| Setting | Value | Why |
|---|---|---|
| Resource group | `rg-<prefix>-<env>-qa`: the QA host pool, app group and host | Automated validation's identity reaches the QA pool and nothing else (§6.3) |
| Host pool | `vdpool-<prefix>-<env>-qa`, pooled, `validationEnvironment: true`, same RDP properties and session limit as production | Microsoft's guidance is that a validation environment should be as similar to production as possible |
| Host | 1, same size and image version as production; names `take(<base>, 9)q<gen>-NNN` | Mirrors production. It stays 15 characters at most and is distinct from production names |
| Updates | As §5.6: Windows and Microsoft 365 Apps automatic updates off, Defender signatures on, AVD agent on its earlier schedule | A QA host that patched itself would no longer test the image production runs |
| Users | A desktop app group in the **same workspace**, labeled "QA desktop", assigned to `AVD_QA_GROUP_ID`. When that's empty, the AVD Admins group | QA users see both desktops in the Windows App |
| Power | Start VM on Connect, and covered by the scheduled Stop (EX-0002). No scaling plan | One host, started when someone signs in |
| Quota and cost | One more host's vCPUs. The preflight's quota check and price lines count it (decision 0010; lessons 0013, 0024) | No surprise at deployment |
| Opt-out | `AVD_QA_POOL = false`, guarded with `empty(...)` | Default on in every environment |

**A validation pool only helps if people use it.** Microsoft recommends that a couple of users sign in every day. So:
- the post-deployment preflight warns (`qa-pool-unused`) when `WVDConnections` shows no completed sign-in to the QA pool in two business days;
- once the second brain is running, that becomes a level 1 detection (§7).

### 6.3 Automated validation (the default)

Validation runs by itself. Nobody has to start it or sit through it: every build that passes §5.4 goes through the QA pools automatically, and a person gets involved only to promote a version to a production pool (§6.4). `AVD_IMAGE_VALIDATION = manual` turns the automation off; then a person runs each stage with `workflow_dispatch`.

**How it runs.**
- `image-build.yml` hands a successful build to `image-validate.yml` as a reusable workflow (`workflow_call`), in the same trusted run.
- From then on, `image-validate.yml` runs **hourly** on a schedule and moves each version one stage forward.
- A version's progress is a tag on the gallery version (`avdlz-validation`: the stage, the environment, and the soak end time), the same resumable pattern as rotation (§6.5). No job has to stay alive through a 24-hour soak, and a missed hour costs nothing.

| Stage | What happens | Passes when |
|---|---|---|
| **1 `test` QA** | Rotate `test`'s QA pool to the version (§6.5, `-HostPool qa`) | The checks below all pass |
| **2 `test` soak** | 24 hours. The checks run hourly | Every hourly run passes and no detection fires for the QA pool |
| **3 `prod` QA** | Rotate `prod`'s QA pool to the version | The checks below all pass |
| **4 `prod` soak** | 24 hours. The checks run hourly. Organic sign-ins by QA users are collected | Every hourly run passes and no detection fires. The version is tagged `avdlz-validated=<date>` and `excludeFromLatest` is set to `false`. The build issue gets the promotion command |

**The checks.** They are positive evidence (I4), and none of them needs a user's credentials:
- **Landing zone:** the post-deployment preflight comes back **Ready**.
- **Host, from Azure:**
  - Available, accepting sessions, and every AVD session host health check passing;
  - running the expected image version;
  - its `Configure-FSLogix` and `Register-AvdAgent` run commands succeeded;
  - Entra ID joined and Intune enrolled.

  These are the sign-in readiness checks of `Deploy-AvdDemo.ps1`.
- **Host, from inside:** `scripts/ops/host/Test-SessionHostFunction.ps1` (Windows PowerShell 5.1) runs as a Run Command and checks:
  - the RDP side-by-side listener is up and the agent reports a recent heartbeat;
  - FSLogix is configured with this landing zone's share, which resolves to a private IP and answers on TCP 445;
  - Microsoft 365 Apps shared computer activation is on;
  - automatic updates are off (§5.6);
  - every service protected from WDOT (§5.5) is running or set to start;
  - the WDOT version and profile hash match the image's tags.

  It prints `RESULT` lines that the workflow quotes.
- **Posture:** open Defender for Cloud recommendations and guest configuration results for the QA host. These are warnings, not failures (decision 0009). They're listed for the person who promotes.

**What automation can't prove.** None of these checks signs in as a user. So a **real sign-in**, with its Entra Kerberos ticket and a mounted FSLogix profile, isn't covered. That's what QA users are for (§6.2):
- the soak collects **organic** sign-ins to the QA host from `WVDConnections`, and the FSLogix result from the host's event log;
- the promotion page shows how many completed sign-ins the version had, and whether profiles attached;
- a promotion with **no** organic sign-in is allowed, but the approver must acknowledge it, and the reason is recorded.

An optional synthetic sign-in can close the gap later (Q8).

**On failure.**
1. The version is tagged `avdlz-validation=failed:<stage>:<check>`, and it is never promoted.
2. The QA pool rotates back to the previous validated version **automatically**. The QA pool exists to fail safely, and a failed canary mustn't leave QA users on a broken host.
3. An issue opens with every check's output, the step, status and error code (lesson 0012), and the customization log.
4. The next scheduled build starts over from stage 1. Nothing is retried in place.

**Who can do what.** Automation reaches only the QA pools.
- Each QA pool lives in its own resource group, `rg-<prefix>-<env>-qa`, holding the QA host pool, its app group and its host.
- The `image-validate` identity, through OIDC and a GitHub Environment of the same name with no reviewers, has:
  - Contributor on the QA resource groups;
  - subnet join on the session host subnet;
  - Reader and Log Analytics Reader for the checks.
- It can't touch a production pool, the hosts resource group, Key Vault or the budget. Promoting to a production pool stays with `image-promote.yml` and a person.
- The QA host's break-glass password is random and isn't stored, like the demo host's. **VM > Reset password** recovers access.
- Because this automation changes the QA pools without approval of each run, it is registered as pre-approved exception **EX-0005** in the second brain spec (§4.5.1), next to EX-0001 and EX-0002.

### 6.4 Promotion

`image-promote.yml` (`workflow_dispatch`) takes the version and the target environment. It runs in that GitHub Environment, so `prod`'s required reviewers approve it, or in solo mode, the owner after the wait timer (second brain spec §9.3). It refuses a version without `avdlz-validated`, which means automated validation passed in both QA pools (§6.3). It shows the approver the checks, the posture warnings, and the organic sign-ins and profile attaches on the QA hosts. With no sign-in, it asks for an acknowledgment and records the reason. It sets the environment's `AVD_SESSION_HOST_IMAGE_ID` and opens the rotation of the main pool (§6.5).

Adopters without GitHub Actions run the same steps from Cloud Shell: the portal gives the commands.

### 6.5 Rotation

`scripts/ops/Invoke-AvdHostRotation.ps1` runs in PowerShell 7 in Cloud Shell, calls ARM and Graph REST (`Invoke-AvdArm`, `Invoke-AvdGraph`), and ends with a state line (`stage: rotation`). Rotation is **resumable**: its state lives in a tag on the host pool (`avdlz-rotation`: from and to generation, version, phase, deadline, who started it), the same pattern as decision 0011's Lock. Running it again continues from the recorded phase, so a Cloud Shell disconnect costs nothing.

| Phase | What it does | Ends when |
|---|---|---|
| **Check** | Refuses if the host pool is `power-locked` (EX-0001). Checks vCPU quota for the new hosts: surge needs room for `sessionHostCount` more, and deployed hosts already count as used (lessons 0013, 0024); when it's short, prints the quota request. Checks the version (§6.1) | All checks pass |
| **Deploy** | Deploys the landing zone with the other generation and the version. Existing hosts are untouched, because incremental deployment leaves VMs that aren't in the template | Every new host is Available, passes the AVD health checks, and its run commands succeeded |
| **Drain** | Sets the old hosts to drain mode (no new sessions), saving each host's previous drain state. Sends users a message saying the host is being replaced and to sign out when convenient. Sets the deadline (default 72 hours) | Immediately; prints how many sessions remain |
| **Wait** | Each run reports the remaining sessions on old hosts. With `-LogOffAtDeadline`, once the deadline passes it sends a final message and logs remaining sessions off 15 minutes later. Without it, it only reports | No sessions remain on old hosts |
| **Remove** | Deletes the old session host objects from the host pool, then the old VMs (their disks and NICs go with them, `deleteOption: Delete`). With a Graph sign-in, also their Entra ID and Intune device objects (shared with `Remove-AvdDemo.ps1` as `Remove-AvdHostDevice`; never `| Out-Null` on `Connect-MgGraph`, lesson 0007) | Nothing of the old generation remains; the tag is cleared |

Other rules:
- **The scaling plan keeps running.** It doesn't route new sessions to drained hosts, and it may deallocate empty old hosts early, which is harmless.
- **The break-glass password** (decision 0004) is new for the new hosts. Key Vault holds the latest password, as today.
- **Rollback:** before **Remove**, rotating back is the same script in reverse: undrain the old generation and drain the new one. After **Remove**, rolling back means rotating to the previous validated version (§4.2).
- **No surge capacity** (quota or cost): `-BatchSize` isn't in v1. The script stops at **Check** with the quota request, rather than shrinking capacity silently.

## 7. Second brain integration

- **`replace-host`** (second brain spec §8, level 2, never EX-0003) deploys a single host from the environment's promoted version into the current generation, then removes the unhealthy one. It uses the same helpers as rotation.
- **Detections (level 1):**
  - `image-age`: the promoted version is older than 45 days;
  - `image-mixed`: hosts in one host pool run different versions outside a rotation;
  - `rotation-stalled`: a rotation tag is older than its deadline plus 24 hours;
  - `qa-pool-unused`: no completed sign-in to the QA pool in two business days (§6.2);
  - `qa-ahead-errors`: the QA pool runs a newer AVD agent or image than production and its error rate is above baseline. That is the early warning the QA pool exists for, raised before production's agent window;
  - `host-auto-updates-on`: a host reports automatic updates on, usually an Intune update ring overriding the image (§5.6).
- **Evidence:** the Tier 1 job records each host's image version. Baselines are split by version, so a regression after a rotation shows up as "this started with `2026.1004.1`".
- **Not autonomous.** Builds run on a schedule because they change no landing zone. Promotion and rotation are started by a person, as the second brain's human-in-the-loop rule requires.

## 8. Security

- **No secrets in the image** (§5.3). The build VM has no public IP and no inbound access. Its egress goes through the landing zone's NAT Gateway or the hub firewall.
- **Pinned scripts (I3):** AIB downloads each customizer from the commit's raw URL and checks its SHA-256. A fork or a private copy sets `AVD_IMAGE_SCRIPTS_URI`, as `AVD_RUNBOOK_URI` works in decision 0011. The commit is the authenticity check, and the hash protects integrity in transit.
- **Least privilege:**
  - the AIB identity holds the two custom roles plus Contributor on the staging group only;
  - the build workflow's identity can only deploy and run templates in the images group;
  - the `image-validate` identity can change only the QA resource groups (§6.3);
  - promotion to a production pool needs the target environment's approval.
- **Traceability:** every version's tags name its commit, source image and run, and the run keeps the customization log.
- **Posture:** the QA host is covered by Defender for Cloud and guest configuration like any host. Findings on it are shown at promotion as warnings, not failures (decision 0009). A person decides, with the findings in front of them.
- **New GUIDs** (built-in role IDs, if any role is assigned by ID) go into `PUBLIC_IDS` (decision 0008).

## 9. Repository layout and guards

```
bicep/images/main.bicep          gallery, definition, identity, roles (entry point, carries the notice)
bicep/images/build.bicep         per-build image template
bicep/modules/network.bicep      + snet-image-build, snet-image-aci (deployImageBuildSubnets)
bicep/modules/sessionHosts.bicep + generation in names; imageReference by id
parameters/images.bicepparam     region, replica storage, retention, build environment
scripts/image/                   customizers and Test-GoldenImage.ps1 (Windows PowerShell 5.1)
scripts/image/custom/            adopter customizations (empty here)
scripts/image/wdot/              wdot.lock.json (version, URL, SHA-256) and profile/ (reviewed OptimizationState JSON)
bicep/modules/qaPool.bicep       QA resource group, host pool, app group in the workspace, one host
scripts/ops/host/Test-SessionHostFunction.ps1   in-host checks for automated validation (5.1)
scripts/ops/Invoke-AvdHostRotation.ps1
.github/workflows/               image-build.yml, image-validate.yml (workflow_call and hourly), image-promote.yml
tests/offline/HostRotation.Scenario.ps1, ImageBuild.Scenario.ps1
```

Guards, added with the first slice, following decision 0006:

| Guard | Catches |
|---|---|
| Template test: parameter files compiled with `AVD_SESSION_HOST_IMAGE_ID` unset, empty and set | The empty-string trap (lesson 0004); the marketplace default holding |
| Template test: names unchanged with the default generation; valid and distinct for `a` and `b`; at most 15 characters | Replacing existing hosts by accident; NetBIOS length |
| Template test: the definition is V2 with `TrustedLaunch` and accelerated networking; replica storage is ZRS in a zoned region and LRS in one without zones | Trusted Launch deployment failures; lesson 0001 |
| Template test: every customizer in the build template has a `sha256Checksum` | Unpinned scripts |
| Pester: the WDOT profile keeps every protected item `Skip`, AppxPackages and the advanced categories are off unless opted in, and the lock file has a SHA-256 | Silently broken Intune, Defender, search or RDP |
| Template test: the QA pool exists by default with `validationEnvironment: true`, one host, an earlier agent update window, and names distinct from production; it's absent with `AVD_QA_POOL=false`; the quota and price lines count its host | The maintenance ring's guarantees; decision 0010 |
| Offline scenario `ImageBuild`: a failed build reports the step, code and log tail; the poll loop ends on error | Lessons 0008, 0012 |
| Offline scenario `ImageValidation`: the four stages advance one per run; resume after a missed run; a failure at each stage rolls the QA pool back, tags the version and opens an issue; manual mode does nothing on its own | The state machine and its rollback |
| Template test: the `image-validate` identity's role assignments are scoped to the QA resource groups (plus subnet join and readers), never the hosts group or a production pool | Automation reaching production |
| Offline scenario `HostRotation`: each phase, resume after a disconnect at every phase, refusal while locked, a quota shortfall, `-LogOffAtDeadline` off and on, device cleanup without a Graph sign-in (a warning, not a failure) | Resumability and its edge cases. Mock paths added to `AzMock.psm1`, which omits empty properties like ARM does (lesson 0021) |
| Portal tests: `stage: rotation` and `image` state lines, and the commands with `--image-id` and `--generation` | Decision 0007 drift |
| PSScriptAnalyzer over `scripts/image/` in its 5.1-compatible settings | Lesson 0011 |
| Disclaimer test over the new entry points | The project notice |

## 10. Phases

| Step | Delivers | Exit criterion |
|---|---|---|
| **1 Gallery and build** | `bicep/images`, build subnets, `image-build.yml`, customizers including WDOT, `Test-GoldenImage.ps1` | A scheduled build produces a version with every validation `Pass`, in a region with zones and in one without |
| **2 Parameters and QA pool** | `AVD_SESSION_HOST_IMAGE_ID`, generations, the QA pool, `deploy.sh` flags, preflight check, portal | dev deploys from a gallery version, with a QA pool whose host reports automatic updates off; the default still deploys the marketplace image with unchanged production names |
| **3 Rotation** | `Invoke-AvdHostRotation.ps1`, device cleanup shared with `Remove-AvdDemo.ps1` | `test` rotates a → b → a, resumed after a deliberate disconnect, and a real sign-in lands on the new generation each time |
| **4 Automated validation and promotion** | `image-validate.yml`, `Test-SessionHostFunction.ps1`, `image-promote.yml` | A scheduled build validates through both QA pools with nobody running anything. One deliberately broken build fails, rolls the QA pool back and opens an issue. One good version is promoted by a person and rotated into `prod`'s main pool, with the post-deployment preflight Ready afterwards |

When step 4 passes, phase 0b is done, and the second brain's phase 1 can start.

## 11. Verify at build

Each of these is an assumption in the spec, to confirm against the docs and a real run before relying on it:

- AIB isolated builds with `containerInstanceSubnetId`: the subnet delegation and the network policies each subnet needs, and that no proxy VM or Private Link service is created.
- AIB builds for a Trusted Launch gallery definition from the `win11-24h2-avd-m365` source.
- The AIB PowerShell customizer's `sha256Checksum` field, and the `validate` phase's `continueDistributeOnFailure`.
- `Standard_ZRS` replica storage in the chosen regions.
- GitHub Actions cron semantics, where day-of-month and day-of-week combine as OR.
- Whether AIB source-image triggers could replace the schedule (Q2).
- WDOT at the pinned release: the parameter names, the profile layout, and which items its default profile applies. In particular, whether any protected item (§5.5) is `Apply` by default.
- That Defender signature updates keep working with `NoAutoUpdate = 1`, and the exact Microsoft 365 Apps update policy key.
- That decision 0011's runbook (EX-0002) finds the QA pool's host, which sits in a second host pool.
- How scheduled agent updates interact with a validation pool: whether the service still flights agents to it first inside its own window.
- The list of AVD session host health checks the ARM API returns, and that Contributor on the QA resource group plus subnet join is enough to register a host to the QA pool.

## 12. Open questions

- **Q1** Preinstall the AVD agent and Boot Loader in the image, for faster registration? Default **no**: `Register-AvdAgent` installs the current version, and it already handles a preinstalled agent if an adopter wants one.
- **Q2** Schedule or AIB source-image triggers? The schedule is the default until triggers are verified (§11).
- **Q3** When to move to the next Windows 11 release: a new image definition per release (`25h2`), run side by side through a canary.
- **Q4** Should the project publish a community gallery image for adopters? Recommended **no**: supply chain trust and cost would fall on one maintainer, and each adopter's own build is traceable to their own commit.
- **Q5** Should `-LogOffAtDeadline` be the default in `prod`? Recommended **no**: losing unsaved work is worse than a slower rotation.
- **Q6** Opt in to WDOT's AppxPackages removal once a build passes with it? Recommended **yes, after** one passing build and a lesson recording which packages it removed.
- **Q7** Keep the QA pool on by default in dev and test, whose main pools are already validation environments? Recommended **yes**: it's also each environment's image canary, and one host with Start VM on Connect and the nightly Stop costs little.
- **Q8** Add a **synthetic sign-in** to automated validation? It would need a dedicated test account and a Windows client signing in through the Windows App, with an MFA policy that suits automation. That puts a credential and a Conditional Access exception in the adopter's tenant. Third-party logon simulators exist ([eG Logon Simulator](https://www.eginnovations.com/blog/free-logon-simulator-for-avd-azure-virtual-desktop-now-available/)); Microsoft offers none. Recommended **not yet**: organic QA sign-ins come first, and this gets revisited after a few months of validation data.
