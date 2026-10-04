# 0012. A second brain that heals by tested playbooks and evolves by pull request

- **Status:** Proposed

## Context
Decisions 0006 to 0011 built a learning loop that runs through people: a real run fails, the output is pasted, a lesson and a guard follow. The estate itself is not watched between runs, the same AVD failures (agent health, empty-host recycling, profile share headroom, drift) recur in every estate, and the knowledge to fix them already sits in this repo.

## Decision
Build the loop into the platform, as specified in [second-brain-spec.md](../second-brain-spec.md):
- Sense through Azure Monitor, Resource Graph and a scheduled preflight that writes the existing state line.
- Remember in Git (lessons, decisions, detections, playbooks: reviewed, the only place policy lives), Cosmos DB (episodes, tenant-specific) and Azure AI Search (retrieval with citations).
- Reason with agents in Microsoft Foundry that can only propose. Deterministic, offline-tested Automation runbooks act, within autonomy levels, guardrails and a kill switch, and every action is verified.
- Learn and evolve by pull request only: lessons and guards through the retro routine, drift and sizing through CI and the `test` environment. The brain never merges or deploys to prod.

## Consequences
- Known, reversible failures are fixed in minutes; unknown ones arrive with evidence instead of a guess.
- New surface to secure and pay for (an opt-in resource group, `AVD_BRAIN_ENABLED`), and a new kind of test: evals of the agents against redacted real episodes.
- Model data handling must be accepted by the organization before the Reason layer is enabled; the rest works without it.
