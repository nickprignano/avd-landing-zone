# Spec: an organizational second brain for AVD

- **Status:** Proposed (see [decision 0012](decisions/0012-second-brain.md)); red-team findings open in [second-brain-redteam.md](second-brain-redteam.md)
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

- **Self-healing, with a person in the loop:** known failures are detected and diagnosed, and the brain prepares the fix as a **plan** from a **playbook** that lives in the repo and is tested offline. **By default, nothing runs until a person approves that exact plan.** The exception is the self-healing playbooks people list in exception EX-0003 (§4.5.1). Each one runs without approving each run, but only after it has earned a record of approved, verified runs.
- **Self-learning:** every incident becomes an **episode** with its evidence, diagnosis, action and outcome. Patterns that repeat become lessons, guards, detections and playbooks, through the retro routine that exists today.
- **Self-evolving:** drift, sizing, cost and Well-Architected findings become **pull requests** against the IaC. CI validates them, they are tried in `test` first, and a person merges them.

The rules that hold it all together: **the LLM reasons and proposes. A person approves every change the brain makes before it is made, except the few pre-approved exceptions people write down in Git. Deterministic, tested code makes it. Git is the only place knowledge becomes policy.**

## 2. Goals and non-goals

### Goals

1. Detect AVD failures before users report them, and diagnose them with evidence (lesson 0012: report what the API returned before guessing).
2. Turn known failures into a ready-to-approve plan, so that a person decides in under a minute and the fix runs and verifies itself after approval. Once a playbook has proven itself, it heals on its own under EX-0003, inside the same guardrails.
3. Never pay twice for the same lesson. A repeated incident signature after a guard exists is a defect of the brain.
4. Keep the estate and its code in agreement: detect drift, then either codify it or revert it, by pull request.
5. Answer operators' questions ("why is host 3 draining?", "what changed before Monday's errors?") from the estate's own memory, with citations.
6. Keep every decision auditable: who or what acted, on what evidence, under which playbook version, with what result.

### Non-goals

- **No change without a person.** The brain never writes to Azure, merges, deploys or changes its own configuration without a person first approving that exact change (§4.5). There is no autonomous mode and no "approve all similar". The only changes without approval of each run are **pre-approved exceptions** that people write, date and own in Git (§4.5.1), such as the budget Lock.
- **No autonomous merge to `master` and no autonomous deployment, in any environment.** The brain opens PRs; people merge them; the `prod` GitHub Environment keeps its required reviewers.
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
| P10 | A person approves every change the brain makes before it is made: one approval, one exact plan, one run. Pre-approved exceptions are written, dated and owned by people in Git, with deterministic triggers. Enforced by Azure (no token without an approval or an exception), not only by process. | Owner requirement, 2026-10-04 |

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
             └──────────────────►│   │ Approval gate: a person approves each exact plan (GitHub Env.) │
               Event Grid        └───┤ Executor: Actions job, Azure token only after that approval    │
                                     │ Guardrails: kill switch, Policy, blast radius, verification    │
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
| Code and CI | GitHub: workflow runs and PRs in the brain's private repository | Webhook → Function | Public `portal-report` issues are **not** signals (§9.1) |

Every signal is normalized into a **Signal** (§6.1) with a **signature**: a stable hash of what failed, not when or where (for example `wvd-agent-unhealthy:upgrade-failed`, `fslogix-attach:0x00000005`). Signatures are how the brain recognizes "we've seen this before".

**Only detections assign signatures (red-team C1).** A signature comes from the detection that fired: from its metadata, or from a deterministic function of the columns the detection returns. Nothing else assigns one.
- An episode's signature is set once, when it opens, and can't change. The orchestrator rejects any write that would change it.
- Merging signals into an episode is a pure function: the same signature, the same scope, inside a time window.
- An agent can add a **hypothesis** ("this looks like `fslogix-attach:0x00000005`"), lower an episode's level, or ask for a person. It can never set or change the signature.
- Playbooks are selected only by signature. When Diagnose suggests a playbook for an episode with an unknown signature, the plan is marked `agent-classified`. It always needs approval of each run, it is never eligible for EX-0003, and the approver sees that the brain guessed the match.

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
| **Triage** | New signal | Signal, recent episodes with the same signature, Service Health | Severity and a summary of an episode the orchestrator opened or merged deterministically; may lower the level or ask for a person, never set the signature | No |
| **Diagnose** | Episode opened, unknown signature or playbook asks | Logs (KQL), Resource Graph changes, preflight state lines, AI Search over lessons and episodes | Ranked hypotheses, each with evidence links and a confidence; a proposed playbook or "escalate" | No |
| **Critic** | Before any plan goes to a person, and before any PR | The proposal and its evidence | Agreement, or a dissent shown to the approver beside the plan. A second model or prompt that argues against the proposal | No |
| **Retro** | Episode closed with a new signature, or a signature repeated ≥3 times in 30 days | Episode, evidence, `.claude/skills/retro/SKILL.md` | A draft PR: lesson + guard (+ detection, + playbook) | PR only |
| **Evolve** | Weekly, or on drift | Resource Graph vs. what-if, utilization baselines, cost, WAF findings | PRs: codify or revert drift, sizing (`AVD_SESSION_HOST_*`, `AVD_PROFILE_QUOTA_GIB`), new alerts, AVM version bumps | PR only |
| **Concierge** | Operator question (GitHub issue comment, Teams, portal) | Everything above, read-only | Answer with citations | No |

Agents reach tools through **MCP**, each with an allowlist:

