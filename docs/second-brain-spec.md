# Spec: an organizational second brain for AVD

- **Status:** Proposed (see [decision 0012](decisions/0012-second-brain.md))
- **Date:** 2026-10-04
- **Scope:** landing zones built from this repo (Entra ID-only, greenfield, private by default; [decision 0001](decisions/0001-cloud-native-scope.md))

This is a personal project, not for production, provided as is. The design below is a proposal; nothing in it has run against a real tenant yet.

## 1. Summary

The repo already learns, but only through people. A real run fails, someone pastes the output, Claude writes a lesson and a guard, and CI makes sure the failure can't come back ([decision 0006](decisions/0006-lessons-and-guards.md)). The deployment portal reads a machine-readable state line ([0007](decisions/0007-portal-state-line.md)). Operators send redacted problem reports ([0008](decisions/0008-portal-issue-reports.md)). The Well-Architected review compares the deployed estate with Azure's own evaluations ([0009](decisions/0009-well-architected-review.md)). A runbook acts on the budget ([0011](decisions/0011-auto-shutdown.md)).

The **second brain** runs that same loop all the time, against the running estate as well as the code:

```
 Sense ──► Remember ──► Reason ──► Act ──► Verify ──► Learn ──► Evolve
   ▲                                                              │
   └──────────────── guards, detections, playbooks ◄──────────────┘
```

- **Self-healing:** known failures are detected, diagnosed and fixed by **playbooks** that live in the repo and are tested offline. A playbook runs on its own only when its autonomy level allows it.
- **Self-learning:** every incident becomes an **episode** with its evidence, diagnosis, action and outcome. Patterns that repeat become lessons, guards, detections and playbooks, through the retro routine that exists today.
- **Self-evolving:** drift, sizing, cost and Well-Architected findings become **pull requests** against the IaC. CI validates them, they are tried in `test` first, and a person merges them.

The rule that holds it all together: **the LLM reasons and proposes. Deterministic, tested code acts. Git is the only place knowledge becomes policy.**

## 2. Goals and non-goals

### Goals

1. Detect AVD failures before users report them, and diagnose them with evidence (lesson 0012: report what the API returned before guessing).
2. Fix the known, reversible, low-blast-radius failures without a person, within hard limits.
3. Never pay twice for the same lesson. A repeated incident signature after a guard exists is a defect of the brain.
4. Keep the estate and its code in agreement: detect drift, then either codify it or revert it, by pull request.
5. Answer operators' questions ("why is host 3 draining?", "what changed before Monday's errors?") from the estate's own memory, with citations.
6. Keep every decision auditable: who or what acted, on what evidence, under which playbook version, with what result.

### Non-goals

