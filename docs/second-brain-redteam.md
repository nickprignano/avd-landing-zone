# Red-team review: second brain spec

- **Reviewed:** [second-brain-spec.md](second-brain-spec.md) as of 2026-10-04 (decision 0012, Proposed)
- **Method:** attack the trust boundaries, check each Azure claim against the docs, and look for places where two parts of the spec contradict each other or the repo's existing decisions. Every finding has a scenario and a proposed fix. Nothing here has been tried against a real tenant.

## Verdict

The core idea holds: the LLM proposes, tested code acts, Git is the policy store. But the spec **states that boundary more strongly than its own mechanics enforce it**. Four findings are critical, because each one lets model output, or an attacker's text, reach an action or a merged policy change. Two of the spec's Azure building blocks don't work the way it assumes. And the scope is too big for a one-maintainer personal project. Fix the critical findings in the spec before decision 0012 moves to Accepted, and cut phase 1 down (finding S1).

| Severity | Count |
|---|---|
| Critical: breaks the safety model | 4 |
| High: wrong about Azure, or harmful in a likely case | 9 |
| Medium: gaps and inconsistencies | 10 |
| Strategic | 2 |

## Critical

### C1. The model picks the playbook after all
**Where:** §4.4 Triage "produces ... known/unknown signature"; §12 "Signatures, not model judgment, select level 2 playbooks".
**Scenario:** Triage is an agent. If it can set or merge an episode's signature, then a hallucination, or a crafted string in a log or issue, turns an unknown failure into `wvd-agent-unhealthy:*`, and a level 2 playbook runs on its say-so.
**Fix:** signatures come only from the detection that fired (deterministic, in `brain/detections`). Agents may **lower** an episode's level, or ask for a human, but never set or change its signature. Merging episodes is a pure function of signature and scope.

### C2. Agents supply action parameters
**Where:** §4.4 `propose_playbook_run(playbook, version, parameters)` against §4.5 "parameters from episode fields, never free text from a model".
**Scenario:** the tool signature lets the model pass a `sessionHostId`. A prompt-injected log line names a host in another host pool, or a resource outside the landing zone. The executor has the roles to act on it.
**Fix:** the tool takes `episodeId` and `playbookId` only. The orchestrator binds the parameters from the episode, then resolves each target through Resource Graph and refuses any target outside the landing zone's resource groups. The runbook checks the scope again.

### C3. Public issues reach an agent that writes code
**Where:** §4.2 "`portal-report` issues ... enter as episodes"; §5 `brain-retro.yml` (Claude Code in Actions, OIDC to Azure).
**Scenario:** in the public repo, anyone can open an issue carrying the portal marker. The issue body is attacker text. The Retro agent reads it with write access to branches and an Azure token, and drafts a PR that changes `scripts/automation`, a workflow or a playbook's `maxLevel`. One tired approval merges it. This is the classic Actions injection path, with an LLM in the middle.
**Fix:**
- Portal reports from the public repo **never** become episodes in an organization's brain. They feed the public knowledge only through the existing human retro (decision 0008).
- Workflows triggered by issue or comment events get no Azure credentials and a read-only `GITHUB_TOKEN`. Agent PRs come from a separate, manually triggered or scheduled workflow.
- The brain refuses to post or read issues when the repository is public (it checks visibility through the API).

### C4. The brain can loosen its own guardrails
**Where:** §4.6 promotion "by a PR a person approves"; §4.7 Evolve opens PRs; §7 `brain/evals`, `brain/prompts`, `brain/playbooks/*maxLevel`.
**Scenario:** the Evolve or Retro agent authors the PR that raises a playbook's `maxLevel`, relaxes a limit, edits a prompt, or deletes the eval case it keeps failing. Then the eval gate passes. The human review that's meant to stop this is reviewing the brain's own argument for it.
**Fix:**
- A CI check fails any agent-authored PR (by author identity) that touches `maxLevel`, `limits`, `preconditions`, prompts, the guardrail code, workflows, role assignments, or deletes an eval.
- CODEOWNERS on those paths requires a named human, not the PR's requester.
- Evals are append-only; removing one is a human PR with a reason.

## High

### H1. Automation cloud jobs can't reach private endpoints
**Where:** §4.2 "scheduled preflight ... written to Blob"; §4.5 Automation playbooks read App Configuration; P5 "every data store private".
**Fact:** Automation cloud jobs can't reach resources secured with a private endpoint; that takes a Hybrid Runbook Worker ([Microsoft Learn](https://learn.microsoft.com/en-us/azure/automation/how-to/private-link-security)). The playbooks themselves are fine, since ARM is a public control plane. But writing evidence to private Blob and reading the kill switch from private App Configuration both fail.
**Fix:** runbooks touch ARM only. They return their state line in the job output. The VNet-integrated orchestrator collects it and writes it to Blob. The kill switch and levels reach the runbook as job parameters, checked against ARM tags on the host pool, which the runbook can read.