- **Azure MCP Server**: read-only operations (Resource Graph, Log Analytics query, Monitor, Advisor).
- **GitHub MCP**: issues, comments, branches and PRs on the brain's repository only.
- **AVD-LZ MCP** (new, small, in this repo): wraps what already exists as typed tools: run the preflight and return its state line, the KQL catalog by name, `Invoke-AvdPowerAction -WhatIf`, the playbook catalog, and `propose_playbook_run(episodeId, playbookId)` (the orchestrator binds parameters from the episode; the agent supplies none). There is no tool that writes to Azure directly.

Everything an agent reads from logs, issues, comments or tool output is **untrusted data**. Prompts mark it as such; no instruction found in it can widen what the agent may do. The only way to act is `propose_playbook_run`, which produces a plan for a person to approve (§4.5). The proposal alone changes nothing.

### 4.5 Act and verify: a person approves every change

**The rule:** the brain never makes a change until a person has approved that exact change.

- **A change** is any write: to Azure (control plane, data plane, Run Command, tags, power state, drain mode), to the default branch, to a deployment, or to the brain's own configuration and guardrails.
- **Not a change:** reading, writing the brain's own memory (episodes, evidence), and opening issues, comments or draft PRs in the private repo. Those are proposals.

The orchestrator is a **Durable Functions** app (Flex Consumption, VNet-integrated, managed identity). It runs one orchestration per episode:

```
open episode → collect evidence → triage → (known signature? → playbook : diagnose)
  → build plan → Critic → guardrail check → request approval
  → person approves the exact plan (or rejects it, or it expires)
  → executor re-checks the plan → run → verify (positive evidence)
  → success: close | failure: the plan's approved rollback → escalate
```

**The plan is what a person approves.** It holds:
- the playbook's ID and content hash;
- the targets, as resource IDs the orchestrator resolved through Resource Graph and checked against the landing zone's resource groups;
- the parameters, bound from the episode, never from a model;
- each precondition as observed, with its timestamp;
- the expected effect and blast radius;
- the verification;
- the rollback steps;
- a summary of the evidence, with the Critic's dissent if it has one;
- an expiry, 30 minutes by default.

The plan's hash is the SHA-256 of its canonical JSON.

**Approval rules**

- **One approval, one run.** There are no batch, time-window or "approve all similar" approvals. Standing approval exists only as a pre-approved exception (§4.5.1). A playbook's track record changes how its plan is presented, never whether it needs approval.
- **The approver is a person, and not the requester.** Approval uses a GitHub Environment per landing-zone environment (`brain-<env>`):
  - required reviewers come from an approvers team;
  - "Prevent self-review" is on;
  - the brain's own GitHub identity is not a reviewer.

  Prod and any plan that uses Run Command need two people: a second environment, `brain-<env>-second`, whose reviewer list shares no one with the first.
- **Approve or reject, never edit.** A changed plan is a new plan with a new hash and a new approval. Rejecting needs a one-line reason.
- **Silence is not approval.** An expired plan is rejected. The episode returns to the inbox with the Cloud Shell block for doing it by hand (lesson 0015). The brain never re-asks to pressure an approval.
- **The rollback is part of what's approved.** Approving a plan approves only the rollback steps it lists, and they run only if verification fails. Anything else needs a new approval.

**Enforced by Azure, not only by process.** The executor holds no standing credentials. It is a GitHub Actions workflow, `brain-execute.yml`, with two jobs, like plan and apply:

1. **`plan`** runs without an environment, under a read-only identity. It builds the plan and writes the plan and its hash to the job summary and to the episode's issue, so the approver reads exactly what will run.
2. **`apply`** runs in the `brain-<env>` environment. The executor's user-assigned managed identity has a federated credential whose subject is that environment (`repo:<org>/<repo>:environment:brain-<env>`). Azure therefore issues the executor a token only to a job a person has approved.

   Before acting, `apply` re-reads the targets and preconditions and rebuilds the plan. If the hash differs from the approved one, it stops and asks again. This closes the gap between approval and action.

Playbooks are actions in `scripts/automation/Invoke-AvdPlaybook.ps1`. Like decision 0011's runbook, it is Windows PowerShell 5.1-compatible, module-free and uses ARM REST, so an operator can run the same action from Cloud Shell and the offline harness can test it. It runs on the Actions runner against the public ARM endpoint. Its state line goes back to the orchestrator through the run's output, not through the private stores. No Automation account holds playbook rights, and Automation keeps only the budget runbook.

**Levels.** Each playbook declares the highest level it may reach. The effective level is the lowest of the playbook's level, the environment's ceiling and the kill switch.

| Level | Meaning | Examples |
|---|---|---|
| 0 Observe | Record only | New unknown signature |
| 1 Recommend | Issue with the diagnosis and a self-contained Cloud Shell block for a person to run (lesson 0015) | Storage near quota; Defender high-severity finding |
| 2 Approve and run | Plan → a person approves → the executor runs it → verify | Restart the AVD agent on one host; recycle an empty host; re-register a host; Resume after a budget Lock |
| 2S Self-heal (EX-0003) | Same plan and guardrails; the approval is the standing exception, and every run is reported | The playbooks listed in EX-0003, once they have met its entry criteria |
| 3 Change code | PR; a person merges; a person starts the deployment | Sizing, new alerts, drift fixes, anything in Bicep |

**Guardrails.** They hold even after an approval. The orchestrator checks them before it asks, and the executor checks them again before it acts.

- **Kill switch (EX-0004):** the levels and limits deploy from Git. The tag `avdlz-brain-killswitch` on the brain's resource group can only **lower** them (§4.5.1). If the tag can't be read, nothing runs. Default for a new deployment: `maxLevel = 1`.
- **Blast radius:** at most one host per host pool in remediation at a time. Availability never drops below current demand plus one host, or the scaling plan's minimum, whichever is higher.
- **Respect the other actors:**
  - never act on a host that is `power-locked` (decision 0011) or carries the scaling plan's exclusion tag;
  - a playbook restores the drain state it found;
  - session state that can't be read counts as occupied.