- **No autonomous merge to `master` and no autonomous production deployment.** The brain opens PRs; people merge them; the `prod` GitHub Environment keeps its required reviewers.
- **No changes to identity, Conditional Access or Intune policy.** They are the platform's job ([out-of-scope.md](out-of-scope.md)). The brain may observe and recommend.
- **No reading of user data.** Profile contents, session contents and user files are off limits. Metadata (connection records, FSLogix event IDs, share metrics) is in.
- **Not a replacement for Microsoft support.** Escalation is a playbook outcome. The open Entra Kerberos case in [rebuild-spec.md](rebuild-spec.md#known-open-issue) is exactly the kind of case it must hand over with evidence, not keep retrying.
- **No AD DS, hybrid or brownfield features.** Same scope as the landing zone.

## 3. Principles

Each comes from something this repo already learned.

| # | Principle | Source |
|---|---|---|
| P1 | Real runs are the source of truth. When an agent's diagnosis disagrees with a real outcome, the outcome wins and becomes an eval case. | decision 0006, lesson 0020 |
| P2 | Diagnose before acting. Every episode records the raw evidence (status, error code, body, headers) before any hypothesis. | lesson 0012 |
| P3 | Knowledge is code. A lesson without a guard is unfinished; a playbook without an offline scenario cannot run. | decision 0006 |
| P4 | REST over cmdlets, managed identities over secrets, PowerShell 5.1-compatible runbooks without modules. | decisions 0002, 0011 |
| P5 | Private by default. Every data store sits behind a private endpoint with public access off. | decision 0001 |
| P6 | Warnings are not failures. Advisory findings never block; only playbooks with a verified signature act. | decision 0009 |
| P7 | Fail safe. Missing data, a failed verification or an unknown signature means stop and ask, never "try something". | lessons 0008, 0012 |
| P8 | Tenant data stays in the tenant. Anything bound for GitHub passes the browser redaction rules (`report.js`) or a server-side port of them, with the same tests. | decision 0008 |
| P9 | Never make operators remember secrets, or carry state between sessions in their heads. | lesson 0002, 0015 |

## 4. Architecture

### 4.1 Overview

```
                          ┌─────────────────────────────── GitHub ───────────────────────────────┐
                          │ repo: IaC · lessons · decisions · detections · playbooks · evals     │
                          │ Actions: validate · deploy (OIDC) · brain-evolve · brain-eval        │
                          │ Issues/Projects: incident inbox · approvals · weekly digest          │
                          └──────▲──────────────────────────▲─────────────────────▲──────────────┘
                                 │ PRs (never merges)        │ index on push       │ issues (redacted)
┌──────────── Sense ─────────┐   │                          │                     │
│ Log Analytics (AVD Insights│   │   ┌──── Remember ────────┴───────┐   ┌──── Reason ─────────┴──────┐
│  WVD*, FSLogix, perf)      │   │   │ Azure AI Search (hybrid +    │   │ Microsoft Foundry Agent    │
│ Resource Graph + changes   ├───┼──►│  vector): repo docs, MS Learn│◄──┤  Service: triage, diagnose,│
│ Activity Log, Service      │   │   │  excerpts, episodes          │   │  retro, evolve, critic     │
│  Health, Advisor, Defender,│   │   │ Cosmos DB (NoSQL): episodes, │   │ Models: Claude or Azure    │
│  Policy, Cost Management   │   │   │  signals, playbook stats     │   │  OpenAI, via Foundry       │
│ Scheduled preflight state  │   │   │ Blob (immutable): evidence,  │   │ Tools via MCP: Azure MCP,  │
│  lines (Automation)        │   │   │  state lines, KQL results    │   │  GitHub MCP, AVD-LZ MCP    │
│ Graph: Intune compliance,  │   │   └──────────────────────────────┘   └─────────────┬──────────────┘
│  sign-in logs              │   │                                                    │ proposals
└────────────┬───────────────┘   │   ┌──── Act / Verify ──────────────────────────────▼──────────────┐
             │ alerts, events    │   │ Durable Functions (Flex Consumption): incident orchestrator    │
             └──────────────────►│   │ Azure Automation: playbook runbooks (PS 5.1, REST, MI token)   │
               Event Grid        └───┤ Guardrails: App Configuration (kill switch, levels, limits),   │
                                     │  Azure Policy, blast-radius checks, verification + rollback    │
                                     └────────────────────────────────────────────────────────────────┘
```

All new resources go into one new resource group, `rg-<prefix>-<env>-brain`, deployed by a new module `bicep/modules/brain.bicep`, opt-in through `AVD_BRAIN_ENABLED` (guarded with `empty(...)`, lesson 0004). A landing zone without it behaves exactly as today.

### 4.2 Sense

| Signal | Source | Transport | Notes |
|---|---|---|---|
| Connections, errors, checkpoints, agent health | Log Analytics: `WVDConnections`, `WVDErrors`, `WVDCheckpoints`, `WVDAgentHealthStatus`, `WVDConnectionNetworkData` | Scheduled query alerts → action group → Event Grid custom topic | Already collected by the AVD Insights DCR |
| FSLogix and host events | Log Analytics `Event` (FSLogix Apps operational log), `Perf` | Same | Extend the DCR with FSLogix event IDs |
| Resource state and changes | Azure Resource Graph, `resourcechanges` | Event Grid system topic (subscription) for writes; Resource Graph for "what changed before X" | Correlates incidents with changes |
| Platform health | Service Health, Resource Health | Activity Log alert → action group | First check of every connection incident |
| Posture | Advisor, Defender for Cloud, Policy compliance | Scheduled pull, REST | Same sources as `-WellArchitected` |
| Cost | Cost Management exports to Blob; budget alerts | Export + action group | Budget lock already exists (0011) |
| Landing zone health | Post-deployment preflight run on a schedule by Automation (`-SkipTenant -SkipNtfs`, plus `-WellArchitected` weekly) | State line `<<<AVDLZ-STATE ...>>>` written to Blob | Reuses the portal's contract unchanged |
| Device and identity | Microsoft Graph: Intune managed device compliance, Entra sign-in logs (diagnostic settings to Log Analytics) | Pull / diagnostic settings | Read-only |
| Code and CI | GitHub: workflow runs, PRs, `portal-report` issues | Webhook → Function, or GitHub Actions calling the brain | Portal reports enter as episodes, already redacted |

Every signal is normalized into a **Signal** (§6.1) with a **signature**: a stable hash of what failed, not when or where (for example `wvd-agent-unhealthy:upgrade-failed`, `fslogix-attach:0x00000005`). Signatures are how the brain recognizes "we've seen this before".

**Detections are code.** Each one is a KQL file with metadata in `brain/detections/` (§7). The Bicep module turns them into scheduled query rules, so a detection changes only by PR, and a template test checks that every detection compiles and names a playbook or `notify-only`.

### 4.3 Remember

Five kinds of memory, each with one home.

| Memory | Holds | Home | Written by |
|---|---|---|---|
| **Semantic** | Lessons, decisions, docs, gotchas, curated Microsoft Learn excerpts | Git (canonical) → indexed into Azure AI Search on push | People and PRs only |
| **Procedural** | Detections, playbooks, guards, evals | Git (`brain/`) | People and PRs only |
| **Episodic** | Incidents: signals, evidence, hypotheses, actions, outcomes | Cosmos DB for NoSQL (system of record) + AI Search (retrieval) | Orchestrator |
| **State** | What exists now and what changed | Resource Graph, Log Analytics (queried live, never copied) | Azure |
| **Statistical** | Baselines per host pool and hour of week; playbook success rates; signature frequency | Cosmos DB, refreshed daily | Learn job |

Why this split:

- **Git is the long-term memory and the only place policy lives.** It is reviewed, versioned and already wired to CI. An agent can propose to it but never write to it directly.
- **Cosmos DB holds the short-term, tenant-specific memory** that must not reach a public repo: resource names, UPNs, timings. Serverless capacity mode keeps idle cost near zero; its vector search could replace AI Search for small estates (open question Q3).
- **Azure AI Search** gives hybrid retrieval (keyword + vector + semantic ranker) across both, so "this looks like lesson 0011" and "this looks like episode from last Tuesday" come from one query. Every answer cites its sources.
- **Evidence is immutable.** Raw outputs go to Blob with a time-based immutability policy, and episodes reference them by hash. A diagnosis can always be re-checked against what was actually returned.

Retention: episodes 13 months (a year of seasonality plus one month), evidence 90 days unless pinned by a lesson, signals 30 days. Lifecycle management deletes the rest.

### 4.4 Reason

Agents run in **Microsoft Foundry Agent Service**, with the model chosen per agent. Claude models are available through Foundry, so one platform hosts both Claude and Azure OpenAI models. The repo already uses Claude Code for development; the `brain-evolve` and `brain-retro` workflows use Claude Code in GitHub Actions, so code changes go through the same path people use today.

| Agent | Trigger | Reads | Produces | Can act? |
|---|---|---|---|---|
| **Triage** | New signal | Signal, recent episodes with the same signature, Service Health | Episode opened or merged into an existing one; severity; known/unknown signature | No |
| **Diagnose** | Episode opened, unknown signature or playbook asks | Logs (KQL), Resource Graph changes, preflight state lines, AI Search over lessons and episodes | Ranked hypotheses, each with evidence links and a confidence; a proposed playbook or "escalate" | No |
| **Critic** | Before any Level 2+ action and before any PR | The proposal and its evidence | Approve, or reject with reason. A second model or prompt that argues against the proposal | No |
| **Retro** | Episode closed with a new signature, or a signature repeated ≥3 times in 30 days | Episode, evidence, `.claude/skills/retro/SKILL.md` | A draft PR: lesson + guard (+ detection, + playbook) | PR only |
| **Evolve** | Weekly, or on drift | Resource Graph vs. what-if, utilization baselines, cost, WAF findings | PRs: codify or revert drift, sizing (`AVD_SESSION_HOST_*`, `AVD_PROFILE_QUOTA_GIB`), new alerts, AVM version bumps | PR only |
| **Concierge** | Operator question (GitHub issue comment, Teams, portal) | Everything above, read-only | Answer with citations | No |

Agents reach tools through **MCP**, each with an allowlist:

- **Azure MCP Server**: read-only operations (Resource Graph, Log Analytics query, Monitor, Advisor).
- **GitHub MCP**: issues, comments, branches and PRs on the brain's repository only.
- **AVD-LZ MCP** (new, small, in this repo): wraps what already exists as typed tools: run the preflight and return its state line, the KQL catalog by name, `Invoke-AvdPowerAction -WhatIf`, the playbook catalog, and `propose_playbook_run(playbook, version, parameters)`. There is no tool that writes to Azure directly.

Everything an agent reads from logs, issues, comments or tool output is **untrusted data**. Prompts mark it as such; no instruction found in it can widen what the agent may do. The only way to act is `propose_playbook_run`, which the orchestrator validates against the playbook's schema and the guardrails (§4.5) before anything runs.

### 4.5 Act and verify

The orchestrator is a **Durable Functions** app (Flex Consumption, VNet-integrated, managed identity). One orchestration per episode, so every step is replayable and its history is the audit trail:

```
open episode → collect evidence → triage → (known signature? → playbook : diagnose)
  → guardrail check → [approval if level ≥ 3] → execute (Automation job)
  → verify (detection query + preflight) → success: close | failure: rollback → escalate
```

Playbooks run as **Azure Automation runbooks**, following decision 0011: Windows PowerShell 5.1, no modules, ARM REST with the managed identity's token, a state line at the end. The same script runs from Cloud Shell and in the offline harness.

**Autonomy levels.** Each playbook declares the highest level it may reach; the effective level is the lowest of the playbook's level, the environment's ceiling and the kill switch.

| Level | Meaning | Examples |
|---|---|---|
| 0 Observe | Record only | New unknown signature |
| 1 Recommend | Issue with diagnosis and the exact command (a self-contained Cloud Shell block, lesson 0015) | Storage near quota; Defender high-severity finding |
| 2 Auto, reversible | Runs without a person, inside limits; verify and roll back on failure | Restart the AVD agent on one host; drain, restart and undrain a host with no sessions; clear a stale lock older than its expiry |
| 3 Approve | Runs after a person approves (GitHub Environment `brain-approve`, or a Teams card) | Replace a session host; change scaling plan schedule; Resume after a budget Lock |
| 4 Change code | PR only | Sizing, new alerts, drift fixes, anything in Bicep |

**Guardrails**, enforced by the orchestrator before execution and again inside the runbook:

- **Kill switch:** an App Configuration flag per environment (`brain:enabled`, `brain:maxLevel`). Default for a new deployment: `maxLevel = 1`. Prod ceiling: 2.
- **Blast radius:** at most one host per host pool in remediation at a time, and never below `max(1, ceil(active sessions / max session limit))` available hosts. Never act on a host with active sessions at level 2.
- **Rate limits and circuit breaker:** at most N runs of a playbook per hour; three failed verifications of the same playbook in 24 hours demote it to level 1 automatically and open an issue.
- **Change windows:** level 2 runs only outside the scaling plan's peak hours unless the episode is severity 1.
- **Typed parameters only:** the playbook schema lists parameters and their sources (episode fields, never free text from a model).
- **Least privilege:** the executor identity has only the built-in roles its playbooks need (as in decision 0011), on the landing zone's resource groups. Agents' identities are Reader plus Log Analytics Reader. No identity can write role assignments, policy or Key Vault secrets.
- **Azure Policy stays the outer wall.** A playbook that would violate policy fails, and that failure is an episode, not a retry.

**Verification is mandatory.** Every playbook names the detection that must clear and the preflight checks that must pass. "Fixed" means verified (CLAUDE.md: "Fixed" means done), not "the command returned 200".

### 4.6 Learn

- **Close every episode with an outcome:** `resolved-auto`, `resolved-approved`, `resolved-manual`, `escalated`, `false-positive`, `no-action`. A person's fix outside the brain is recorded too: the Retro agent asks for it on the issue.
- **Repeat detection:** a signature seen again after a guard was merged is flagged `regression` and opens a high-priority issue. This is the brain's main quality metric.
- **From episode to guard:** the Retro agent drafts the PR the retro skill describes today: a lesson in `docs/lessons`, a guard (Pester, offline scenario, template test or preflight check), and, if it can act, a detection and a playbook with its scenario. The redacted evidence becomes a fixture (decision 0007).
- **Playbook statistics:** success rate, verification time, rollbacks. A playbook is **promoted** only by a PR a person approves, after at least 10 verified runs at its current level with no rollback. It is **demoted** automatically (fail safe).
- **Baselines:** daily recomputation of per-hour-of-week connection counts, error rates, logon duration and profile load time, so detections can use "unusual for Monday 9:00" rather than fixed thresholds.
- **Evals:** every closed episode, redacted, can become an eval case: input signals and evidence, expected signature, expected playbook or escalation. `brain-eval` runs the agents against the eval set on every PR that changes prompts, models, detections or playbooks, with tools served by the offline mock. A drop in accuracy fails CI.

### 4.7 Evolve

The Evolve agent proposes, CI checks, `test` proves, a person decides.

1. **Drift:** nightly what-if of the deployed parameter file against the subscription, plus Resource Graph changes not made by the deploy identity. Each drift becomes a PR that either codifies the change in Bicep or documents the revert command.
2. **Right-sizing:** from baselines, propose `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT` or `AVD_PROFILE_QUOTA_GIB` changes. Prices come from the retail price API with the matching rules of decision 0010 and lesson 0025; a size change on an existing landing zone is called out in the PR, never applied silently.
3. **Posture:** Well-Architected findings that are not `data.accepted` become PRs or issues, by pillar.
4. **Dependencies:** AVM module and API version bumps (Dependabot or Renovate), with what-if output attached by CI.
5. **Rollout:** a merged change deploys to `test` first (`test.bicepparam`, same subscription), the brain watches it for a soak period (default 24 hours) with the same detections, then the `deploy` workflow promotes to `prod` behind its required reviewers.

## 5. Services

### Azure (required)

| Service | Role | Why this one |
|---|---|---|
| Log Analytics, Azure Monitor (scheduled query rules, action groups, DCR) | Sense | Already deployed; AVD Insights tables live here |
| Event Grid (system and custom topics) | Signal bus | Push delivery to Functions with retries and dead-lettering |
| Azure Resource Graph | State and change history | Free, fast, cross-resource |
| Durable Functions (Flex Consumption) | Incident orchestration | Replayable state machine, VNet integration, scales to zero |
| Azure Automation | Playbook execution | Same runtime and pattern as decision 0011 |
| Cosmos DB for NoSQL (serverless) | Episodic and statistical memory | Schemaless episodes, change feed for indexing, private endpoint |
| Azure AI Search | Retrieval over repo knowledge and episodes | Hybrid + semantic ranking with citations |
| Blob Storage (immutable container) | Evidence, state lines, cost exports | Tamper-evident audit |
| Microsoft Foundry (Agent Service, models) | Reasoning | Hosts Claude and Azure OpenAI models, agent identities, tracing |
| App Configuration | Kill switch, autonomy levels, limits | Change without redeploy, audited |
| Key Vault | Only for anything that cannot use a managed identity (ideally nothing) | Existing pattern |
| Managed identities, Microsoft Entra Agent ID (where available) | One identity per agent and per executor | Least privilege, auditable per actor |
| Private endpoints and private DNS | All of the above | Decision 0001 |

### GitHub (required)

- **Repository** as the long-term memory: `brain/` (detections, playbooks, evals, prompts) beside the existing IaC, lessons and decisions.
- **Actions:** `validate.yml` gains the brain checks; new `brain-index.yml` (reindex on push), `brain-eval.yml`, `brain-evolve.yml` and `brain-retro.yml` (Claude Code in Actions, OIDC to Azure, read-only roles).
- **Issues and Projects** as the inbox: one issue per episode that needs a person, labeled `brain`, with a weekly digest issue. Approvals for level 3 use a GitHub Environment with required reviewers.
- **Org brain vs. public brain.** This public repo holds generic knowledge only. An organization runs the brain from a **private fork**, so issue bodies may contain more context; even there, issue text passes the redaction rules, and full detail stays in Cosmos DB and Blob, linked by episode ID.

### Additional services (optional, when needed)

| Service | When | Note |
|---|---|---|
| Anthropic API directly | If a model or feature isn't available in Foundry in the chosen region | Same prompts; data processing terms reviewed first |
| Microsoft Teams (Bot Service or Workflows) | Operators live in Teams rather than GitHub | Approvals as adaptive cards; GitHub stays the record |
| Azure Managed Grafana or Workbooks | Visual dashboards of episodes and baselines | Workbooks first: no extra cost |
| Microsoft Sentinel | Security signals are in scope for the organization | Listed as a next layer in [out-of-scope.md](out-of-scope.md) |
| PagerDuty or similar | On-call paging outside business hours | Action group webhook |

Cost is driven mainly by AI Search tier, model tokens and Cosmos DB request units. Following decision 0010, the deploy step prices the brain from the retail price API and reports the meters it matched; this spec does not guess numbers.

## 6. Contracts

### 6.1 Signal

```json
{
  "schema": "avdlz-signal/v1",
  "id": "sig-...",
  "time": "2026-10-04T08:12:03Z",
  "source": "detection:wvd-agent-unhealthy",
  "signature": "wvd-agent-unhealthy:upgrade-failed",
  "environment": "prod",
  "scope": { "hostPool": "...", "sessionHost": "..." },
  "severity": 2,
  "evidenceRef": "blob://evidence/sha256-...",
  "data": {}
}
```

### 6.2 Episode

```json
{
  "schema": "avdlz-episode/v1",
  "id": "ep-...",
  "signature": "wvd-agent-unhealthy:upgrade-failed",
  "status": "open | diagnosing | awaiting-approval | acting | verifying | closed",
  "signals": ["sig-..."],
  "evidence": [{ "kind": "kql | rest | state-line | github", "ref": "blob://...", "sha256": "..." }],
  "changesBefore": [{ "resourceId": "...", "changeTime": "...", "actor": "..." }],
  "hypotheses": [{ "text": "...", "confidence": 0.7, "citations": ["docs/lessons/0011-...", "ep-..."] }],
  "actions": [{ "playbook": "restart-avd-agent", "version": "git:<sha>", "level": 2,
                "parameters": {}, "approvedBy": null, "job": "...", "result": "succeeded" }],
  "verification": { "detection": "cleared", "preflight": "Ready" },
  "outcome": "resolved-auto",
  "lesson": null,
  "issue": "https://github.com/<org>/<repo>/issues/..."
}
```

### 6.3 Playbook

```yaml
# brain/playbooks/restart-avd-agent.yml
id: restart-avd-agent
version: 1
signatures: [wvd-agent-unhealthy:*]
maxLevel: 2
runbook: scripts/automation/Invoke-AvdPlaybook.ps1   # one runbook, one action per playbook, like 0011
action: RestartAgent
parameters:
  sessionHostId: { from: episode.scope.sessionHost }
preconditions:
  - noActiveSessions
  - hostPoolAvailableHostsAbove: 1
  - serviceHealthClear: AVD
verify:
  detection: wvd-agent-unhealthy
  within: PT15M
  preflight: [host-health]
rollback: none          # restarting the agent leaves nothing to undo; undrain is in the action
limits: { perHour: 3, perHostPerDay: 2 }
scenario: tests/offline/Playbooks.Scenario.ps1     # required; CI fails without it
lesson: null
```

### 6.4 State line

Unchanged: the scheduled preflight writes the same `<<<AVDLZ-STATE {json} AVDLZ-STATE>>>` line the portal reads. The brain adds `stage: playbook` for playbook runs. Any new field goes through `portal-core.js` and its tests (decision 0007).

## 7. Repository layout

```
brain/
  detections/        <id>.kql + <id>.yml (signature, severity, playbook or notify-only, owner)
  playbooks/         <id>.yml (schema §6.3)
  prompts/           one file per agent; versioned like code
  evals/             <case>/ signals.json, evidence/, expected.json (redacted)
  schemas/           signal, episode, playbook JSON Schemas
bicep/modules/brain.bicep
scripts/automation/Invoke-AvdPlaybook.ps1
scripts/brain/       Functions app (orchestrator) and the AVD-LZ MCP server
tests/offline/Playbooks.Scenario.ps1, Brain.Scenario.ps1
tests/brain/         schema tests, detection compile tests, eval runner
.github/workflows/   brain-index.yml, brain-eval.yml, brain-evolve.yml, brain-retro.yml
```

Template and CI guards to add with the first slice:

- every detection compiles against the Log Analytics schema and names a playbook or `notify-only`;
- every playbook validates against its schema, names an existing runbook action, has a scenario and a verification;
- every `AzMock.psm1` path a playbook calls exists (decision 0011's rule);
- no prompt file contains tenant data (the PII sample test from decision 0008, run over `brain/`);
- the new entry points carry the project notice (`tests/portal/disclaimer.test.mjs`).

## 8. First playbooks

Chosen because they are frequent in AVD estates, reversible, and verifiable from data the landing zone already collects.

| Playbook | Signature | Level | Action | Verify |
|---|---|---|---|---|
| `restart-avd-agent` | Agent health failing, host otherwise up | 2 | Restart the RDAgentBootLoader service via managed Run Command | Agent healthy within 15 min |
| `recycle-empty-host` | Host unavailable, no sessions | 2 | Drain, restart VM, undrain | Host available; connections succeed |
| `re-register-host` | Host not registered / token expired | 3 | New registration token (never stored), re-run `Register-AvdAgent` | Host appears available |
| `profile-share-headroom` | Share usage over 85% of quota | 1 → 4 | Issue now; PR raising `AVD_PROFILE_QUOTA_GIB` | Usage below threshold after deploy |
| `connection-errors-spike` | `WVDErrors` above baseline | 1 | Correlate with Service Health and recent changes; post diagnosis | n/a (diagnosis) |
| `fslogix-attach-failure` | FSLogix attach errors | 1 | Diagnosis with lesson 0011 and the open Kerberos case; escalate with evidence pack | n/a |
| `budget-lock-review` | Budget Lock active (0011) | 3 | Resume after approval | `power-locked` cleared |
| `drift-detected` | What-if or change not by deploy identity | 4 | PR: codify or revert | Next what-if clean |
| `quota-pressure` | vCPU quota near the limit (lesson 0013, 0024) | 1 | Issue with the request command | Preflight quota check passes |

## 9. Security and privacy

- **Data classification:** tenant identifiers, UPNs, resource names and IPs are confidential and stay in the tenant's stores. GitHub content passes redaction; public `brain/evals` cases are redacted fixtures only.
- **Prompt injection:** logs, issue text, PR comments and tool output are untrusted. Agents cannot act except through `propose_playbook_run`; the orchestrator checks schema, level and guardrails, and the Critic reviews level 2+ proposals.
- **Identities:** one per agent and one per executor; no shared credentials; no secrets in prompts; OIDC for GitHub Actions. Registration tokens and similar short-lived secrets are created inside the runbook and never returned.
- **Network:** all data stores private; the Functions app and AI Search use private endpoints and VNet integration in the brain's own subnet (a new `/27` in the spoke, or a peered management spoke in hub mode).
- **Audit:** every action has an episode, an Automation job, Activity Log entries under the executor's identity, and a GitHub comment. Foundry tracing keeps agent steps.
- **Model data handling:** the organization confirms the data processing terms of the chosen model deployment before enabling the Reason layer. Without it, Sense, Remember and level 0-1 playbooks still work, with diagnosis left to people.

## 10. Measures of success

| Measure | Target after phase 4 |
|---|---|
| Repeat incidents after a guard (regressions) | 0 per quarter |
| Mean time to detect (vs. user report) | Detected first in ≥ 80% of incidents |
| Mean time to resolve, known signatures | < 15 minutes |
| Share of incidents resolved at level 2 | ≥ 40% of known-signature incidents |
| Rollbacks and false-positive actions | < 2% of level 2 runs |
| Episodes closed with a recorded outcome | 100% |
| Eval accuracy (signature and playbook) | Reported per PR; no merge on a drop |
| New signatures turned into lesson + guard within 7 days | ≥ 90% |

## 11. Phases

Each phase ships on its own, is useful on its own, and is validated by a real run before the next starts.

| Phase | Delivers | Max level | Exit criterion |
|---|---|---|---|
| **0 (done)** | Lessons and guards, state line, portal reports, WAF review, budget runbook | — | — |
| **1 Sense and remember** | `brain.bicep` (Cosmos, Blob, AI Search, Event Grid, Functions), scheduled preflight, detection catalog, episodes, indexing of the repo, weekly digest issue | 0 | A real incident appears as an episode with its evidence and the changes before it |
| **2 Diagnose** | Triage and Diagnose agents, Concierge, AVD-LZ MCP, eval harness with offline mock | 1 | Diagnoses cite the right lesson or episode in ≥ 80% of eval cases |
| **3 Heal** | Orchestrator guardrails, `Invoke-AvdPlaybook.ps1`, first three level 2 playbooks, kill switch | 2 (dev), 1 (prod) | 10 verified runs per playbook in dev without rollback |
| **4 Learn** | Retro agent PRs, playbook statistics, promotion and demotion, baselines | 2 | A new signature reaches a merged lesson and guard without a person writing it |
| **5 Evolve** | Drift, right-sizing and posture PRs, test-then-prod rollout with soak | 4 (PR) | One drift and one sizing PR merged and deployed through test |

## 12. Risks

| Risk | Mitigation |
|---|---|
| An agent's confident wrong diagnosis triggers a harmful action | Signatures, not model judgment, select level 2 playbooks; Critic; preconditions; verification and rollback; demotion on failure |
| Alert storms flood episodes and token budgets | Triage merges by signature and scope; per-signature rate limits; token budget per day with a level-0 fallback |
| The brain itself fails silently | Heartbeat detection on the orchestrator and indexer; the scheduled preflight reports `brain-*` checks; the brain is watched by Azure Monitor, not by itself |
| Knowledge rot: lessons go stale as Azure changes | Each lesson gets a `last-verified` date; Retro flags lessons cited by failed playbooks; quarterly review issue |
| The mock is more permissive than Azure, so playbooks pass tests and fail for real | Lessons 0020 and 0021 apply; every real playbook failure updates `AzMock.psm1` |
| Cost creep | Serverless and consumption tiers; priced at deploy (decision 0010); the brain's resource group sits under the same budget and Lock |
| Tenant data leaks to GitHub | Redaction with tests; private fork for org brains; evidence stays in Blob |

## 13. Open questions

- **Q1** Model choice per agent: Claude through Foundry for diagnosis and code, a smaller model for triage? Decide with the phase 2 eval set, not up front.
- **Q2** Approval surface: GitHub Environments only, or Teams as well?
- **Q3** Retrieval: Azure AI Search, or Cosmos DB vector search alone for small estates?
- **Q4** One brain per landing zone, or one per organization over several landing zones (the episode schema allows `environment` and `scope` to span them)?
- **Q5** Microsoft Entra Agent ID availability and roles in the target tenants, versus plain user-assigned managed identities.
- **Q6** Image pipeline: host replacement (level 3) is far stronger with a golden image (listed in [out-of-scope.md](out-of-scope.md) as a next layer). Build it before or alongside phase 3?
