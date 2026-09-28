// Tests for the deployment portal engine (docs/portal/portal-core.js) against real Cloud Shell
// output (fixtures/real-*.txt, redacted) and the scripts' state lines (fixtures/state-*.txt).
// Run: node --test tests/portal
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const P = require('../../docs/portal/portal-core.js');
const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url), 'utf8');
const analyze = (name, cfg = {}, opts = {}) => P.analyze(fixture(name), cfg, opts);
const last = (cmd) => cmd.trim().split('\n').pop();

// Every command must work in a fresh Cloud Shell session (docs/lessons/0015).
function assertSelfContained(r) {
  for (const a of r.actions.filter((x) => x.command && /scripts\//.test(x.command))) {
    assert.match(a.command, /git clone https:\/\/github\.com\/nickprignano\/avd-landing-zone\.git ~\/avd-landing-zone/, a.title);
    assert.match(a.command, /Set-Location ~\/avd-landing-zone/, a.title);
  }
}

test('real: pre-deployment not ready in check mode -> rerun with -Fix', () => {
  const r = analyze('real-predeploy-notready.txt');
  assert.equal(r.stage, 'predeploy');
  assert.equal(r.status, 'notready');
  assert.equal(r.source, 'text');
  assert.ok(r.failures.length >= 5);
  assert.match(last(r.actions[0].command), /-PreDeployment -ParameterFile parameters\/dev\.bicepparam -Location northcentralus .* -Fix$/);
  assertSelfContained(r);
});

test('real: pre-deployment ready -> deploy with the printed parameters', () => {
  const r = analyze('real-predeploy-ready.txt', { location: 'eastus2' });
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'deploy');
  assert.equal(last(r.actions[0].command), "bash ./scripts/deploy/deploy.sh -p parameters/dev.bicepparam -l northcentralus --users-group 'AVD Users' --admins-group 'AVD Admins'");
  assertSelfContained(r);
});

test('real: deployment failed on availability zones -> known cause, update and redeploy', () => {
  const r = analyze('real-deploy-failed-zones.txt');
  assert.equal(r.stage, 'deploy');
  assert.equal(r.status, 'failed');
  assert.match(r.actions[0].title, /LocationNotSupportAvailabilityZones/);
  assert.match(r.actions[0].command, /git pull/);
  assert.match(last(r.actions[0].command), /^bash \.\/scripts\/deploy\/deploy\.sh/);
});