- **Rate limits and circuit breaker:** at most N plans per playbook per hour. Three failed verifications in 24 hours demote the playbook to level 1 and open an issue.
- **Change windows:** plans outside peak hours are preferred, and the approver sees when a plan falls inside them.
- **Least privilege:**
  - the executor has only the roles its playbooks need, on the landing zone's resource groups, and only through the approval environment;
  - agents' identities are Reader plus Log Analytics Reader;
  - no identity can write role assignments, policy or Key Vault secrets.
- **Azure Policy stays the outer wall.** A plan that would violate policy fails, and that failure is an episode, not a retry.

**Verification is mandatory and positive.** Every playbook names fresh evidence that must appear after the action, such as the session host's `Available` status with a `lastHeartBeat` later than the run. Missing data is a failed verification, not a cleared alert. "Fixed" means verified (CLAUDE.md: "Fixed" means done), not "the command returned 200".

### 4.5.1 Pre-approved exceptions

The approval rule covers the changes the second brain process originates. Some changes have to happen without waiting for a person, and the owner has said there will be more of them. Each one is a **pre-approved exception**: a standing approval that a person writes down once, for one narrowly defined action, in `brain/exceptions/` (schema §6.5).

There are three kinds:

- **External:** automation outside the brain that a person configured, such as decision 0011's budget Lock. The brain doesn't run it and never changes or suppresses it. It records each use as an episode and can propose the follow-up, such as Resume, as an ordinary plan for approval.
- **Standing:** a brain playbook allowed to run without approving each run.
- **Safety:** an action that can only take the brain's own capability away, never add it. The kill switch (EX-0004) is the only one. The kill switch can't stop it, and a failure pages the owner instead of suspending it.

**Rules for every exception**

1. **Only people create one.** People write and merge exceptions; CODEOWNERS on `brain/exceptions/` requires the approvers it names. A PR written by the brain that touches the folder fails CI (§9.2). The brain may only point out candidates in the weekly digest, such as "approved 20 of 20 times, never rejected".
2. **The trigger is deterministic:** a detection, a schedule or a budget threshold. It is never a model's output or an agent's judgment. No agent can invoke an exception.
3. **Narrow:**
   - one playbook action, or a fixed list of named playbooks, each with its own scope and limits (EX-0003); suspension applies per playbook;
   - named environments and resource groups;
   - parameters bound by the orchestrator;
   - limits on how many runs and how many hosts.
4. **Owned and dated:** each exception names its owner and approvers, the reason, and a review date. A standing exception has a review date at most 180 days out. An external one is reviewed with the deployment parameters that configure it. When the review date passes, a standing exception falls back to approving each run, automatically.
5. **Every use is on record:** the episode carries `approval.kind: standing`, with the exception ID and the commit that approved it. Each use is posted to the episode's issue and listed in the weekly digest.
6. **The guardrails still apply:** blast radius, preconditions and positive verification. A failed verification or a rollback **suspends** a standing exception, so it falls back to approving each run, and opens an issue. Re-enabling it is a PR a person merges.
7. **The kill switch (EX-0004) stops standing exceptions.** It does not stop external ones, which have their own controls (the budget's threshold and action), so turning the brain off never turns off a cost safety.
8. **Enforced by Azure:**
   - Each standing exception has its own executor identity, with a custom role limited to its action and scope.
   - That identity is federated to an environment (`brain-<env>-standing-<id>`) that only accepts the default branch. Its OIDC subject is customized to include the workflow file, so only `brain-standing.yml` on the default branch can get a token.
   - Before acting, the workflow checks that the exception file at that commit is unexpired and unsuspended.

**Registered exceptions**

| ID | Kind | Action | Trigger | Scope | Approved | Review |
|---|---|---|---|---|---|---|
| EX-0001 | External | Budget **Lock**: drain, scaling plan exclusion tag, Start VM on Connect off, deallocate (decision 0011) | Budget actual cost reaches `autoShutdownBudgetPercent` | The landing zone's hosts | Owner, 2026-10-04 | With the budget parameters |
| EX-0002 | External | Scheduled **Stop**: deallocate idle hosts (decision 0011) | The auto-shutdown schedule (`AVD_AUTO_SHUTDOWN_TIME`) | The landing zone's hosts | Owner, 2026-10-04 | With the schedule parameters |
| EX-0003 | Standing | **Self-healing**: the playbooks in the table below, each on one host at a time | Each playbook's own detection signature, computed by the detection, never by an agent | Per playbook | Owner, 2026-10-04 (as a category; each playbook enters by PR) | Every 180 days, and on any change to a listed playbook |
| EX-0004 | Safety | **Kill switch**: halt the brain's actions, or all of it; cut the executors' credentials | A person (one is enough), or the watchdog's deterministic triggers | The brain's own resource group and identities only | Owner, 2026-10-04 | Every 180 days, and after every real trip |

Resume after a Lock is **not** an exception. It stays an approved plan (`budget-lock-review`, §8).

**EX-0003 Self-healing**

The owner approved self-healing as a category. A playbook enters EX-0003 only by a PR a person merges, and only when it meets all of these:

- **Reversible and single-host:** it touches one session host and leaves nothing a restart can't undo. No identity, network, storage or control-plane changes.
- **Deterministic trigger:** one detection signature, computed by the detection (red-team C1). Episodes the Diagnose agent classified are not eligible.
- **Proven:** at least 10 approved, verified runs without a rollback in `test` (fault-injection drills allowed). For prod, at least 3 more approved, verified runs in prod, and the PR approved by two people.
- **Positive verification and a listed rollback**, as for every plan.
- **Tested:** an offline scenario covering success, failed verification and every precondition that blocks it.

| Playbook | Environments | Limits | Entry status |
|---|---|---|---|
| `restart-avd-agent` | dev, test, prod | 1 host per pool at a time; 3 per hour; 2 per host per day | Candidate: needs its run record |
| `recycle-empty-host` | dev, test, prod | 1 host per pool at a time; 2 per hour; 1 per host per day | Candidate: needs its run record |

Not eligible:
- `re-register-host`: it creates a registration token;
- anything that changes capacity, sizing, configuration or code;
- Resume after a Lock.

What still holds under EX-0003:
- every guardrail in §4.5: kill switch, blast radius, the other actors' locks and drain states, unknown counts as occupied, positive verification;
- the scope is checked with the plan rebuilt just before acting;
- each run is posted to its episode's issue as it happens, not only in the digest;
- a failed verification or a rollback suspends **that playbook** in EX-0003 and sends it back to approving each run, until a person re-enables it by PR.

Because no person approves each run, these red-team fixes become **required** before any playbook is active in EX-0003:
- C1: signatures come only from detections (§4.2), and the `brain-guard` check is in place (§9.2);
- H6: the Run Command script is fixed text, pinned by content hash, under a custom role scoped to the hosts resource group;
- M5: the first rollback suspends the playbook.

**EX-0004 Kill switch**

The kill switch stops the brain from changing anything, at once and from more than one place. Stopping it is a change the brain process can make by itself, so it is an exception. It is the only exception of kind **safety**: it can only take capability away, never add it.

*Positions*

| Position | Effect | Brain level |
|---|---|---|
| `run` | Normal | As deployed |
| `halt-actions` | No changes by the brain. Agents keep diagnosing and recommending, with Cloud Shell blocks for people to run themselves | 1 |
| `halt-all` | No changes and no model calls. The brain only records signals and evidence | 0 |

*What a trip does, in order*

1. **Sets the switch:** the tag `avdlz-brain-killswitch` on the brain's resource group becomes `halt-actions` or `halt-all`. Companion tags record who or what tripped it, when, and the episode (the same pattern as decision 0011's Lock tag).

   The state lives in an ARM tag, not in App Configuration. Every runtime can read it over the public control plane: the Actions runner, Automation, Cloud Shell and the orchestrator (red-team H1). And the Activity Log records every change to it.