### H2. The scheduled preflight needs Az modules, which decision 0011 avoided on purpose
**Where:** §4.2 "Post-deployment preflight run on a schedule by Automation".
**Scenario:** `Test-AvdLandingZoneReadiness.ps1` is PowerShell 7 with Az modules (Cloud Shell). Automation's module versions are whatever the sandbox has, which is exactly why 0011 went module-free. Results would differ from Cloud Shell, and the portal contract would drift.
**Fix:** run the preflight in a Container Apps job (or a Functions PowerShell 7.4 worker) from a pinned image with pinned modules, VNet-integrated, so it can also write to the private stores.

### H3. The brain fights the scaling plan and the budget Lock
**Where:** §8 `recycle-empty-host` "drain, restart VM, undrain"; decision 0011.
**Scenario:**
- An admin drains a host on purpose; the brain recycles it and **undrains** it.
- The budget Lock deallocates hosts; the brain sees "host unavailable" and restarts one, breaking the Lock.
- The scaling plan ramps down a host as the brain restarts it.
**Fix:**
- Preconditions on every playbook: not `power-locked`, not carrying the scaling plan's exclusion tag, and not drained by anyone else.
- A playbook restores the drain state it found, never "undrain".
- Deallocated hosts are not "unhealthy". The detections exclude power state `deallocated`.

### H4. "No active sessions" is read from the component that's broken
**Where:** §6.3 precondition `noActiveSessions` for `restart-avd-agent`.
**Scenario:** when the agent is unhealthy, the session host's session count is stale or zero while users still have disconnected sessions. The brain treats the host as empty.
**Fix:** unknown means occupied. Require a fresh agent heartbeat **and** no `WVDConnections` activity for the host in the last N minutes. If either is missing, go to level 1.

### H5. Verification reads missing data as success
**Where:** §4.5 "the detection that must clear"; §6.3 `verify.within: PT15M`; P7.
**Scenario:** Log Analytics ingestion lags, and AVD tables can trail by many minutes. A detection with no fresh rows "clears". A host that never came back is recorded as `resolved-auto` and counts toward promotion.
**Fix:** verify by **positive** evidence: session host status `Available` with a `lastHeartBeat` after the action time (ARM), and a fresh agent health record. No positive evidence within the window means a failed verification.

### H6. The executor is SYSTEM on every session host
**Where:** §4.5 "Least privilege"; §8 Run Command playbooks; 0011 "runbook downloaded from GitHub at deployment time".
**Scenario:** Run Command write runs arbitrary code as SYSTEM. The executor's identity, and anyone who can change the runbook source (a merged PR, a compromised fork, the raw GitHub URL at deploy time), gets admin on every host and every user session on it. This is the most valuable identity in the design, and the spec treats it like the others.
**Fix:**
- A custom role scoped to the hosts resource group, with only the actions the playbooks use.
- The scripts each Run Command runs are fixed text in the runbook, not parameters.
- The runbook is pinned by content hash, not just by commit URL.
- Run Command use is alerted on in the Activity Log whenever the caller isn't the executor.
- Treat changes to `scripts/automation` as CODEOWNERS-protected (C4).

