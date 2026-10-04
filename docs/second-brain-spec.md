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

### 3.1 Tiers: adopt as much as you need (red-team S1)

The brain is for the community, and one person maintains it. So it comes in tiers. Each tier is useful on its own and adds the fewest services that make it work. An adopter picks one with `AVD_BRAIN_TIER` (`0` to `3`, guarded with `empty(...)`, lesson 0004). `0`, the default, deploys nothing.

| Tier | What it does | What it adds in Azure | Highest level |
|---|---|---|---|
| **0 Off** | Today's landing zone | Nothing | — |
| **1 Notice** | Detections raise alerts. A scheduled job runs the preflight and collects pseudonymized evidence, then opens one issue per episode in the adopter's private repo. Claude Code in Actions posts a diagnosis citing the lessons. A weekly digest. The kill switch | Container Apps environment and job, a private Blob container, alert rules, the watchdog Logic App, two small subnets | 1 Recommend |
| **2 Approved fixes** | Plans, the approval gate and the executor (§4.5); playbooks chosen from Tier 1's ranked signature list | One executor identity per playbook with a custom role | 2 Approve and run |
| **3 Memory and agents** | Episodes and vector retrieval in Cosmos DB, Foundry agents, the orchestrator, Retro and Evolve PRs, self-healing (EX-0003) | Durable Functions, Cosmos DB, Foundry with a chat model and an embedding model; Azure AI Search only if the estate outgrows Cosmos DB vector search | 2S and 3 |

What keeps this maintainable by one person:

- **One language.** Everything new is PowerShell and Bicep: the job, the playbooks, the orchestrator (Durable Functions supports PowerShell) and the agents' tools. PSScriptAnalyzer, Pester and the offline harness already cover them. No custom MCP server and no new runtime.
- **Tier 1 is the supported core.** Tiers 2 and 3 are marked **experimental** until real runs have verified them (decision 0006), the same way decision 0011 recorded what it hadn't verified.
- **Small surface first.** Without Tier 3, episodes live as GitHub issues plus Blob evidence. Retrieval is the Git checkout itself, which Claude Code reads.

### 3.2 The project and its adopters

There are two roles, and the safety rules apply to each one differently.

| | The project | An adopter |
|---|---|---|
| Who | This public repository and its one maintainer | An organization, or a person, running the brain in their own tenant |
| Where the brain runs | Nowhere: the brain refuses to run in a public repository (§9.1) | A private fork, against their landing zone |
| Ships or holds | Code, templates, detections, playbooks, generic lessons; exception **templates**; conservative defaults (`maxLevel = 1`, EX-0003 with no playbooks) | Their active exceptions, their EX-0003 entries, their approvers, their episodes |
| Approvals | The maintainer alone, in **solo mode** (§9.3) | Solo mode with one approver; **team mode** with two or more |

**Upstream changes are guardrail changes.** An adopter syncs from a **release tag**, never from `master`. Releases carry GitHub artifact attestations. A sync PR runs `brain-guard` (§9.2) like any other PR, so an adopter sees every guardrail field that upstream changed before merging it. Upstream never ships an active exception beyond EX-0001, EX-0002 and EX-0004, so a release can't turn on self-healing in someone's tenant.

## 4. Architecture

### 4.1 Overview