2. **Cuts the executors' credentials:** it deletes the federated identity credentials on the executor identities (`brain-execute` and every EX-0003 identity). After that, Azure won't issue them a token, whatever GitHub approves.
3. **Expires every pending plan** and posts the trip on each open episode.
4. **Stops runs in flight at the next step boundary.** Each executor reads the switch before every step and stops when it isn't `run` or can't be read. A run that already changed something completes **only** its approved rollback, such as restoring the drain state it found. It still holds a token from before the trip, which lasts about an hour at most. That is also why step 2 alone isn't enough.
5. **Notifies:** the owner and the approvers team, through the action group and a pinned issue.

*What it never touches*

- **EX-0001 and EX-0002.** The kill switch never turns off a cost safety.
- **Azure's own features:** the scaling plan, Start VM on Connect, agent updates.
- **The landing zone's resources:** a trip changes only the brain's own tag and identities.

*Who can trip it*

- **Any one person** in the owner or approvers team, with no second approval. Stopping is easy; starting again is hard. There are two ways:
  - the `brain-killswitch.yml` workflow (`workflow_dispatch`, which also works from GitHub mobile);
  - a self-contained Cloud Shell block in [operations.md](operations.md) (lesson 0015).
- **The watchdog**, automatically, on these deterministic triggers:

| Trigger | Position |
|---|---|
| A write by a brain identity with no matching approved plan or exception run (Activity Log) | `halt-all` |
| A write by a brain identity outside the landing zone's resource groups | `halt-all` |
| `brain/exceptions/` or a guardrail file changed on the default branch without the required CODEOWNERS reviews | `halt-actions` |
| Two EX-0003 suspensions within 24 hours, or failed verifications above 20% of runs in a day | `halt-actions` |
| A Service Health incident for Azure Virtual Desktop in the landing zone's region (healing during a platform outage only churns) | `halt-actions` |
| The brain's daily token or cost cap reached | `halt-all` |
| The switch tag cleared outside `brain-resume.yml` | Trips again at the previous position |

- **Not agents.** No model or agent can trip it or clear it. The Critic and Diagnose agents can recommend a trip, and a person decides.

*The watchdog is not the brain*

The watchdog is a separate Consumption Logic App, in the same pattern as decision 0011's trigger Logic Apps:
- Azure Monitor alerts and Activity Log alerts start it through its own action group;
- it calls ARM with its own managed identity, which has exactly two roles: Tag Contributor on the brain's resource group, and Managed Identity Contributor on the executor identities;
- it doesn't depend on the orchestrator, Foundry or any private endpoint, so it still works when those are the problem.

If a trip fails, the action group pages the owner. A trip that doesn't happen is never silent.

*Starting again*

Only a person can start the brain again. The brain never re-enables itself, and nothing re-enables on a timer.
1. Close the trip's episode with a reason.
2. Run `brain-resume.yml`. It refuses while any trigger is still true.
3. The workflow redeploys `brain.bicep`, which recreates the federated credentials, then clears the tag.
4. dev and test need one person; prod needs the two required reviewers of the `prod` environment.

Clearing the tag by hand restores nothing: without the redeploy the executors still have no credentials, and the watchdog trips again.

*Drills*