### H7. Claude through Foundry is not inside the Azure data boundary
**Where:** §5 "Foundry ... Hosts Claude and Azure OpenAI models"; §9 "Model data handling".
**Fact:** Anthropic stays an independent data processor for Claude in Foundry under either hosting option ([data privacy](https://learn.microsoft.com/en-us/azure/foundry/responsible-ai/claude-models/data-privacy), [hosting comparison](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/concepts/claude-models-hosting-comparison)). Reports say no EU data zone exists for Claude yet ([InfoQ](https://www.infoq.com/news/2026/07/claude-foundry-ga-europe/)). Sign-in logs and connection records carry UPNs and client IPs.
**Fix:**
- Pseudonymize at ingest: UPNs and client IPs become keyed hashes before anything is stored or sent to a model. The key lives in Key Vault, and only the Concierge, answering an authorized operator, may reverse them.
- Make the model's hosting option and data zone an explicit deployment parameter, with the processor named in the deploy output.

### H8. Tenant-wide Graph permissions for a landing-zone tool
**Where:** §4.2 "Intune managed device compliance, Entra sign-in logs".
**Scenario:** `DeviceManagementManagedDevices.Read.All` and audit or sign-in log access are tenant-wide application permissions. The landing zone's brain becomes a reader of the whole tenant's devices and sign-ins, which is far beyond the landing zone's scope (decision 0001, out-of-scope). Exporting sign-in logs to Log Analytics also needs Entra ID P1 or P2.
**Fix:**
- Drop Graph from phase 1.
- Host compliance comes from the hosts themselves (AMA, the Guest Configuration extension).
- If sign-ins are needed later, use a diagnostic setting the tenant admin owns, filtered in the DCR to the AVD apps, and say what it costs in licensing.

### H9. "Serverless" doesn't apply to AI Search, and the costs are always-on
**Where:** §12 "Serverless and consumption tiers"; §5 AI Search; P5.
**Facts the spec skips:**
- AI Search has no serverless tier. Private endpoints and shared private links for an indexer over private Cosmos DB need a billed tier that runs all month.
- Vector retrieval needs an embedding model deployment, which isn't in the service list.
- A private Foundry agent setup brings its own storage, search and Cosmos DB dependencies.

For a lab subscription with a budget Lock, the brain can become the largest fixed cost, and it counts toward the budget that locks the session hosts.
**Fix:**
- Price the minimal configuration through the retail price API before phase 1 (decision 0010).
- Start without AI Search: Cosmos DB vector search, or retrieval straight from the Git checkout (Q3, answered: start without it).
- Add the embedding model to §5.
- Give the brain's resource group its own budget.

## Medium

| # | Finding | Fix |
|---|---|---|
| M1 | **Contradiction:** §4.5 says prod's ceiling is level 2; §11 phase 3 says prod is level 1. | Phase 3: prod level 1. Raising it is a human PR after phase 4. |
| M2 | **Policy outside Git:** App Configuration holds `maxLevel` and limits, so they can be raised without review. That contradicts "Git is the only place policy lives". | Levels and limits deploy from Git. At runtime App Configuration can only **lower** them (kill switch). If it can't be read, the level is 0. |
| M3 | **Phase 3 exit can't be met:** dev has one host, and the blast-radius floor forbids taking it out. Ten real failures per playbook won't happen on their own either. | Phase 3 runs in `test` with two or more hosts. Verified runs come from **fault injection** (Azure Chaos Studio VM faults, stopping the agent service with Run Command) on a schedule, recorded as drills. |
| M4 | **Blast radius formula leaves no headroom:** `ceil(sessions / limit)` lets the brain take capacity down to exactly current demand during ramp-up. | Floor = current demand + one host, or the scaling plan's minimum percentage, whichever is higher. |
| M5 | **Promotion evidence is thin:** 10 clean runs still allows a failure rate up to about 30% (rule of three). | Keep 10 as a minimum, require drills plus real runs, and demote on the first rollback at the new level. |
| M6 | **Targets don't fit the timings:** "< 15 min to resolve" against 5-minute detection frequency, ingestion lag and a 15-minute verification window. | Measure from detection, set the first target at 30 minutes, and revise it with real data. |
| M7 | **Immutable evidence vs. deletion requests:** immutable Blob and 13-month episodes holding UPNs can't honor erasure, and lesson-pinned evidence is kept forever. | Pseudonymize first (H7). Store only pseudonymized evidence immutably. Pinned evidence must already be a redacted fixture. |
| M8 | **What-if is noisy:** nightly what-if over AVM templates reports changes that aren't real, and it needs the deployment's env vars and the break-glass input. Drift PRs become spam people learn to ignore. | Drift comes from Resource Graph changes not made by the deploy identity. What-if runs only on PRs. Known what-if noise is suppressed in a reviewed list. |
| M9 | **Soak in `test` proves nothing without users:** `test` has no traffic, so 24 hours of quiet is not evidence. And it shares the subscription budget with prod, so test spend can trigger prod's Lock. | Add a synthetic sign-in probe (the demo's sign-in validation, on a schedule). Note the shared-budget coupling, or give `test` its own subscription for the brain's phases. |
| M10 | **Stochastic CI gate:** LLM evals vary run to run, so "a drop fails CI" makes PRs flaky. Evals cost money, and fork PRs can't get secrets (a `pull_request_target` workaround would be dangerous). | Run each case k times and gate on the confidence bound. Evals run on maintainers' branches and on a schedule, never on fork PRs. |

## Strategic

### S1. Too big for the project that hosts it
The spec adds about a dozen services, a new language stack (Durable Functions plus an MCP server, neither of which is PowerShell), three new workflows, and a new kind of test, to a one-maintainer personal project. Its own guards (PSScriptAnalyzer, the offline harness, the portal contract) don't cover most of it. A large unowned surface is the likeliest way this fails, before any attacker shows up.

**Smallest version that proves the idea:**
1. A scheduled Container Apps job runs the preflight and writes the state line to Blob.
2. Existing alerts go to the existing action group, which opens a GitHub issue in a **private** repo.
3. Claude Code in Actions, on a schedule, read-only, writes a diagnosis comment citing the lessons.
4. The only automatic action stays the budget runbook.

That is phases 1 and 2, roughly level 1, with about four new resources. Add Cosmos DB, AI Search, Foundry and the orchestrator only when the episode count shows Git and issues can't keep up.

### S2. Measure before you heal
The spec has no baseline for how often each failure actually happens in this estate. Without one, the first playbooks are guesses. Phase 1 should end with a ranked signature list from real data. Phase 3's playbooks are the top of that list, not the table in §8.

## Status after the human-approval rule (2026-10-04)

The owner set a requirement: a person approves every change before it is made. The spec now has no autonomous level. The executor gets an Azure token only through an approved GitHub Environment job, and every run is bound to an approved plan hash (spec §4.5).

| Finding | Status | How |
|---|---|---|
| C1 Model picks the playbook | **Resolved in spec** | Only detections assign signatures, set once at episode open (§4.2); agents add hypotheses only; agent-classified plans always need approval of each run and are never EX-0003 |
| C2 Agents supply parameters | **Resolved in spec** | `propose_playbook_run(episodeId, playbookId)`; the orchestrator binds and scope-checks the targets; the approved plan hash is re-checked before running |
| C3 Public issues reach a code-writing agent | **Resolved in spec** | §9.1: no brain in a public repo; public portal reports aren't episodes; untrusted-event workflows hold no credentials; code-writing agents run only on schedule or dispatch, as a GitHub App limited to `brain/*` branches; provenance block; workflow linting in CI |
| C4 Brain loosens its own guardrails | **Resolved in spec** | §9.2: protected paths and fields; `brain-guard` fails agent-authored guardrail changes; CODEOWNERS with no bypass; a deterministic summary of each guardrail change; append-only evals; a merge around the rules trips EX-0004. Solo-maintainer limit is Q8 |
| H1 Automation can't reach private endpoints | **Resolved in spec** | Playbooks run in the approval-gated Actions job against ARM; state goes back through the run, not the private stores. The scheduled preflight is still H2 |
| H3 Fights the scaling plan and Lock | **Resolved in spec** | Preconditions: not locked, not excluded, drain state restored |
| H4 Session count from the broken agent | **Resolved in spec** | Unknown counts as occupied |
| H5 Missing data reads as success | **Resolved in spec** | Positive verification |
| H6 Executor is SYSTEM on hosts | **Open, required for EX-0003** | Per-run approval reduced it; EX-0003 gives a standing identity Run Command rights again. A fixed, content-hash-pinned script and a custom role are required before `restart-avd-agent` is active |
| M1 Prod level contradiction | **Resolved in spec** | One ladder, level 2 means approved |
| M2 Policy outside Git | **Resolved in spec** | App Configuration removed; the kill switch is an ARM tag that can only lower the levels deployed from Git, and an unreadable tag means stop (EX-0004) |
| M3 Phase 3 exit can't be met | **Resolved in spec** | Exit in `test` with two or more hosts and drills |
| M4 Blast radius has no headroom | **Resolved in spec** | Demand plus one host, or the scaling plan's minimum |
| M5 Thin promotion evidence | **Resolved in spec** | Entering EX-0003 needs 10 test runs plus 3 prod runs; the first rollback suspends the playbook |
| M6 Targets vs. timings | **Resolved in spec** | Split into time to plan and time from approval to verified fix |
| H2, H7, H8, H9, M7-M10, S1, S2 | Open | Not affected by the rule |

New risk introduced by the rule: **approval fatigue**, and fixes waiting on people. Both are in spec §12. The owner then decided that the budget Lock stays a **pre-approved exception**, and that more exceptions will follow (spec §4.5.1). That reopens C4 for a new path: exceptions are the one way around approval, so the CI rule that agents can't touch `brain/exceptions/`, together with CODEOWNERS, is now required, not optional. Self-healing then became exception EX-0003 (spec §4.5.1), which brings C1 and H6 back to full weight for the playbooks it lists. The kill switch became EX-0004 (spec §4.5.1). It is held in an ARM tag, which also settles the kill-switch half of H1, and it cuts the executors' federated credentials, so a stop doesn't depend on the brain's own code behaving.

All four critical findings are now resolved in the spec. The open findings are H2, H6 (required before `restart-avd-agent` enters EX-0003), H7, H8, H9, M7-M10, S1 and S2.

## Next step

Fold C1-C4, H1-H9 and S1 into the spec and the decision record. Then answer Q1, Q3 and Q6 with the data phase 1 produces.