test('real: deployment succeeded (older deploy.sh) -> post-deployment setup with -Fix', () => {
  const r = analyze('real-deploy-succeeded-old.txt');
  assert.equal(r.status, 'succeeded');
  assert.equal(r.step, 'postdeploy');
  assert.equal(last(r.actions[0].command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart');
});

test('real: post-deployment still failing after -Fix -> show the finding, then check again', () => {
  const r = analyze('real-postdeploy-notready-fixmode.txt');
  assert.equal(r.stage, 'postdeploy');
  assert.equal(r.status, 'notready');
  assert.match(r.actions[0].title, /Profile share root ACL/);
  assert.match(r.actions[0].why, /MissingRequiredHeader/);
  assert.equal(last(r.actions.at(-1).command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev');
});

test('real: post-deployment ready -> sign in', () => {
  const r = analyze('real-postdeploy-ready.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.match(r.actions[0].why, /windows\.cloud\.microsoft/);
});

test('real: script not found in a fresh session -> repeat the pasted command from the repo folder', () => {
  // The tracker says "sign in", but the paste shows the post-deployment preflight failed to start.
  const r = analyze('real-not-in-repo.txt', {}, { currentStep: 'signin' });
  assert.equal(r.step, 'postdeploy');
  assert.equal(r.problems[0].id, 'not-in-repo');
  assert.match(last(r.actions[0].command), /-NamePrefix avdlz -Environment dev -Fix -AllowHostStart$/);
  assertSelfContained(r);
});

test('real: stray parameter from a bad paste -> named and the step repeated', () => {
  const r = analyze('real-bad-parameter.txt', {}, { currentStep: 'postdeploy' });
  assert.equal(r.problems[0].id, 'bad-parameter');
  assert.match(r.actions[0].title, /'FixC'/);
  // The pasted command was the pre-deployment preflight; -FixC is not -Fix, so it reruns in check mode.
  assert.match(last(r.actions[0].command), /-PreDeployment .* -AdminsGroup 'AVD Admins'$/);
});

test('real: Graph token failure -> sign out of Graph and repeat', () => {
  const r = analyze('real-graph-token.txt', {}, { currentStep: 'predeploy' });
  assert.ok(r.problems.some((p) => p.id === 'graph-token'));
  const a = r.actions.find((x) => /Graph sign-in/.test(x.title));
  assert.match(a.command, /^Disconnect-MgGraph/);
});

test('state: pre-deployment not ready (fixable) -> -Fix', () => {
  const r = analyze('state-predeploy-notready-check.txt');
  assert.equal(r.source, 'state');
  assert.equal(r.status, 'notready');
  assert.match(last(r.actions[0].command), / -Fix$/);
  assert.equal(r.actions.length, 1);
});

test('state: quota and soft-deleted vault -> quota request with the right numbers, vault advice, rerun', () => {
  const r = analyze('state-predeploy-quota-kv.txt');
  const q = r.actions.find((a) => /quota/i.test(a.title));
  // limit 10, used 4, 16 needed -> request 20
  assert.match(q.command, /value = 20 }; name = @\{ value = 'standardDASv5Family' \}/);
  assert.match(q.command, /Microsoft\.Compute\/locations\/northcentralus\/providers\/Microsoft\.Quota\/quotas\/standardDASv5Family\?api-version=2023-02-01/);
  assert.ok(r.actions.some((a) => /soft-deleted Key Vault/.test(a.title)));
  assert.match(last(r.actions.at(-1).command), /-ParameterFile parameters\/prod\.bicepparam/);
});

test('state: a line broken by the terminal copy still parses', () => {
  const r = analyze('state-wrapped-by-terminal.txt');
  assert.equal(r.source, 'state');
  assert.ok(r.actions.some((a) => /quota/i.test(a.title)));
});

test('state: pre-deployment ready -> deploy', () => {
  const r = analyze('state-predeploy-ready.txt');
  assert.equal(r.step, 'deploy');
  assert.match(last(r.actions[0].command), /^bash \.\/scripts\/deploy\/deploy\.sh -p parameters\/dev\.bicepparam -l northcentralus/);
});

test('state: deployment started but output ends (disconnect) -> status check, not a second deployment', () => {
  const r = analyze('state-deploy-started-disconnected.txt');
  assert.equal(r.status, 'started');
  assert.match(r.actions[0].command, /az deployment sub show -n \$name/);
  assert.doesNotMatch(r.actions[0].command, /deploy\.sh/);
  assert.match(r.actions[0].why, /Do not start the deployment again/);
});

test('state: deployment failed -> the last state wins over "started"', () => {
  const r = analyze('state-deploy-failed.txt');
  assert.equal(r.status, 'failed');
});

test('state: deployment succeeded -> post-deployment setup for the deployed prefix', () => {
  const r = analyze('state-deploy-succeeded.txt', { namePrefix: 'other', environment: 'prod' });
  assert.equal(last(r.actions[0].command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -Fix -AllowHostStart');
});

test('state: post-deployment not ready in check mode -> -Fix -AllowHostStart', () => {
  const r = analyze('state-postdeploy-notready-check.txt');
  assert.match(last(r.actions[0].command), /-Fix -AllowHostStart$/);
});

test('state: no landing zone under this name -> check the one that exists', () => {
  const r = analyze('state-postdeploy-no-lz.txt');
  assert.match(last(r.actions[0].command), /-NamePrefix contoso -Environment prod$/);
});

test('state: post-deployment ready -> sign in, demo optional', () => {
  const r = analyze('state-postdeploy-ready.txt');
  assert.equal(r.step, 'signin');
  assert.match(last(r.actions[1].command), /^\.\/scripts\/ops\/Deploy-AvdDemo\.ps1 -NamePrefix avdlz -Environment dev$/);
});

test('state: demo ready -> sign in, then remove the demo', () => {
  const r = analyze('state-demo-ready.txt');
  assert.match(r.actions[0].why, /vdws-avdlz-dev-demo/);
  assert.match(last(r.actions[1].command), /Remove-AvdDemo\.ps1/);
});

test('state: landing zone removed -> done, pre-deployment to start again', () => {
  const r = analyze('state-cleanup-lz.txt');
  assert.equal(r.status, 'done');
  assert.match(r.actions[0].title, /landing zone is removed/);
});

test('host pool region not offered -> closest supported region from the latency test', () => {
  const state = { v: 1, stage: 'predeploy', status: 'notready', fix: false, context: { location: 'mexicocentral', parameterFile: 'parameters/dev.bicepparam' },
    failures: [{ id: 'hostpool-region', check: 'AVD host pools offered in mexicocentral', data: { location: 'mexicocentral', regions: ['eastus2', 'southcentralus', 'westus2'] } }], warnings: [] };
  const text = `<<<AVDLZ-STATE ${JSON.stringify(state)} AVDLZ-STATE>>>`;
  const r = P.analyze(text, {}, { rankedRegions: ['mexicocentral', 'southcentralus', 'eastus2'] });
  assert.match(last(r.actions[0].command), /-Location southcentralus /);
  assert.equal(r.actions.length, 1, 'no extra rerun in the old region');
});

test('nothing recognisable -> ask for the whole output', () => {
  const r = P.analyze('hello world');
  assert.equal(r.recognised, false);
  assert.match(r.actions[0].why, /AVDLZ-STATE/);
});

test('group names with apostrophes are quoted for PowerShell', () => {
  assert.equal(P.psQuote("O'Brien Users"), "'O''Brien Users'");
  const c = P.commands.deploy({ ...P.DEFAULTS, usersGroup: "O'Brien Users" });
  assert.match(c, /--users-group 'O''Brien Users'/);
});

test('the first step for a new user is the pre-deployment preflight in the chosen region', () => {
  const s = P.firstStep({ location: 'westus2', parameterFile: 'parameters/prod.bicepparam' });
  assert.match(last(s.command), /-PreDeployment -ParameterFile parameters\/prod\.bicepparam -Location westus2 /);
});

test('every step has a default action, and commands in it are self-contained', () => {
  for (const s of P.STEPS) {
    const actions = P.actionsForStep(s.id, { location: 'westus2' });
    assert.ok(actions.length > 0, s.id);
    assertSelfContained({ actions });
  }
  assert.match(last(P.actionsForStep('deploy', { location: 'westus2' })[0].command), / -l westus2 /);
});

// Drift guard: every parameter the portal puts in a command exists in the script it calls.
test('portal commands only use parameters the scripts define', () => {
  const repo = new URL('../../', import.meta.url);
  const psParams = (file) => {
    const src = readFileSync(new URL(file, repo), 'utf8');
    const block = src.slice(src.indexOf('param('), src.indexOf('\n)', src.indexOf('param(')));
    return new Set([...block.matchAll(/\]\s*\$(\w+)/g)].map((m) => m[1].toLowerCase()));
  };
  const shFlags = new Set([...readFileSync(new URL('scripts/deploy/deploy.sh', repo), 'utf8').matchAll(/^\s*(-{1,2}[a-z-]+)\)/gm)].map((m) => m[1]));
  const scripts = {
    'Test-AvdLandingZoneReadiness.ps1': psParams('scripts/ops/Test-AvdLandingZoneReadiness.ps1'),
    'Deploy-AvdDemo.ps1': psParams('scripts/ops/Deploy-AvdDemo.ps1'),
    'Remove-AvdDemo.ps1': psParams('scripts/ops/Remove-AvdDemo.ps1')
  };
  const cfg = { ...P.DEFAULTS, testUserUpn: 'alex@contoso.com' };
  const commands = [
    P.commands.predeploy(cfg, true), P.commands.predeploy(cfg, false), P.commands.postdeploy(cfg, true), P.commands.postdeploy(cfg, false),
    P.commands.demo(cfg), P.commands.removeDemo(cfg), P.commands.deploy(cfg), P.commands.wellArchitected(cfg)
  ];
  let checked = 0;
  for (const c of commands) {
    const line = last(c);
    const script = Object.keys(scripts).find((s) => line.includes(s));
    if (script) {
      for (const [, p] of line.matchAll(/\s-([A-Za-z]+)\b/g)) { assert.ok(scripts[script].has(p.toLowerCase()), `${script} has no -${p}`); checked++; }
    }
    else if (line.includes('deploy.sh')) {
      for (const [, f] of line.matchAll(/\s(-{1,2}[a-z-]+)\s/g)) { assert.ok(shFlags.has(f), `deploy.sh has no ${f}`); checked++; }
    }
  }
  assert.ok(checked >= 15, `checked ${checked} parameters`);
});

test('state: post-deployment ready -> offers the Well-Architected review', () => {
  const r = analyze('state-postdeploy-ready.txt');
  const w = r.actions.find((a) => /Well-Architected/.test(a.title));
  assert.ok(w, 'no Well-Architected action');
  assert.equal(last(w.command), './scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix avdlz -Environment dev -WellArchitected -SkipTenant -SkipNtfs');
  assertSelfContained(r);
});

test('state: Well-Architected review of a dev landing zone -> findings by pillar, expected ones counted, sign-in not blocked', () => {
  const r = analyze('state-postdeploy-waf.txt');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.equal(r.actions[0].title, 'Review the Well-Architected findings');
  assert.match(r.actions[0].why, /^To review: /);
  assert.match(r.actions[0].why, /7 are trade-offs the dev parameter file makes on purpose/);
  assert.ok(r.warnings.some((w) => w.id === 'waf-zones' && w.data.accepted));
  assert.ok(r.actions.some((a) => a.title === 'Sign in to the desktop'));
  assert.ok(!r.actions.some((a) => a.title === 'Optional: Well-Architected review'), 'offers the review it just ran');
});

test('state: Well-Architected review with nothing to review', () => {
  const r = analyze('state-postdeploy-waf-clean.txt');
  assert.equal(r.actions[0].title, 'Well-Architected: every check passes');
  assert.equal(r.warnings.length, 0);
});

test('real: first live Well-Architected review (dev, northcentralus) -> sign-in, 4 open findings, 6 expected', () => {
  const r = analyze('real-postdeploy-waf.txt');
  assert.equal(r.source, 'state');
  assert.equal(r.status, 'ready');
  assert.equal(r.step, 'signin');
  assert.equal(r.actions[0].title, 'Review the Well-Architected findings');
  assert.equal(r.actions[0].why.split('.')[0], 'To review: 1 Reliability, 1 Security, 2 Operational Excellence');
  assert.match(r.actions[0].why, /6 are trade-offs the dev parameter file makes on purpose/);
});