- The kill switch has an offline scenario (`tests/offline/KillSwitch.Scenario.ps1`) with mock paths for the tag write, the deletion of federated credentials, and an executor that stops at a step boundary.
- It is drilled in `test` before any playbook is active under EX-0003, and then monthly. Each drill trips the switch while a drill run is in flight, confirms the executor can no longer get a token, confirms the run stopped and rolled back, and resumes.
- A missed or failed drill sets EX-0003 to approving each run until a drill passes.

### 4.6 Learn

- **Close every episode with an outcome:** `resolved-approved`, `rejected`, `expired`, `resolved-manual`, `escalated`, `false-positive`, `no-action`. A person's fix outside the brain is recorded too: the Retro agent asks for it on the issue.
- **Repeat detection:** a signature seen again after a guard was merged is flagged `regression` and opens a high-priority issue. This is the brain's main quality metric.
- **From episode to guard:** the Retro agent drafts the PR the retro skill describes today: a lesson in `docs/lessons`, a guard (Pester, offline scenario, template test or preflight check), and, if it can act, a detection and a playbook with its scenario. The redacted evidence becomes a fixture (decision 0007).
- **Playbook statistics:** success rate, verification time, rollbacks, approval and rejection rates with reasons. A good record changes how a plan is presented (its history is shown to the approver), **never whether it needs approval**. A playbook is **demoted** to level 1 automatically on failures (fail safe); restoring it is a PR a person merges.
- **Rejections teach:** a rejected plan needs a one-line reason. Rejections by signature feed the Retro agent, because a playbook people keep rejecting is a wrong playbook.
- **Baselines:** daily recomputation of per-hour-of-week connection counts, error rates, logon duration and profile load time, so detections can use "unusual for Monday 9:00" rather than fixed thresholds.
- **Evals:** every closed episode, redacted, can become an eval case: input signals and evidence, expected signature, expected playbook or escalation. `brain-eval` runs the agents against the eval set on every PR that changes prompts, models, detections or playbooks, with tools served by the offline mock. A drop in accuracy fails CI.

### 4.7 Evolve

The Evolve agent proposes, CI checks, `test` proves, a person decides.

1. **Drift:** nightly what-if of the deployed parameter file against the subscription, plus Resource Graph changes not made by the deploy identity. Each drift becomes a PR that either codifies the change in Bicep or documents the revert command.
2. **Right-sizing:** from baselines, propose `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT` or `AVD_PROFILE_QUOTA_GIB` changes. Prices come from the retail price API with the matching rules of decision 0010 and lesson 0025; a size change on an existing landing zone is called out in the PR, never applied silently.
3. **Posture:** Well-Architected findings that are not `data.accepted` become PRs or issues, by pillar.
4. **Dependencies:** AVM module and API version bumps (Dependabot or Renovate), with what-if output attached by CI.
5. **Rollout:** a merged change deploys to `test` first (`test.bicepparam`, same subscription), the brain watches it for a soak period (default 24 hours) with the same detections, then a person runs the `deploy` workflow to promote to `prod` behind its required reviewers. The brain never triggers a deployment; merging approves the code, and running the deployment is a second, separate human decision.

## 5. Services

### Azure (required)

| Service | Role | Why this one |
|---|---|---|
| Log Analytics, Azure Monitor (scheduled query rules, action groups, DCR) | Sense | Already deployed; AVD Insights tables live here |
| Event Grid (system and custom topics) | Signal bus | Push delivery to Functions with retries and dead-lettering |
| Azure Resource Graph | State and change history | Free, fast, cross-resource |
| Durable Functions (Flex Consumption) | Incident orchestration | Replayable state machine, VNet integration, scales to zero |
| GitHub Actions + Environments | Approval gate and executor (§4.5) | The Azure token exists only after a person approves; same pattern as `deploy.yml` |
| Azure Automation | Decision 0011's runbook only (exceptions EX-0001 and EX-0002); no brain playbooks | Unchanged |
| Cosmos DB for NoSQL (serverless) | Episodic and statistical memory | Schemaless episodes, change feed for indexing, private endpoint |
| Azure AI Search | Retrieval over repo knowledge and episodes | Hybrid + semantic ranking with citations |
| Blob Storage (immutable container) | Evidence, state lines, cost exports | Tamper-evident audit |
| Microsoft Foundry (Agent Service, models) | Reasoning | Hosts Claude and Azure OpenAI models, agent identities, tracing |
| Logic App (Consumption), its own action group | Kill-switch watchdog (EX-0004) | Independent of the brain it stops; the same pattern as decision 0011's trigger Logic Apps |
| Key Vault | Only for anything that cannot use a managed identity (ideally nothing) | Existing pattern |
| Managed identities, Microsoft Entra Agent ID (where available) | One identity per agent; the executor's identity is federated to the approval environment only | Least privilege, auditable per actor |
| Private endpoints and private DNS | All of the above | Decision 0001 |

### GitHub (required)

- **Repository** as the long-term memory: `brain/` (detections, playbooks, evals, prompts) beside the existing IaC, lessons and decisions.
- **Actions:** `validate.yml` gains the brain checks; new `brain-index.yml` (reindex on push), `brain-eval.yml`, `brain-evolve.yml` and `brain-retro.yml` (Claude Code in Actions, OIDC to Azure, read-only roles), and `brain-execute.yml` (plan, then approval-gated apply).
- **Issues and Projects** as the inbox: one issue per episode that needs a person, labeled `brain`, with a weekly digest issue. Every change is approved through a GitHub Environment with required reviewers (§4.5).
- **Org brain vs. public brain.** This public repo holds generic knowledge only, and the brain refuses to run in a public repository (§9.1). An organization runs the brain from a **private fork**, so issue bodies may contain more context; even there, issue text passes the redaction rules, and full detail stays in Cosmos DB and Blob, linked by episode ID.

### Additional services (optional, when needed)