```
┌──── GitHub: the adopter's private repo ──────────────────────────────────────────────────────┐
│ brain/: detections · playbooks · exceptions · prompts · evals    lessons · decisions · IaC   │
│ Actions: diagnose (Claude Code) · execute (plan → approval → apply) · killswitch · resume    │
│ Issues: one per episode, weekly digest              Environments: the approval gates         │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
        ▲ issues with pseudonymized evidence    │ approved job only → federated token
        │ dispatch (a trusted trigger)          ▼
┌──── Tier 1: Notice ──────────────────────────────────────────────────────────────────────────┐
│ Scheduled query rules (detections) → alerts → Container Apps job (PowerShell 7.4, pinned)    │
│   runs the preflight, collects and pseudonymizes evidence, opens issues, dispatches diagnosis│
│ Blob (private, immutable): state lines, evidence      Watchdog Logic App: kill switch EX-0004│
└──────────────────────────────────────────────────────────────────────────────────────────────┘
┌──── Tier 2: Approved fixes ──────────────────────────────────────────────────────────────────┐
│ Executor identities, one per playbook, custom roles → ARM: drain, restart, pinned Run Command│
│ Every run bound to an approved plan hash; positive verification; the approved rollback       │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
┌──── Tier 3: Memory and agents ───────────────────────────────────────────────────────────────┐
│ Durable Functions orchestrator (PowerShell) · Cosmos DB episodes + vector search             │
│ Foundry agents (Claude or Azure OpenAI) calling PowerShell Functions as OpenAPI tools        │
│ Self-healing EX-0003 · Retro and Evolve PRs · Azure AI Search only if needed                 │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

All new resources go into one new resource group, `rg-<prefix>-<env>-brain`, deployed by a new module `bicep/modules/brain.bicep`, opt-in through `AVD_BRAIN_TIER` (§3.1). A landing zone at tier 0 behaves exactly as today. Network: two `/27` subnets in the spoke's free range: `snet-brain-jobs` (`10.100.2.64/27`, delegated to the Container Apps environment) and, at Tier 3, `snet-brain-func` (`10.100.2.96/27`, for the Functions app). In hub mode, the hub firewall must allow `github.com` and `mcr.microsoft.com` for the job.

### 4.2 Sense

| Signal | Source | Transport | Notes |
|---|---|---|---|
| Connections, errors, checkpoints, agent health | Log Analytics: `WVDConnections`, `WVDErrors`, `WVDCheckpoints`, `WVDAgentHealthStatus`, `WVDConnectionNetworkData` | Scheduled query alerts → action group → Event Grid custom topic | Already collected by the AVD Insights DCR |
| FSLogix and host events | Log Analytics `Event` (FSLogix Apps operational log), `Perf` | Same | Extend the DCR with FSLogix event IDs |
| Resource state and changes | Azure Resource Graph, `resourcechanges` | Event Grid system topic (subscription) for writes; Resource Graph for "what changed before X" | Correlates incidents with changes |
| Platform health | Service Health, Resource Health | Activity Log alert → action group | First check of every connection incident |
| Posture | Advisor, Defender for Cloud, Policy compliance | Scheduled pull, REST | Same sources as `-WellArchitected` |
| Cost | Cost Management exports to Blob; budget alerts | Export + action group | Budget lock already exists (0011) |
| Landing zone health | Post-deployment preflight (`-SkipTenant -SkipNtfs`, plus `-WellArchitected` weekly), run by a **Container Apps job** on a schedule (red-team H2) | State line `<<<AVDLZ-STATE ...>>>` written to private Blob | Same scripts and modules as Cloud Shell, so the portal's contract holds |
| Host compliance | Azure Policy guest configuration assignments and the Azure Monitor Agent on the hosts | ARM and Log Analytics | No Graph permissions (red-team H8) |
| Sign-ins (optional, Tier 3) | Entra sign-in logs, through a diagnostic setting **the tenant admin owns**, filtered by the DCR to the AVD and Windows Cloud Login apps | Log Analytics | Needs Entra ID P1 or P2. The brain holds no Graph application permissions |
| Code and CI | GitHub: workflow runs and PRs in the brain's private repository | Webhook → Function | Public `portal-report` issues are **not** signals (§9.1) |

Every signal is normalized into a **Signal** (§6.1) with a **signature**: a stable hash of what failed, not when or where (for example `wvd-agent-unhealthy:upgrade-failed`, `fslogix-attach:0x00000005`). Signatures are how the brain recognizes "we've seen this before".

**Only detections assign signatures (red-team C1).** A signature comes from the detection that fired: from its metadata, or from a deterministic function of the columns the detection returns. Nothing else assigns one.
- An episode's signature is set once, when it opens, and can't change. The orchestrator rejects any write that would change it.
- Merging signals into an episode is a pure function: the same signature, the same scope, inside a time window.
- An agent can add a **hypothesis** ("this looks like `fslogix-attach:0x00000005`"), lower an episode's level, or ask for a person. It can never set or change the signature.
- Playbooks are selected only by signature. When Diagnose suggests a playbook for an episode with an unknown signature, the plan is marked `agent-classified`. It always needs approval of each run, it is never eligible for EX-0003, and the approver sees that the brain guessed the match.

**The scheduled job (red-team H2).** The preflight needs PowerShell 7 with Az modules, which Automation can't pin (the reason decision 0011 went module-free). So a Container Apps job runs it:
- the image is `mcr.microsoft.com/azure-powershell`, pinned by digest, so its module versions are recorded;
- it runs the repo's scripts at the deployed commit;
- it signs in with `Connect-AzAccount -Identity`, using a read-only identity;
- it is VNet-integrated in `snet-brain-jobs`, so it reaches the private Blob container and Key Vault.

The same job collects and pseudonymizes evidence (§9.4), opens or updates episode issues as the brain's GitHub App, and dispatches diagnosis (a trusted trigger, §9.1). The job's image digest is a guardrail (§9.2), and moving to a new image is a PR.

**Detections are code.** Each one is a KQL file with metadata in `brain/detections/` (§7). The Bicep module turns them into scheduled query rules, so a detection changes only by PR, and a template test checks that every detection compiles and names a playbook or `notify-only`.

### 4.3 Remember

Five kinds of memory, each with one home.

| Memory | Holds | Home | Written by |
|---|---|---|---|
| **Semantic** | Lessons, decisions, docs, gotchas, curated Microsoft Learn excerpts | Git (canonical). Tiers 1–2 read the checkout directly; Tier 3 embeds it into Cosmos DB vector search on push | People and PRs only |
| **Procedural** | Detections, playbooks, guards, evals | Git (`brain/`) | People and PRs only |
| **Episodic** | Incidents: signals, evidence, hypotheses, actions, outcomes | Tiers 1–2: a GitHub issue plus Blob evidence. Tier 3: Cosmos DB for NoSQL, with vector search | Job / orchestrator |
| **State** | What exists now and what changed | Resource Graph, Log Analytics (queried live, never copied) | Azure |
| **Statistical** | Baselines per host pool and hour of week; playbook success rates; signature frequency | Tiers 1–2: a JSON file in Blob, refreshed daily. Tier 3: Cosmos DB | Job / Learn job |

Why this split:

- **Git is the long-term memory and the only place policy lives.** It is reviewed, versioned and already wired to CI. An agent can propose to it but never write to it directly.
- **Tenant-specific memory never reaches a public repo:** resource names, timings and pseudonyms. At Tiers 1–2 it lives in the private repo's issues and in Blob. At Tier 3 it lives in Cosmos DB, whose serverless mode keeps idle cost near zero.
- **Retrieval at Tier 3 is Cosmos DB vector search** over the embedded repo knowledge and the episodes, so "this looks like lesson 0011" and "this looks like last Tuesday's episode" come from one query, and every answer cites its sources. Azure AI Search is an option for large estates only, because it has no serverless tier and its private networking needs a billed tier that runs all month (red-team H9; Q3).
- **Evidence is immutable.** Raw outputs go to Blob with a time-based immutability policy, and episodes reference them by hash. A diagnosis can always be re-checked against what was actually returned.

Retention (red-team M7):
- **Episodes:** 13 months, which is a year of seasonality plus one month.
- **Signals:** 30 days.
- **Evidence:** 90 days, under a time-based immutability window of **30 days**, so it is tamper-evident while an incident is live and deletable afterwards. Evidence a lesson needs is copied into a redacted fixture in Git, never kept in Blob.

Lifecycle management deletes the rest. Erasure is covered in §9.4.

### 4.4 Reason

**Tiers 1–2:** one agent, Diagnose, as Claude Code in GitHub Actions. The scheduled job dispatches it with an episode ID. It reads the episode issue and the repo, has read-only Azure access, and writes one comment. **Tier 3:** the agents below run in **Microsoft Foundry Agent Service**, with the model chosen per agent (Claude or Azure OpenAI). The `brain-evolve` and `brain-retro` workflows use Claude Code in GitHub Actions at every tier where they are enabled, so code changes go through the same path people use today. Where model calls are processed is a deployment choice (§9.4).

| Agent | Trigger | Reads | Produces | Can act? |
|---|---|---|---|---|
| **Triage** | New signal | Signal, recent episodes with the same signature, Service Health | Severity and a summary of an episode the orchestrator opened or merged deterministically; may lower the level or ask for a person, never set the signature | No |
| **Diagnose** | Episode opened, unknown signature or playbook asks | Logs (KQL), Resource Graph changes, preflight state lines, the repo checkout (Tiers 1–2) or vector search over lessons and episodes (Tier 3) | Ranked hypotheses, each with evidence links and a confidence; a proposed playbook or "escalate" | No |
| **Critic** | Before any plan goes to a person, and before any PR | The proposal and its evidence | Agreement, or a dissent shown to the approver beside the plan. A second model or prompt that argues against the proposal | No |
| **Retro** | Episode closed with a new signature, or a signature repeated ≥3 times in 30 days | Episode, evidence, `.claude/skills/retro/SKILL.md` | A draft PR: lesson + guard (+ detection, + playbook) | PR only |
| **Evolve** | Weekly, or on drift | Resource Graph vs. what-if, utilization baselines, cost, WAF findings | PRs: codify or revert drift, sizing (`AVD_SESSION_HOST_*`, `AVD_PROFILE_QUOTA_GIB`), new alerts, AVM version bumps | PR only |
| **Concierge** | Operator question (GitHub issue comment, Teams, portal) | Everything above, read-only | Answer with citations | No |

Agents reach tools with an allowlist:

- **Azure MCP Server**: read-only operations (Resource Graph, Log Analytics query, Monitor, Advisor).
- **GitHub MCP**: issues, comments, branches and PRs on the brain's repository only.
- **AVD-LZ tools** (this repo, PowerShell): what already exists, as typed operations: run the preflight and return its state line, the KQL catalog by name, `Invoke-AvdPowerAction -WhatIf`, the playbook catalog, and `propose_playbook_run(episodeId, playbookId)` (the orchestrator binds parameters from the episode; the agent supplies none). Claude Code runs them as allowlisted commands. At Tier 3 they are PowerShell Azure Functions with an OpenAPI description, which Foundry agents call as OpenAPI tools. There is no tool that writes to Azure directly, and no custom MCP server to maintain.

Everything an agent reads from logs, issues, comments or tool output is **untrusted data**. Prompts mark it as such; no instruction found in it can widen what the agent may do. The only way to act is `propose_playbook_run`, which produces a plan for a person to approve (§4.5). The proposal alone changes nothing.

**Models (Q1, decided 2026-10-04).** All agents start on one model, **Claude Opus 5.5** (`claude-opus-5-5`). Each agent gets its own effort level. A cheaper model replaces it only where evals show quality holds.

| Agent | Model | Effort | Why |
|---|---|---|---|
| Diagnose (the only agent at Tiers 1–2) | Claude Opus 5.5 | `high` | Reading evidence and citing the right lesson is where capability pays off |
| Triage (Tier 3) | Claude Opus 5.5 | `low` | It only summarizes; signatures come from detections (§4.2). First candidate for Claude Sonnet 5.5 |
| Critic | Claude Opus 5.5, separate adversarial prompt | `high` | Then tested against a different model (below) |
| Retro and Evolve (Claude Code in Actions) | Claude Opus 5.5 | `high` | Writes code and tests; its PRs are what a person reviews |
| Concierge | Claude Opus 5.5 | `low` to `medium` | Answers with citations |

Why one model:
- **Volume is low.** An estate has a handful of episodes a day, so a wrong diagnosis costs more than the token difference.
- **Effort first, then model.** On current models, a stronger model at lower effort usually matches a weaker model at high effort. One model also means one prompt cache and one eval baseline.
- **Prices come from the meters.** Claude Sonnet 5.5 costs about half as much per token as Claude Opus 5.5, and Claude on Foundry is billed at the same per-token rates as the Anthropic API. The deploy step prices the chosen setup from the meters (decision 0010). This spec doesn't estimate it.

Rules:
- **Set effort explicitly.** Claude Opus 5.5 defaults to `medium`. Prompts keep the lessons and docs first, so prompt caching covers the repeated input.
- **A refusal is an escalation.** Safety classifiers can decline content that looks like security work, and Run Command, credentials and access are near that line. A `refusal` stop reason marks the episode for a person, with the evidence. The brain never rephrases to get past it.
  - On the Anthropic API, server-side fallbacks (`fallbacks: "default"`) are enabled.
  - On Foundry, the SDK's refusal-fallback middleware does the same job.
  - Either way, a fallback answer is labeled with the model that produced it.
- **Hosting changes features, not prices.** `AVD_BRAIN_MODEL` (§9.4) picks the platform. Some features work only on Anthropic-hosted Foundry deployments, so the Tier 3 tools are plain function tools that work on both.
- **Model IDs are configuration.** They live in `brain/models.yml`, a guardrail file (§9.2), and change only by PR.

**Re-testing the choice.** Once the eval set has about 20 redacted real episodes (phase 3), each agent's cases run on Claude Opus 5.5 at the next lower effort and on Claude Sonnet 5.5. The cheapest setup that passes the eval gate (§4.6) wins, decided per agent and recorded in `brain/models.yml` with the eval run.

For the Critic, Claude Opus 5.5 with its own prompt is also run against Claude Sonnet 5.5 and an Azure OpenAI model on episodes seeded with known-wrong plans. The Critic keeps whichever model catches the most of them, because a critic that shares the diagnoser's blind spots adds little. The same re-test runs whenever a new model generation ships.

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

  In team mode, prod and any plan that uses Run Command need two people: a second environment, `brain-<env>-second`, whose reviewer list shares no one with the first. Solo mode is in §9.3.
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
- **Least privilege (red-team H6):**
  - **one executor identity per playbook**, each with a **custom role** listing only that playbook's actions, scoped to the hosts and AVD resource groups, and usable only through the approval environment or its EX-0003 environment. For example:
    - `restart-avd-agent`: `virtualMachines/read`, `virtualMachines/runCommands/read|write|delete`, `hostpools/sessionhosts/read`;
    - `recycle-empty-host`: `virtualMachines/read`, `virtualMachines/restart/action`, `hostpools/sessionhosts/read|write`, `sessionhosts/usersessions/read`;
  - **Run Command scripts are fixed files** in `scripts/ops/host/`, Windows PowerShell 5.1, with no parameters or only enumerated ones. The playbook pins each script's SHA-256. The executor hashes the file at the approved commit, refuses on a mismatch, sends the script inline, reads back its output and deletes the Run Command resource afterwards;
  - an Activity Log alert fires on `runCommands/write` by anyone except the deploy identity or an executor. A write by an executor without a matching plan trips the kill switch (EX-0004);
  - decision 0011's runbook (EX-0001, EX-0002) is pinned by content hash as well (`publishContentLink.contentHash`; verify the property against the Automation API at build);
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
- **Proven:** at least 10 approved, verified runs without a rollback in `test` (fault-injection drills allowed). For prod, at least 3 more approved, verified runs in prod. The PR needs two people in team mode, or the 72-hour time-lock in solo mode (§9.3).
- **Positive verification and a listed rollback**, as for every plan.
- **Tested:** an offline scenario covering success, failed verification and every precondition that blocks it.

| Playbook | Environments | Limits | Entry status |
|---|---|---|---|
| `restart-avd-agent` | dev, test, prod | 1 host per pool at a time; 3 per hour; 2 per host per day | Candidate: needs its run record |
| `recycle-empty-host` | dev, test, prod | 1 host per pool at a time; 2 per hour; 1 per host per day | Candidate: needs its run record |

Not eligible:
- `re-register-host`: it creates a registration token;
- `replace-host`: it changes capacity while it runs;
- anything that changes capacity, sizing, configuration or code;
- Resume after a Lock.

What still holds under EX-0003:
- every guardrail in §4.5: kill switch, blast radius, the other actors' locks and drain states, unknown counts as occupied, positive verification;
- the scope is checked with the plan rebuilt just before acting;
- each run is posted to its episode's issue as it happens, not only in the digest;
- a failed verification or a rollback suspends **that playbook** in EX-0003 and sends it back to approving each run, until a person re-enables it by PR.

Because no person approves each run, these red-team fixes become **required** before any playbook is active in EX-0003:
- C1: signatures come only from detections (§4.2), and the `brain-guard` check is in place (§9.2);
- H6: the per-playbook identity and custom role, and the pinned Run Command script (§4.5);
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
4. dev and test need one person. Prod needs the `prod` environment's two required reviewers in team mode, or the owner after a 60-minute wait timer in solo mode (§9.3).

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
- **Evals (red-team M10):** every closed episode, redacted, can become an eval case: input signals and evidence, expected signature, expected playbook or escalation. `brain-eval` runs the agents against the eval set with tools served by the offline mock. Model output varies from run to run, so the gate is statistical:
  - each case runs **5 times**. A PR fails when the **90% lower confidence bound** of its pass rate falls more than **5 points** below the base branch's pass rate, measured the same way. A single unlucky run never fails a PR;
  - it runs on PRs that change prompts, models, detections or playbooks, **only from branches in the same repository** (the owner's or the brain's App), and nightly on the default branch. Never on fork PRs: the model key sits in a `brain-eval` environment limited to those branches;
  - a daily spend cap stops evals once reached and reports it, rather than passing silently.

### 4.7 Evolve

The Evolve agent proposes, CI checks, `test` proves, a person decides.

1. **Drift (red-team M8):** found from Resource Graph `resourcechanges` that the deploy identity didn't make, not from a nightly what-if. What-if over AVM templates reports changes that aren't real, and it needs the deployment's inputs.
   - What-if runs only on PRs, inside the deploy workflow.
   - Known what-if noise is suppressed only through `brain/whatif-noise.yml`. That file is a guardrail (§9.2), because a suppression can hide real drift. Each entry names the resource type, the property, and the evidence that it's noise.
   - Each drift becomes either a PR that codifies the change in Bicep, or a plan to revert it, which a person approves.
2. **Right-sizing:** from baselines, propose `AVD_SESSION_HOST_COUNT`, `AVD_SESSION_HOST_VM_SIZE`, `AVD_MAX_SESSION_LIMIT` or `AVD_PROFILE_QUOTA_GIB` changes. Prices come from the retail price API with the matching rules of decision 0010 and lesson 0025; a size change on an existing landing zone is called out in the PR, never applied silently.
3. **Posture:** Well-Architected findings that are not `data.accepted` become PRs or issues, by pillar.
4. **Dependencies:** AVM module and API version bumps (Dependabot or Renovate), with what-if output attached by CI.
5. **Rollout (red-team M9):** a person deploys a merged change to `test` first (`test.bicepparam`, same subscription). A quiet `test` with no users proves nothing, so the soak needs **positive evidence**:
   - **The readiness probe passes** at the start of the soak and every hour after: the sign-in readiness checks of `Deploy-AvdDemo.ps1` (hosts Available and accepting sessions, all AVD health checks, the host run commands, the access assignments), run by the scheduled job against `test`'s host pool, read-only;
   - **no detection fires** for `test` during the soak (default 24 hours);
   - **a real sign-in, when the change touches the user's path.** CI classifies the diff: session hosts, storage, network, the control plane, RBAC. For those changes, `WVDConnections` must show at least one completed connection to `test`'s host pool after the deployment. A person signs in through the Windows App to produce it, and the soak waits for it.

   Then a person runs the `deploy` workflow to promote to `prod` behind its required reviewers.

   **Shared budget:** `test` sits in the same subscription as `dev` (and, for many adopters, `prod`), so its spend counts toward decision 0011's subscription-wide budget and Lock (EX-0001). A long soak with extra hosts can trip the Lock for everyone. The spec doesn't change that coupling; the soak report shows `test`'s spend so far, and adopters who soak often should give `test` its own subscription. The brain never triggers a deployment; merging approves the code, and running the deployment is a second, separate human decision.

## 5. Services

### Azure (required)

| Service | Role | Why this one |
|---|---|---|
| Log Analytics, Azure Monitor (scheduled query rules, action groups, DCR) | Sense | Already deployed; AVD Insights tables live here |
| Event Grid (system and custom topics) | Signal bus | Push delivery to Functions with retries and dead-lettering |
| Azure Resource Graph | State and change history | Free, fast, cross-resource |
| Container Apps (workload profiles environment, consumption) and a scheduled job | Tier 1: preflight, evidence, episode issues (red-team H2) | Pinned modules, VNet-integrated, PowerShell 7.4 |
| Durable Functions (Flex Consumption, PowerShell) | Tier 3: incident orchestration and the agents' tools | Replayable state machine, VNet integration, scales to zero |
| GitHub Actions + Environments | Approval gate and executor (§4.5) | The Azure token exists only after a person approves; same pattern as `deploy.yml` |
| Azure Automation | Decision 0011's runbook only (exceptions EX-0001 and EX-0002); no brain playbooks | Unchanged |
| Cosmos DB for NoSQL (serverless) | Tier 3: episodic and statistical memory, vector search | Schemaless episodes, built-in vector index, private endpoint |
| Azure AI Search | Optional at Tier 3, large estates only | Hybrid + semantic ranking; always-on billed tier (red-team H9) |
| Blob Storage (immutable container) | Evidence, state lines, cost exports | Tamper-evident audit |
| Microsoft Foundry (Agent Service, a chat model, an embedding model) | Tier 3: reasoning and embeddings | Hosts Claude and Azure OpenAI models, agent identities, tracing |
| Budget on the brain's resource group | Every tier: its action group trips EX-0004 `halt-all` | The brain can't outspend its own budget (red-team H9) |
| Logic App (Consumption), its own action group | Kill-switch watchdog (EX-0004) | Independent of the brain it stops; the same pattern as decision 0011's trigger Logic Apps |
| Key Vault (the landing zone's) | The pseudonymization key (§9.4), generated at deployment and never shown | Existing pattern; lesson 0002 |
| Managed identities, Microsoft Entra Agent ID (where available) | One identity per agent; the executor's identity is federated to the approval environment only | Least privilege, auditable per actor |
| Private endpoints and private DNS | Blob, Cosmos DB, Key Vault, Functions | Decision 0001 |

### GitHub (required)

- **Repository** as the long-term memory: `brain/` (detections, playbooks, evals, prompts) beside the existing IaC, lessons and decisions.
- **Actions:** `validate.yml` gains the brain checks; new `brain-diagnose.yml` (Tier 1, dispatch only), `brain-index.yml` (Tier 3, re-embed on push), `brain-eval.yml`, `brain-evolve.yml` and `brain-retro.yml` (Claude Code in Actions, OIDC to Azure, read-only roles), and `brain-execute.yml` (plan, then approval-gated apply).
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

**Cost (red-team H9).**
- Tier 1 runs on consumption meters: Container Apps job executions, Blob storage, alert rules, Logic App runs. Its model cost is per diagnosis.
- Tier 3 adds Cosmos DB request units, Foundry tokens and embeddings, and AI Search only if it is chosen.
- Following decision 0010, the deploy step prices the chosen tier from the retail price API and prints the meters it matched. This spec does not guess numbers.
- Every tier deploys a budget on the brain's resource group (`AVD_BRAIN_MONTHLY_BUDGET`). Its action trips the kill switch (`halt-all`).
- Decision 0011's budget is subscription-wide, so the brain's spend also counts toward the hosts' Lock. The brain's own budget is there to stop the brain well before that.

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
approvers: { dev: 1, test: 1, prod: 2 }      # team mode; solo mode uses 1 (§9.3)
identity: brain-exec-restart-avd-agent      # its own custom role (§4.5)
script: { path: scripts/ops/host/Restart-AvdAgent.ps1, sha256: <hash> }
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
  whatif-noise.yml   reviewed what-if suppressions, each with evidence (§4.7)
  models.yml         model and effort per agent, with the eval run that chose them (§4.4)
bicep/modules/brain.bicep
scripts/automation/Invoke-AvdPlaybook.ps1
scripts/brain/       the Tier 1 job entry point; Tier 3 Functions (orchestrator, agents' tools); all PowerShell
scripts/ops/host/    Run Command scripts for playbooks (Windows PowerShell 5.1, hash-pinned)
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
| `drift-detected` | A Resource Graph change not made by the deploy identity | 3 | PR to codify, or a plan to revert | No unexplained changes on the next pass; what-if clean on the PR |
| `quota-pressure` | vCPU quota near the limit (lesson 0013, 0024) | 1 | Issue with the request command | Preflight quota check passes |
| `replace-host` | A host still unhealthy after `recycle-empty-host` | 2 | Drain, deploy a fresh host from the current gallery image (phase 0b), remove the old one | The new host is Available and passes the AVD health checks |

## 9. Security and privacy

- **Data classification:** tenant identifiers, UPNs, resource names and IPs are confidential and stay in the tenant's stores. GitHub content passes redaction; public `brain/evals` cases are redacted fixtures only.
- **Prompt injection:** logs, issue text, PR comments and tool output are untrusted (GitHub specifics in §9.1). Agents cannot act except through `propose_playbook_run`, which only produces a plan. The orchestrator checks schema, level and guardrails, the Critic reviews every plan, and a person approves it. Untrusted text is shown to the approver as quoted evidence, never as the plan's description.
- **Identities:** one per agent and one per executor; no shared credentials; no secrets in prompts; OIDC for GitHub Actions. Registration tokens and similar short-lived secrets are created inside the runbook and never returned.
- **Network:** all data stores are private. The job and the Functions app are VNet-integrated in their own `/27` subnets (§4.1).
- **Audit:** every action has an episode, a plan with its hash, the approving person, the Actions run, Activity Log entries under the executor's identity, and a GitHub comment. Foundry tracing keeps agent steps.
- **Model data handling:** see §9.4.

### 9.1 GitHub trust boundaries (red-team C3)

Anything a person outside the approvers team can write is untrusted input. That includes issues, comments, PR titles and bodies, branch names, commit messages and fork PRs. None of it may reach a component that holds write credentials. Text from these sources never becomes an instruction.

1. **No brain in a public repository.** The brain runs only from a private repository. That covers every workflow that touches a tenant or the brain's memory: diagnose, execute, standing, kill switch, resume, retro, evolve and index. `brain-guard` and `brain-eval` are CI: they also run in the public project repository, against redacted fixtures and the offline mock, never tenant data. The orchestrator and every brain workflow read the repository's visibility through the API at startup and before every GitHub write. If the repository is public, they stop and trip EX-0004 (`halt-all`).
2. **Public portal reports are not episodes.** `portal-report` issues in this public repo come from other people's tenants. They feed public knowledge only through the human retro (decisions 0006 and 0008). An organization's brain doesn't read the public repo's issues.
3. **Workflows started by untrusted events hold no credentials.** Any workflow triggered by `issues`, `issue_comment`, `pull_request` from a fork, `pull_request_review`, `pull_request_target`, `discussion` or `workflow_run` declares:
   - read-only permissions (`contents: read`, plus `pull-requests: read` for `brain-guard`) and nothing else;
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
| `brain/whatif-noise.yml` | A suppression can hide real drift |
| `brain/models.yml` | Which model and effort each agent uses |
| `scripts/automation/**`, `scripts/brain/**` guardrail and orchestrator code | The executor, the kill switch, the watchdog |
| `.github/workflows/**`, `.github/CODEOWNERS`, `bicep/modules/brain.bicep` role assignments and federated credentials | Who can do what |

**Rules:**

1. **Agents can't author guardrail changes.** CI job `brain-guard` fails any PR that has a commit by the `avdlz-brain` App and touches a protected path or field. It parses the YAML, so a guardrail field hidden in an otherwise ordinary playbook edit still fails.
   - The brain can only suggest a guardrail change as text in an issue or the digest. A person writes the change.
2. **People review every guardrail change.** CODEOWNERS names the owner and approvers teams for every protected path. Branch protection requires a code owner review, dismisses stale approvals on new commits, and allows no bypass, including for admins.
3. **A deterministic summary goes with every guardrail change.** `brain-guard` posts a summary: which protected fields changed, old value → new value, and whether the change makes the brain more or less capable. CI produces it, not a model, so the reviewer doesn't rely on the brain's own description.
4. **Evals are append-only.** Removing or changing a case needs a PR by a person, the label `eval-change`, and a reason recorded in `brain/evals/CHANGES.md`. `brain-eval` always runs the base branch's cases as well as the PR's, so a PR can't pass by editing the test it fails.
5. **A guardrail change merged around the rules trips the kill switch.** The watchdog trigger "guardrail file changed without the required reviews" (EX-0004) checks the merged PR against the team-mode or solo-mode path (§9.3). Any other merge, including a direct push, trips `halt-actions`.

**Solo maintainer.** See §9.3: in solo mode, time and evidence stand in for the second person.

### 9.3 Solo mode and team mode (resolves Q8)

GitHub doesn't let an author approve their own PR, and an adopter may have only one person, like this project. The mode comes from how many people are in the approvers team: **solo mode** with one, **team mode** with two or more. In solo mode, **time and evidence stand in for the second person.** This is weaker than a second reviewer. It protects against a rash change and a hijacked session, which gets 72 hours to be noticed, not against a determined owner. Each adopter accepts that knowingly by running in solo mode.

| Decision | Team mode | Solo mode |
|---|---|---|
| A plan, any environment | One approver who isn't the requester (the requester is the brain's App) | Same: one approver |
| A prod plan, or any plan using Run Command | Two approvers, from environments that share no reviewers | One approver. The plan must show the script's hash and the targets' current state |
| A guardrail change that **lowers** capability | A code owner's review | The owner merges once CI is green |
| A guardrail change that **raises** capability: a new exception, an EX-0003 entry, a higher `maxLevel` or limit | Two code owners | A **72-hour time-lock**: the required check `brain-guard/timelock` stays pending until 72 hours after the last commit. Plus the deterministic summary (§9.2), and a pinned issue for the whole window |
| An EX-0003 entry | The run record and the last kill-switch drill, checked by CI | Same, plus the time-lock |
| Resuming after the kill switch, prod | The `prod` environment's two required reviewers | The owner, after a 60-minute wait timer on the resume environment |

Branch protection in solo mode:
- PRs required (no direct pushes) and status checks required, including `brain-guard`;
- no required approval count, because GitHub can't count the owner's own review;
- no bypass.

`brain-guard` checks the rest itself:
- a PR authored by the brain's App needs the owner's approving review, read with read-only permissions;
- a PR that raises capability needs the time-lock.

The watchdog's "merged around the rules" trigger (§9.2 rule 5) accepts the solo path, and only that path.


### 9.4 Pseudonymization and model data (red-team H7)

- **Pseudonymize at collection.** The job and the orchestrator replace user principal names, user display names, client public IPs and client device names with keyed pseudonyms (`user-3fa2c1d0`), using HMAC-SHA256.
  - The key is a secret in the landing zone's Key Vault, generated at deployment and never shown to anyone (lesson 0002).
  - Every brain store, every issue and every model prompt holds pseudonyms only.
  - The brain keeps no mapping. To answer "who is `user-3fa2c1d0`?", an operator with access to the vault runs `Get-AvdPseudonym -UserPrincipalName <candidate>` in Cloud Shell, or queries Log Analytics, which keeps the raw data under its own access control.
- **Redact as well.** The redaction rules of decision 0008 (`report.js`, ported to PowerShell with the same fixtures) run after pseudonymization on anything bound for GitHub.
- **Where model calls go is an explicit choice:** `AVD_BRAIN_MODEL` = `none`, `anthropic-api`, `foundry-global` or `foundry-datazone`. The deployment prints who processes prompts.
  - For Claude, Anthropic is an independent data processor even when Claude runs in Foundry, and there is no EU data zone for Claude today ([data privacy](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/claude-models/data-privacy)).
  - The Tier 1 diagnosis through Claude Code in Actions is `anthropic-api`.
  - With `none`, Tier 1 and Tier 2 still work, and diagnosis is left to people.
- **Erasure (red-team M7).** Pseudonymized data is still personal data, so the brain has to be able to forget a person.
  - **One person:** an operator computes their pseudonym (`Get-AvdPseudonym`). `Remove-AvdBrainSubject` then scrubs it from the mutable stores (issue comments the brain wrote, Cosmos DB, the statistics file). Immutable evidence that still holds the pseudonym ages out within the 30-day window, and the script reports which blobs those are and when they unlock.
  - **Everyone at once:** the pseudonymization key **rotates every 12 months**, and the old key is deleted and purged from Key Vault. Pseudonyms made with it can then no longer be linked to anyone (crypto-shredding). An erasure request can also trigger an early rotation.
  - **Fixtures in Git** hold redacted placeholders only, never pseudonyms (decision 0008).
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
| **0b Image pipeline** (before phase 1; Q6) | A golden image built with Azure Image Builder or Packer into an Azure Compute Gallery, and host rotation onto new image versions. Specified separately, outside the brain | — | A host pool rebuilt from a gallery image passes the post-deployment preflight and a real sign-in |
| **1 Notice (Tier 1)** | Container Apps job, detections, episode issues, pseudonymization, the diagnosis workflow, digest, brain budget, kill switch and watchdog | 1 | A real incident appears as an issue with pseudonymized evidence, the changes before it and a cited diagnosis; a kill-switch drill passes; **a ranked list of signatures from at least 30 days of real data** (red-team S2) |
| **2 Approved fixes (Tier 2)** | Plans, `brain-execute.yml`, per-playbook identities and custom roles, hash-pinned scripts; the first playbooks taken **from the top of the ranked list**, not from §8 | 2 | 10 approved, verified runs per playbook in `test` (two or more hosts, fault-injection drills allowed) without rollback, which is EX-0003's entry criterion |
| **3 Memory and agents (Tier 3)** | Cosmos DB episodes and vector search, Foundry agents, orchestrator, eval harness with the offline mock | 2 | Diagnoses cite the right lesson or episode in ≥ 80% of eval cases |
| **4 Learn and self-heal** | Retro agent PRs, playbook statistics, rejection reasons, demotion, baselines; the first playbooks enter EX-0003 (test first, then prod) | 2S | A new signature reaches a lesson and guard drafted by the brain and merged by a person |
| **5 Evolve** | Drift, right-sizing and posture PRs, test-then-prod rollout with soak, each deployment started by a person | 3 (PR) | One drift and one sizing PR merged and deployed through test |

## 12. Risks

| Risk | Mitigation |
|---|---|
| An agent's confident wrong diagnosis reaches the approver | A person approves every plan; the Critic's dissent and the raw evidence sit beside it; preconditions are re-checked at run time; verification and the approved rollback; demotion on failure |
| Approval fatigue: people approve without reading | Plans readable in 30 seconds; duplicates merged before they reach a person; rejection needs a reason; approvals faster than a few seconds are flagged in the digest; the brain never re-asks to pressure an approval, and an expired plan stays expired |
| A needed fix waits because nobody approves | Expiry returns the episode to the inbox with the Cloud Shell block for manual action; in team mode, approver lists of at least two people per environment; on-call paging is optional (§5) |
| Alert storms flood episodes and token budgets | Triage merges by signature and scope; per-signature rate limits; token budget per day with a level-0 fallback |
| The brain itself fails silently | Heartbeat detection on the orchestrator and indexer; the scheduled preflight reports `brain-*` checks; the brain is watched by Azure Monitor, not by itself |
| Knowledge rot: lessons go stale as Azure changes | Each lesson gets a `last-verified` date; Retro flags lessons cited by failed playbooks; quarterly review issue |
| The mock is more permissive than Azure, so playbooks pass tests and fail for real | Lessons 0020 and 0021 apply; every real playbook failure updates `AzMock.psm1` |
| Cost creep | Tiers (§3.1); consumption meters where they exist; priced at deploy (decision 0010); the brain's own budget trips `halt-all` |
| One maintainer: the project stalls or the maintainer's account is compromised | One language; Tier 1 is the supported core and Tiers 2–3 are experimental until verified; adopters sync from attested release tags and see every upstream guardrail change through `brain-guard` (§3.2); upstream never ships active self-healing |
| Tenant data leaks to GitHub | Redaction with tests; private fork for org brains; evidence stays in Blob |

## 13. Open questions

- **Q1** ~~Which model per agent?~~ **Decided 2026-10-04:** Claude Opus 5.5 for every agent, with effort set per agent; cheaper models only where evals show quality holds (§4.4).
- **Q2** Approval surface: GitHub Environments are where Azure can enforce approval. Are Teams notifications that link to them enough?
- **Q3** ~~Retrieval?~~ **Decided:** the Git checkout at Tiers 1–2, Cosmos DB vector search at Tier 3, Azure AI Search only for large estates (red-team H9).
- **Q4** One brain per landing zone, or one per organization over several landing zones (the episode schema allows `environment` and `scope` to span them)?
- **Q5** Microsoft Entra Agent ID availability and roles in the target tenants, versus plain user-assigned managed identities.
- **Q6** ~~Image pipeline before or alongside phase 3?~~ **Decided 2026-10-04:** build the image pipeline **first**, before phase 1 (phase 0b). Replacing a host from a known image is the strongest fix the brain can offer, and a predictable fleet makes detections and baselines meaningful.
- **Q7** ~~Does the budget Lock wait for approval?~~ **Decided 2026-10-04:** no; it stays a pre-approved exception (EX-0001). More exceptions will follow through §4.5.1. EX-0002 (scheduled Stop) confirmed the same day, and self-healing became EX-0003.
- **Q8** ~~Who is the second approver?~~ **Decided 2026-10-04:** there may never be one for the project. Solo mode (§9.3) replaces the second person with a 72-hour time-lock and evidence; adopters with two or more approvers run team mode.
