# Contributing

This is an **opinionated** landing zone: Entra ID-only, Intune-managed, private by default, greenfield. Contributions that harden or simplify that path are welcome. Contributions that add another identity model or brownfield options will usually be declined, because the [AVD LZA](https://github.com/Azure/avdaccelerator) already covers them and the narrow scope is the point (see [`docs/design-decisions.md`](docs/design-decisions.md)).

## Before you open a PR

Run the same checks CI runs ([`docs/ci.md`](docs/ci.md#running-the-checks-locally)):

```bash
az bicep lint --file bicep/main.bicep
AVD_USERS_GROUP_ID=x AVD_ADMINS_GROUP_ID=x AVD_SERVICE_PRINCIPAL_ID=x AVD_LOCAL_ADMIN_PASSWORD=Placeholder-1234 \
  az bicep build-params --file parameters/prod.bicepparam --stdout > /dev/null
pwsh -c "Invoke-ScriptAnalyzer -Path scripts/sessionhost -Recurse -Severity Warning,Error"
shellcheck scripts/deploy/deploy.sh
```

If your change touches resources, include `deploy.sh --what-if` output from a test subscription in the PR.

## Conventions

- **Pin AVM versions** (`br/public:avm/res/...:<version>`) and note version bumps in the PR. Use native resources only where AVM has no module or adds nothing.
- **One concern per module.** `main.bicep` stays readable; push complexity down.
- **Everything declarative.** Session host configuration belongs in `scripts/sessionhost/`, runs through Run Commands, and must be **idempotent** (it re-runs on every deployment). No post-deployment scripts, and no runtime downloads beyond Microsoft's agent links.
- **Windows PowerShell 5.1**: Run Commands use it, so avoid PowerShell 7-only syntax in `scripts/sessionhost/`.
- **Secure by default.** New resources get private endpoints where supported, diagnostics to Log Analytics, and least-privilege RBAC on Entra groups.
- **No tenant data in the repo.** Identity values and secrets come from environment variables.
- Every parameter gets an `@description`. Update `docs/` when behaviour changes.

## License

By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).