| Service | When | Note |
|---|---|---|
| Anthropic API directly | If a model or feature isn't available in Foundry in the chosen region | Same prompts; data processing terms reviewed first |
| Microsoft Teams (Bot Service or Workflows) | Operators live in Teams rather than GitHub | Notifications that link to the GitHub approval; the approval itself stays in GitHub, where Azure can enforce it |
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
  "signatureSource": "detection:wvd-agent-unhealthy@git:<sha>",
  "agentClassified": false,
  "status": "open | diagnosing | awaiting-approval | acting | verifying | closed",
  "signals": ["sig-..."],
  "evidence": [{ "kind": "kql | rest | state-line | github", "ref": "blob://...", "sha256": "..." }],
  "changesBefore": [{ "resourceId": "...", "changeTime": "...", "actor": "..." }],
  "hypotheses": [{ "text": "...", "confidence": 0.7, "citations": ["docs/lessons/0011-...", "ep-..."] }],
  "actions": [{ "playbook": "restart-avd-agent", "version": "git:<sha>", "level": 2,
                "plan": { "hash": "sha256-...", "targets": ["/subscriptions/.../virtualMachines/..."],
                          "createdAt": "...", "expiresAt": "..." },
                "approval": { "kind": "per-run | standing | external", "exception": null,
                              "approvedBy": ["<github-login>"], "approvedAt": "...", "run": "<actions-run-url>" },
                "result": "succeeded" }],
  "verification": { "detection": "cleared", "preflight": "Ready" },
  "outcome": "resolved-approved",
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
approvers: { dev: 1, test: 1, prod: 2 }
preconditions:
  - noActiveSessions          # unknown counts as occupied
  - notPowerLocked
  - notDrainedByOthers
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

### 6.5 Exception

```yaml
# brain/exceptions/EX-0001-budget-lock.yml
id: EX-0001
kind: external                     # external | standing | safety
title: Budget Lock
action: { runbook: scripts/automation/Invoke-AvdPowerAction.ps1, name: Lock }
trigger: { budget: { percent: autoShutdownBudgetPercent } }   # detection | schedule | budget; never an agent
scope: { environments: [dev, test, prod], resourceGroups: [hosts, avd] }
limits: { perDay: 1 }
owner: <github-login>
approvedBy: [<github-login>]
approvedOn: 2026-10-04
reason: Stop spending when the budget is exceeded; waiting for a person lets costs run on.
review: { with: budget parameters }             # standing: { by: <date, at most 180 days out> }
undo: Resume, as an approved plan (playbook budget-lock-review)
decision: docs/decisions/0011-auto-shutdown.md
```

## 7. Repository layout

```
brain/
  detections/        <id>.kql + <id>.yml (signature, severity, playbook or notify-only, owner)
  playbooks/         <id>.yml (schema §6.3)
  exceptions/        EX-NNNN-<slug>.yml (schema §6.5); CODEOWNERS: people only
  prompts/           one file per agent; versioned like code
  evals/             <case>/ signals.json, evidence/, expected.json (redacted)
  schemas/           signal, episode, playbook, exception JSON Schemas
bicep/modules/brain.bicep
scripts/automation/Invoke-AvdPlaybook.ps1
scripts/brain/       Functions app (orchestrator) and the AVD-LZ MCP server
tests/offline/Playbooks.Scenario.ps1, Brain.Scenario.ps1, KillSwitch.Scenario.ps1
tests/brain/         schema tests, detection compile tests, eval runner
.github/workflows/   brain-index.yml, brain-eval.yml, brain-evolve.yml, brain-retro.yml, brain-execute.yml, brain-standing.yml,
                     brain-killswitch.yml, brain-resume.yml
```

Template and CI guards to add with the first slice:

