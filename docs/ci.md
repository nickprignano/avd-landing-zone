# CI / validation

The repo ships a GitHub Actions workflow at [`.github/workflows/validate.yml`](../.github/workflows/validate.yml) with two jobs: **lint** (always runs) and **what-if** (opt-in).

## Lint — runs automatically, no setup

On every PR that touches `bicep/`, `parameters/`, or the workflow itself, the lint job installs Bicep and runs:

```bash
az bicep build --file bicep/main.bicep --stdout > /dev/null
```

If the template doesn't transpile — including failures resolving the pinned AVM modules — the PR fails. This is your first gate and it needs nothing configured. It also runs on `workflow_dispatch` if you want to trigger it manually.

## What-if — opt-in, needs Azure access

The what-if job runs a `az deployment group what-if` against a test resource group so you can see what a PR *would* change before merging. It stays dormant until you set the repo variable `AZURE_WHATIF_ENABLED` to `true`, so a fresh fork won't fail on it.

It authenticates to Azure with **OIDC** (federated credentials) — no client secret is stored in the repo.

### 1. Create an app registration + service principal

```bash
az ad app create --display-name avd-lz-ci
# note the appId (this is AZURE_CLIENT_ID)
az ad sp create --id <appId>
```

Grant it Contributor on the subscription (or, better, just the test resource group):

```bash
az role assignment create \
  --assignee <appId> \
  --role Contributor \
  --scope /subscriptions/<sub-id>/resourceGroups/<test-rg>
```

### 2. Add a federated credential (this is what makes OIDC work)

Point the credential at your repo. The `subject` must match where the workflow runs — for PRs from branches in the same repo, use the `pull_request` subject:

```bash
az ad app federated-credential create \
  --id <appId> \
  --parameters '{
    "name": "avd-lz-ci-pr",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:nickprignano/avd-landing-zone:pull_request",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

> If you also want it to run on pushes to `main` (e.g. via `workflow_dispatch` on a branch), add a second credential with subject `repo:nickprignano/avd-landing-zone:ref:refs/heads/main`. OIDC subjects are exact-match — one per context.

### 3. Set the repo secrets and variables

**Secrets** (Settings → Secrets and variables → Actions → Secrets):

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | the app registration's `appId` |
| `AZURE_TENANT_ID` | your Entra tenant ID |
| `AZURE_SUBSCRIPTION_ID` | the target subscription ID |
| `SH_ADMIN_PW` | a throwaway password for the session-host admin param (what-if doesn't deploy, but the template requires the param) |

**Variables** (same screen → Variables):

| Variable | Value |
|----------|-------|
| `AZURE_WHATIF_ENABLED` | `true` |
| `AZURE_WHATIF_RG` | the test resource group name |

Once those are in place, open a PR touching `bicep/` and the what-if job will post the projected changes.

## Why OIDC and not a stored secret

OIDC uses a short-lived federated token minted per run — there's no client secret living in your repo secrets to leak or rotate. A service-principal JSON (`--sdk-auth`) is faster to stand up but stores a secret that expires (~1 year) and has to be rotated. For anything people might actually deploy from, OIDC is the better posture; that's why it's the default here.
