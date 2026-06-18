# Contributing

This repo is a **baseline** — the non-negotiable floor of an AVD deployment, meant to be forked and made yours. That shapes how to contribute: most of the time you're not changing this repo, you're building *on top of* it. But improvements to the baseline itself are welcome.

## The mental model

There's a hard line in this project between **the floor** and **the engineering on top of it**:

- **The floor** (this repo): networking, identity wiring, storage, host pool, scaling — the parts that are the same in every deployment.
- **The engineering** (your fork): sizing, golden imaging, domain services, cost tuning, compliance, monitoring — the parts that depend on your org.

See [`docs/out-of-scope.md`](docs/out-of-scope.md) for the full boundary. Changes that pull org-specific engineering *into* the baseline will usually be declined — not because they're wrong, but because they belong in a fork. Keep the floor generic.

## Using this for your own deployment (the common case)

You don't need to contribute anything — just fork:

1. Fork or clone.
2. `cp parameters/dev.example.bicepparam parameters/dev.bicepparam` and edit for your tenant. Your real `.bicepparam` files are gitignored — keep them out of commits.
3. Change what you need in `bicep/modules/`. The wrappers are deliberately thin and readable.
4. Deploy per [`docs/deploy.md`](docs/deploy.md).

## Contributing back to the baseline

Good baseline contributions: clearer defaults, a missing guardrail that's truly universal, a fix to an AVM module wrapper, better docs, a real-world gotcha for [`docs/gotchas.md`](docs/gotchas.md).

### Before you open a PR

- **Lint and build the Bicep.** This must pass:
  ```bash
  az bicep build --file bicep/main.bicep --stdout > /dev/null
  ```
- **Run a what-if** against a test subscription if your change touches resources:
  ```bash
  ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -g rg-avd-lz-test -l eastus2 --what-if
  ```
- **Pin AVM versions explicitly.** Module references use `br/public:avm/res/...:<version>`. Don't float them — pin to a version you've built against, and note the version in your PR.
- **Keep `main.bicep` readable.** Each block is one non-negotiable. If a change makes the orchestration harder to follow, push the complexity down into a module.
- **No secrets, ever.** No passwords, tokens, or tenant IDs in committed files. The example parameter file uses placeholders for a reason.

### Conventions

- One concern per module in `bicep/modules/`; modules wrap AVM, they don't reimplement it.
- `az` drives infrastructure; PowerShell drives post-deploy config. Keep that split.
- Bicep parameters get `@description` decorators. Defaults should be lab-safe, not prod-assumptions.
- Update the relevant doc in `docs/` when behavior changes.

## Reporting issues

Open an issue with: what you ran, what you expected, what happened, and your `az` / Bicep / AVM module versions. If it's a deployment failure, the [`docs/gotchas.md`](docs/gotchas.md) list catches the four most common causes first — check there before filing.

## License

By contributing, you agree your contributions are licensed under the repo's [MIT License](LICENSE).