- every detection compiles against the Log Analytics schema and names a playbook or `notify-only`;
- every playbook validates against its schema, names an existing runbook action, has a scenario and a verification;
- every exception validates against its schema, has a deterministic trigger, names a person as owner and approver, and has a review date in the future (standing) or a linked parameter (external); a PR written by the brain that touches `brain/exceptions/` fails;
- every `AzMock.psm1` path a playbook calls exists (decision 0011's rule);
- `brain-guard` (§9.2): agent-authored PRs touching protected paths or fields fail; every guardrail change gets the deterministic summary; evals are append-only and the base branch's cases always run;
- the workflow rules of §9.1: a linter, and a repo test that untrusted-event workflows hold no credentials, never interpolate event text, and never use `pull_request_target`;
- the signature rule of §4.2: detections declare how their signature is computed, and the episode schema has no writable signature after creation;
- no prompt file contains tenant data (the PII sample test from decision 0008, run over `brain/`);
- the new entry points carry the project notice (`tests/portal/disclaimer.test.mjs`).

## 8. First playbooks

Chosen because they are frequent in AVD estates, reversible, and verifiable from data the landing zone already collects. Level 2 means a person approves each run.

| Playbook | Signature | Level | Action | Verify |
|---|---|---|---|---|
| `restart-avd-agent` | Agent health failing, host otherwise up | 2 | Restart the RDAgentBootLoader service via managed Run Command | Agent healthy within 15 min |
| `recycle-empty-host` | Host unavailable, no sessions | 2 | Drain, restart VM, restore the drain state it found | Host available; connections succeed |
| `re-register-host` | Host not registered / token expired | 2 | New registration token (never stored), re-run `Register-AvdAgent` | Host appears available |
| `profile-share-headroom` | Share usage over 85% of quota | 1 → 3 | Issue now; PR raising `AVD_PROFILE_QUOTA_GIB` | Usage below threshold after deploy |
| `connection-errors-spike` | `WVDErrors` above baseline | 1 | Correlate with Service Health and recent changes; post diagnosis | n/a (diagnosis) |
| `fslogix-attach-failure` | FSLogix attach errors | 1 | Diagnosis with lesson 0011 and the open Kerberos case; escalate with evidence pack | n/a |
| `budget-lock-review` | Budget Lock active (0011) | 2 | Resume after approval | `power-locked` cleared |
| `drift-detected` | What-if or change not by deploy identity | 3 | PR to codify, or a plan to revert | Next what-if clean |
| `quota-pressure` | vCPU quota near the limit (lesson 0013, 0024) | 1 | Issue with the request command | Preflight quota check passes |

## 9. Security and privacy

- **Data classification:** tenant identifiers, UPNs, resource names and IPs are confidential and stay in the tenant's stores. GitHub content passes redaction; public `brain/evals` cases are redacted fixtures only.
- **Prompt injection:** logs, issue text, PR comments and tool output are untrusted (GitHub specifics in §9.1). Agents cannot act except through `propose_playbook_run`, which only produces a plan. The orchestrator checks schema, level and guardrails, the Critic reviews every plan, and a person approves it. Untrusted text is shown to the approver as quoted evidence, never as the plan's description.
- **Identities:** one per agent and one per executor; no shared credentials; no secrets in prompts; OIDC for GitHub Actions. Registration tokens and similar short-lived secrets are created inside the runbook and never returned.
- **Network:** all data stores private; the Functions app and AI Search use private endpoints and VNet integration in the brain's own subnet (a new `/27` in the spoke, or a peered management spoke in hub mode).
- **Audit:** every action has an episode, a plan with its hash, the approving person, the Actions run, Activity Log entries under the executor's identity, and a GitHub comment. Foundry tracing keeps agent steps.
- **Model data handling:** the organization confirms the data processing terms of the chosen model deployment before enabling the Reason layer. Without it, Sense, Remember and level 0-1 playbooks still work, with diagnosis left to people.

### 9.1 GitHub trust boundaries (red-team C3)

Anything a person outside the approvers team can write is untrusted input. That includes issues, comments, PR titles and bodies, branch names, commit messages and fork PRs. None of it may reach a component that holds write credentials. Text from these sources never becomes an instruction.

1. **No brain in a public repository.** The brain runs only from a private repository. The orchestrator and every brain workflow read the repository's visibility through the API at startup and before every GitHub write. If the repository is public, they stop and trip EX-0004 (`halt-all`).
2. **Public portal reports are not episodes.** `portal-report` issues in this public repo come from other people's tenants. They feed public knowledge only through the human retro (decisions 0006 and 0008). An organization's brain doesn't read the public repo's issues.
3. **Workflows started by untrusted events hold no credentials.** Any workflow triggered by `issues`, `issue_comment`, `pull_request` from a fork, `pull_request_target`, `discussion` or `workflow_run` declares:
   - `permissions: contents: read` and nothing else;
   - no `id-token: write`, so no Azure;
   - no secrets;
   - no agent with write tools.

   `pull_request_target` is not used at all. Event text is never interpolated into `run:` steps (`${{ github.event.* }}`); it is passed through `env:` and treated as data.
4. **Agents that write code run only from trusted triggers.** Retro and Evolve run only on `schedule` or `workflow_dispatch`, on the default branch. They don't run because an issue or comment arrived.
   - Their GitHub identity is a dedicated GitHub App (`avdlz-brain`) whose installation can write only `brain/*` branches, which branch protection enforces, and open draft PRs. It can never write to the default branch, change workflows, manage environments or bypass rules.
   - Their Azure identity is read-only.
5. **Inputs are quoted, with provenance.** When an agent uses issue or comment text, the text goes in as quoted evidence with its author and URL. Every agent PR lists the episodes, issues and comments it drew on in a deterministic **provenance** block, written by the workflow, not by the model. A reviewer can then see which parts of the change came from untrusted text.
6. **The workflows are checked in CI.** `validate.yml` runs a workflow linter (actionlint, plus zizmor or an equivalent) and a repo test that enforces rules 3 and 4 on every file in `.github/workflows/`.

### 9.2 Protected paths: the brain can't loosen its own guardrails (red-team C4)

The brain may propose code, but never changes to what limits it. Two mechanisms enforce this: GitHub's rules on who may merge, and a CI check on what changed. A change to a protected path is a **guardrail change**.

**Protected:**

| Path or field | Why |
|---|---|
| `brain/exceptions/**` | The only way around approval |
| In `brain/playbooks/*.yml`: `maxLevel`, `limits`, `preconditions`, `approvers`, `verify`, `rollback`, `signatures` | What a playbook may do and when |
| `brain/prompts/**` | How agents reason, including what they treat as untrusted |
| `brain/detections/*.yml`: `signature`, `severity`, `playbook` | What triggers a playbook (C1) |
| `brain/evals/**`: changes or deletions (additions are allowed) | The gate on agent quality |
| `scripts/automation/**`, `scripts/brain/**` guardrail and orchestrator code | The executor, the kill switch, the watchdog |
| `.github/workflows/**`, `.github/CODEOWNERS`, `bicep/modules/brain.bicep` role assignments and federated credentials | Who can do what |

**Rules:**

1. **Agents can't author guardrail changes.** CI job `brain-guard` fails any PR that has a commit by the `avdlz-brain` App and touches a protected path or field. It parses the YAML, so a guardrail field hidden in an otherwise ordinary playbook edit still fails.
   - The brain can only suggest a guardrail change as text in an issue or the digest. A person writes the change.
2. **People review every guardrail change.** CODEOWNERS names the owner and approvers teams for every protected path. Branch protection requires a code owner review, dismisses stale approvals on new commits, and allows no bypass, including for admins.
3. **A deterministic summary goes with every guardrail change.** `brain-guard` posts a summary: which protected fields changed, old value → new value, and whether the change makes the brain more or less capable. CI produces it, not a model, so the reviewer doesn't rely on the brain's own description.
4. **Evals are append-only.** Removing or changing a case needs a PR by a person, the label `eval-change`, and a reason recorded in `brain/evals/CHANGES.md`. `brain-eval` always runs the base branch's cases as well as the PR's, so a PR can't pass by editing the test it fails.
5. **A guardrail change merged around the rules trips the kill switch.** The watchdog trigger "guardrail file changed without the required reviews" (EX-0004) checks the merged PR. It looks for an approving code owner review by a person who isn't the PR's author, or an owner as author for a guardrail change that only lowers capability. Any other merge, including a direct push, trips `halt-actions`.

**Solo maintainer.** GitHub doesn't let authors approve their own PRs. With one owner, guardrail changes the owner writes can't get a second review. The rules allow an owner-authored change that **only lowers** capability, as `brain-guard` classifies it, to merge with the owner's own review. A change that raises capability, adds an exception, or adds a playbook to EX-0003 needs a second person. Until a second approver exists, those stay unmerged and the brain stays at approving each run (Q8).

## 10. Measures of success

| Measure | Target after phase 4 |
|---|---|
| Repeat incidents after a guard (regressions) | 0 per quarter |
| Mean time to detect (vs. user report) | Detected first in ≥ 80% of incidents |
| Time from detection to a plan ready for approval, known signatures | < 10 minutes |
| Time from approval to verified fix | < 20 minutes |
| Plans approved as proposed (not rejected or replaced) | ≥ 80%, with every rejection reason recorded |
| Known-signature incidents healed under EX-0003 | Reported per playbook; no target until two playbooks are active |
| Suspensions of EX-0003 playbooks | Each one has a lesson or a fix within 7 days |
| Rollbacks after an approved run | < 2% of runs |
| Changes made without an approval record (per-run approval or a registered exception) | 0, checked against the Activity Log |
| Exceptions past their review date | 0 |
| Kill-switch drill: from trip to the executors unable to get a token | < 5 minutes, monthly, every drill passed |
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
| **3 Heal, approved** | Plan and approval flow, `brain-execute.yml`, `Invoke-AvdPlaybook.ps1`, first three playbooks, kill switch and watchdog (EX-0004) with its first drill | 2 | 10 approved, verified runs per playbook in `test` (two or more hosts, fault-injection drills allowed) without rollback, which is EX-0003's entry criterion |
| **4 Learn and self-heal** | Retro agent PRs, playbook statistics, rejection reasons, demotion, baselines; the first playbooks enter EX-0003 (test first, then prod) | 2S | A new signature reaches a lesson and guard drafted by the brain and merged by a person |
| **5 Evolve** | Drift, right-sizing and posture PRs, test-then-prod rollout with soak, each deployment started by a person | 3 (PR) | One drift and one sizing PR merged and deployed through test |

## 12. Risks

| Risk | Mitigation |
|---|---|
| An agent's confident wrong diagnosis reaches the approver | A person approves every plan; the Critic's dissent and the raw evidence sit beside it; preconditions are re-checked at run time; verification and the approved rollback; demotion on failure |
| Approval fatigue: people approve without reading | Plans readable in 30 seconds; duplicates merged before they reach a person; rejection needs a reason; approvals faster than a few seconds are flagged in the digest; the brain never re-asks to pressure an approval, and an expired plan stays expired |
| A needed fix waits because nobody approves | Expiry returns the episode to the inbox with the Cloud Shell block for manual action; approver lists of at least two people per environment; on-call paging is optional (§5) |
| Alert storms flood episodes and token budgets | Triage merges by signature and scope; per-signature rate limits; token budget per day with a level-0 fallback |
| The brain itself fails silently | Heartbeat detection on the orchestrator and indexer; the scheduled preflight reports `brain-*` checks; the brain is watched by Azure Monitor, not by itself |
| Knowledge rot: lessons go stale as Azure changes | Each lesson gets a `last-verified` date; Retro flags lessons cited by failed playbooks; quarterly review issue |
| The mock is more permissive than Azure, so playbooks pass tests and fail for real | Lessons 0020 and 0021 apply; every real playbook failure updates `AzMock.psm1` |
| Cost creep | Consumption tiers where they exist; priced at deploy (decision 0010); the brain's resource group sits under the same budget and Lock |
| Tenant data leaks to GitHub | Redaction with tests; private fork for org brains; evidence stays in Blob |

## 13. Open questions

- **Q1** Model choice per agent: Claude through Foundry for diagnosis and code, a smaller model for triage? Decide with the phase 2 eval set, not up front.
- **Q2** Approval surface: GitHub Environments are where Azure can enforce approval. Are Teams notifications that link to them enough?
- **Q3** Retrieval: Azure AI Search, or Cosmos DB vector search alone for small estates?
- **Q4** One brain per landing zone, or one per organization over several landing zones (the episode schema allows `environment` and `scope` to span them)?
- **Q5** Microsoft Entra Agent ID availability and roles in the target tenants, versus plain user-assigned managed identities.
- **Q6** Image pipeline: host replacement is far stronger with a golden image (listed in [out-of-scope.md](out-of-scope.md) as a next layer). Build it before or alongside phase 3?
- **Q7** ~~Does the budget Lock wait for approval?~~ **Decided 2026-10-04:** no; it stays a pre-approved exception (EX-0001). More exceptions will follow through §4.5.1. EX-0002 (scheduled Stop) confirmed the same day, and self-healing became EX-0003.
- **Q8** Solo maintainer: guardrail changes that raise capability, new exceptions and EX-0003 entries need a second person (§9.2). Who is the second approver, or should the brain stay at approving each run until there is one?
