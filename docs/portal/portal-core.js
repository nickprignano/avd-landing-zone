/*
 * Deployment portal engine: reads pasted Cloud Shell output and decides the next step.
 *
 * Runs in the browser (window.PortalCore) and in Node (module.exports) so it can be tested
 * against real outputs (tests/portal). Nothing here touches the network.
 *
 * Input: whatever the operator pasted. The scripts end every run with a state line:
 *   <<<AVDLZ-STATE {json} AVDLZ-STATE>>>
 * (schema in docs/portal/README.md). Output from before state lines existed, and errors that
 * stop a script before it can print one, are recognised from their text.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.PortalCore = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  var STEPS = [
    { id: 'region', title: 'Choose a region' },
    { id: 'size', title: 'Size and cost' },
    { id: 'predeploy', title: 'Pre-deployment preflight' },
    { id: 'deploy', title: 'Deploy the landing zone' },
    { id: 'postdeploy', title: 'Post-deployment setup' },
    { id: 'signin', title: 'Sign in' }
  ];

  var DEFAULTS = {
    repoUrl: 'https://github.com/nickprignano/avd-landing-zone',
    parameterFile: 'parameters/dev.bicepparam',
    location: 'northcentralus',
    usersGroup: 'AVD Users',
    adminsGroup: 'AVD Admins',
    namePrefix: 'avdlz',
    environment: 'dev',
    testUserUpn: ''
  };

  // ---------------------------------------------------------------- helpers
  function psQuote(s) { return "'" + String(s).replace(/'/g, "''") + "'"; }
  function merge(a, b) {
    var o = {}, k;
    for (k in a) if (Object.prototype.hasOwnProperty.call(a, k)) o[k] = a[k];
    for (k in b || {}) if (Object.prototype.hasOwnProperty.call(b, k) && b[k] !== null && b[k] !== undefined && b[k] !== '') o[k] = b[k];
    return o;
  }
  function envFromFile(file) { var m = /parameters\/([a-z]+)\.bicepparam/.exec(file || ''); return m ? m[1] : null; }
  function repoDir(cfg) { return (cfg.repoUrl || DEFAULTS.repoUrl).replace(/\/+$/, '').split('/').pop(); }

  // ---------------------------------------------------------------- sizing (decision 0010)
  // Users per vCPU for Windows multi-session hosts, from Microsoft's session host sizing guidance.
  // Suggested sizes are memory-optimised E-series: with many users on one host, memory runs out
  // before CPU (8 GiB per vCPU, against 4 on D-series). Hosts use Premium SSD OS disks.
  var WORKLOADS = {
    light: { label: 'Light: a few line-of-business apps, data entry', usersPerVcpu: 6, suggestedSize: 'Standard_E4as_v5' },
    medium: { label: 'Medium: Office, web, email', usersPerVcpu: 4, suggestedSize: 'Standard_E8as_v5' },
    heavy: { label: 'Heavy: many apps at once, large files', usersPerVcpu: 2, suggestedSize: 'Standard_E8as_v5' },
    power: { label: 'Power: developers, analysts, light graphics', usersPerVcpu: 1, suggestedSize: 'Standard_E16as_v5' }
  };
  // Sizes suited to multi-session hosts (vCPUs, memory in GiB), memory-optimised first.
  var VM_SIZES = {
    Standard_E4as_v5: { vcpu: 4, ramGiB: 32, recommended: true }, Standard_E8as_v5: { vcpu: 8, ramGiB: 64, recommended: true }, Standard_E16as_v5: { vcpu: 16, ramGiB: 128, recommended: true },
    Standard_E4s_v5: { vcpu: 4, ramGiB: 32, recommended: true }, Standard_E8s_v5: { vcpu: 8, ramGiB: 64, recommended: true }, Standard_E16s_v5: { vcpu: 16, ramGiB: 128, recommended: true },
    Standard_D4as_v5: { vcpu: 4, ramGiB: 16 }, Standard_D8as_v5: { vcpu: 8, ramGiB: 32 }, Standard_D16as_v5: { vcpu: 16, ramGiB: 64 },
    Standard_D4s_v5: { vcpu: 4, ramGiB: 16 }, Standard_D8s_v5: { vcpu: 8, ramGiB: 32 }, Standard_D16s_v5: { vcpu: 16, ramGiB: 64 }
  };
  var OS_DISK = 'Premium SSD (P10, 128 GiB)';
  // spareHost: true / false, or null for automatic (a spare in prod).
  // One entry per host pool. The landing zone deploys one pooled host pool today; the list shape
  // leaves room for more (each would get its own sizing and, later, its own deployment).
  var HOST_POOL_DEFAULTS = { name: 'Pooled desktops', type: 'pooled', users: 50, concurrencyPercent: 80, workload: 'medium', vmSize: '', spareHost: null, profileGiBPerUser: 10, activeHoursPerWeek: 50 };
  var MAX_HOST_POOLS = 1;

  function num(v, d) { var n = Number(v); return isFinite(n) && n > 0 ? n : d; }

  // Sizing for one host pool: hosts, sessions per host, vCPUs to request quota for, profile share size.
  function computePool(spec, environment) {
    var p = merge(HOST_POOL_DEFAULTS, spec || {}), notes = [];
    var w = WORKLOADS[p.workload] || WORKLOADS.medium;
    var vmSize = p.vmSize || w.suggestedSize, vm = VM_SIZES[vmSize];
    if (!vm) { vmSize = w.suggestedSize; vm = VM_SIZES[vmSize]; notes.push('Unknown size; using ' + vmSize + '.'); }
    var users = Math.round(num(p.users, 1));
    var concurrent = Math.max(1, Math.ceil(users * Math.min(num(p.concurrencyPercent, 100), 100) / 100));
    var sessionsPerHost = Math.max(1, vm.vcpu * w.usersPerVcpu);
    var hosts = Math.ceil(concurrent / sessionsPerHost);
    var spare = p.spareHost === true || p.spareHost === 'true' || (environment === 'prod' && p.spareHost !== false && p.spareHost !== 'false');
    if (spare) { hosts += 1; notes.push('One spare host, so a host can be drained or fail without turning users away.'); }
    if (environment === 'prod' && hosts < 2) { hosts = 2; notes.push('At least two hosts in prod (the Well-Architected review flags one).'); }
    // Premium file shares are provisioned (minimum 100 GiB); 20% headroom over the expected profile sizes.
    var profileQuotaGiB = Math.max(100, Math.ceil(users * num(p.profileGiBPerUser, 10) * 1.2 / 100) * 100);
    // Too little memory per session: below 1 GiB on any size, below 1.5 GiB on a D-series (the
    // preflight applies the same rule).
    var ramPerSession = vm.ramGiB / sessionsPerHost, isE = /^Standard_E/.test(vmSize);
    if (ramPerSession < 1 || (ramPerSession < 1.5 && !isE))
      notes.push('Only ' + ramPerSession.toFixed(1) + ' GiB of memory per session. ' + (isE ? 'Use a larger E-series size.' : 'The memory-optimised ' + vmSize.replace(/^Standard_D/, 'Standard_E') + ' has twice the memory for the same vCPUs.'));
    return {
      name: p.name, workload: p.workload, users: users, concurrentUsers: concurrent, vmSize: vmSize, vcpuPerHost: vm.vcpu, ramGiBPerHost: vm.ramGiB,
      memoryPerSessionGiB: Math.round(ramPerSession * 10) / 10, osDisk: OS_DISK,
      sessionsPerHost: sessionsPerHost, hosts: hosts, vcpus: hosts * vm.vcpu, capacity: hosts * sessionsPerHost,
      profileQuotaGiB: profileQuotaGiB, activeHoursPerWeek: Math.min(168, Math.round(num(p.activeHoursPerWeek, 50))), notes: notes
    };
  }

  // What the commands pass: the sizing the portal computed, or the one a pasted preflight validated.
  function toSizing(r) { return { hosts: r.hosts, vmSize: r.vmSize, maxSessions: r.sessionsPerHost, profileQuotaGiB: r.profileQuotaGiB, activeHoursPerWeek: r.activeHoursPerWeek }; }
  function sized(cfg) { var s = cfg.sizing; return s && s.hosts && s.vmSize ? s : null; }

  // ---------------------------------------------------------------- commands
  // Every command is a self-contained Cloud Shell (PowerShell) block: sessions are ephemeral,
  // so each starts by cloning or updating the repo and moving into it (docs/lessons/0015).
  function preamble(cfg) {
    var dir = '~/' + repoDir(cfg);
    return [
      'if (-not (Test-Path ' + dir + ')) { git clone ' + cfg.repoUrl.replace(/\/+$/, '') + '.git ' + dir + ' }',
      'Set-Location ' + dir + '; git checkout -q master; git pull -q --ff-only'
    ].join('\n');
  }
  function block(cfg, lines) { return preamble(cfg) + '\n' + lines.join('\n'); }

  // Sizing flags, only once a sizing is set: the preflight validates and prices it, deploy.sh deploys it,
  // and the post-deployment preflight checks quota for it.
  var sizeArgs = {
    predeploy: function (cfg) { var s = sized(cfg); return s ? ' -SessionHostCount ' + s.hosts + ' -SessionHostVmSize ' + s.vmSize + ' -MaxSessionLimit ' + s.maxSessions + ' -ProfileShareQuotaGiB ' + s.profileQuotaGiB + (s.activeHoursPerWeek ? ' -ActiveHoursPerWeek ' + s.activeHoursPerWeek : '') : ''; },
    deploy: function (cfg) { var s = sized(cfg); return s ? ' --hosts ' + s.hosts + ' --vm-size ' + s.vmSize + ' --max-sessions ' + s.maxSessions + ' --profile-quota ' + s.profileQuotaGiB : ''; },
    postdeploy: function (cfg) { var s = sized(cfg); return s ? ' -SessionHostVmSize ' + s.vmSize + ' -SessionHostCount ' + s.hosts : ''; }
  };

  var cmd = {
    predeploy: function (cfg, fix) {
      return block(cfg, ['./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -PreDeployment -ParameterFile ' + cfg.parameterFile +
        ' -Location ' + cfg.location + ' -UsersGroup ' + psQuote(cfg.usersGroup) + ' -AdminsGroup ' + psQuote(cfg.adminsGroup) + sizeArgs.predeploy(cfg) + (fix ? ' -Fix' : '')]);
    },
    deploy: function (cfg) {
      return block(cfg, ['bash ./scripts/deploy/deploy.sh -p ' + cfg.parameterFile + ' -l ' + cfg.location +
        ' --users-group ' + psQuote(cfg.usersGroup) + ' --admins-group ' + psQuote(cfg.adminsGroup) + sizeArgs.deploy(cfg)]);
    },
    deployStatus: function (cfg, name) {
      var n = name ? psQuote(name) : "(az deployment sub list --query \"sort_by([?starts_with(name,'avdlz-')], &properties.timestamp)[-1].name\" -o tsv)";
      return [
        '$name = ' + n,
        'az deployment sub show -n $name --query "{name:name, state:properties.provisioningState, duration:properties.duration}" -o table',
        'az deployment operation sub list -n $name --query "[?properties.provisioningState==\'Failed\'].{resource:properties.targetResource.resourceName, error:properties.statusMessage.error.code}" -o table'
      ].join('\n');
    },
    postdeploy: function (cfg, fix) {
      return block(cfg, ['./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        sizeArgs.postdeploy(cfg) + (fix ? ' -Fix -AllowHostStart' : '')]);
    },
    wellArchitected: function (cfg) {
      return block(cfg, ['./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        ' -WellArchitected -SkipTenant -SkipNtfs']);
    },
    demo: function (cfg) {
      return block(cfg, ['./scripts/ops/Deploy-AvdDemo.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment +
        (cfg.testUserUpn ? ' -TestUserUpn ' + psQuote(cfg.testUserUpn) : '')]);
    },
    removeDemo: function (cfg) {
      return block(cfg, ['./scripts/ops/Remove-AvdDemo.ps1 -NamePrefix ' + cfg.namePrefix + ' -Environment ' + cfg.environment]);
    },
    // Quota increase through the Microsoft.Quota API; small requests are usually approved in minutes.
    quota: function (items) {
      var lines = [
        '$sub = (Get-AzContext).Subscription.Id',
        'Register-AzResourceProvider -ProviderNamespace Microsoft.Quota | Out-Null'
      ];
      items.forEach(function (q) {
        var limit = Math.max(q.limit || 0, (q.used || 0) + (q.needed || 0));
        lines.push(
          '# ' + q.quotaName + ' in ' + q.location + ': limit ' + q.limit + ', used ' + q.used + ', needed ' + q.needed + ' -> request ' + limit,
          "$body = @{ properties = @{ limit = @{ limitObjectType = 'LimitValue'; value = " + limit + " }; name = @{ value = '" + q.quotaName + "' } } } | ConvertTo-Json -Depth 5",
          '$r = Invoke-AzRestMethod -Method PUT -Payload $body -Path "/subscriptions/$sub/providers/Microsoft.Compute/locations/' + q.location +
            '/providers/Microsoft.Quota/quotas/' + q.quotaName + '?api-version=2023-02-01"',
          '"' + q.quotaName + ': HTTP $($r.StatusCode) $((($r.Content | ConvertFrom-Json).properties).provisioningState)"'
        );
      });
      lines.push('# A few minutes later, check the new limits:');
      items.forEach(function (q) {
        lines.push("Get-AzVMUsage -Location " + q.location + " | Where-Object { $_.Name.Value -eq '" + q.quotaName + "' } | Select-Object @{n='Quota';e={$_.Name.Value}}, CurrentValue, Limit");
      });
      return lines.join('\n');
    },
    graphReset: function (cfg, rerun) {
      return ['Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null'].concat(rerun ? [rerun] : []).join('\n');
    }
  };

  // ---------------------------------------------------------------- reading the paste
  function extractStates(text) {
    var states = [], re = /<<<AVDLZ-STATE([\s\S]*?)AVDLZ-STATE>>>/g, m;
    while ((m = re.exec(text))) {
      // A terminal copy can break the long line; JSON strings carry no raw newlines, so drop them.
      var raw = m[1].replace(/[\r\n]+/g, '').trim();
      try { states.push(JSON.parse(raw)); } catch (e) { states.push({ parseError: String(e && e.message || e), raw: raw.slice(0, 200) }); }
    }
    return states;
  }

  // ARM error codes that name a known cause.
  var ARM_ERRORS = [
    { code: 'LocationNotSupportAvailabilityZones', what: 'A resource was created with availability zones in a region that has none.',
      fix: 'Fixed in the template (docs/lessons/0001). Update the repo and deploy again; the next block does both.', action: 'redeploy' },
    { code: 'SkuNotAvailable', what: 'The VM size is not available in this region or zone for your subscription.',
      fix: 'Pick another size or region, then run the pre-deployment preflight, which checks sizes and zones.', action: 'predeploy' },
    { code: 'QuotaExceeded', what: 'Not enough vCPU quota.', fix: 'Run the pre-deployment preflight: it shows the quota and the portal builds the increase request.', action: 'predeploy' },
    { code: 'OperationNotAllowed', what: 'Usually a quota limit.', fix: 'Run the pre-deployment preflight: it checks quota and the portal builds the increase request.', action: 'predeploy' },
    { code: 'AuthorizationFailed', what: 'Your account lacks permission for part of the deployment.', fix: 'Deploy as Owner of the subscription (or Contributor + Role Based Access Control Administrator).', action: 'predeploy' },
    { code: 'VaultAlreadyExists', what: 'The Key Vault name is taken (often by a soft-deleted vault from an earlier deployment).', fix: 'Change namePrefix in the parameter file, or recover the vault with Undo-AzKeyVaultRemoval.', action: 'predeploy' },
    { code: 'InvalidTemplateDeployment', what: 'Azure rejected the template or parameters before deploying.', fix: 'Run the pre-deployment preflight; it compiles the parameter file and checks the region.', action: 'predeploy' },
    { code: 'ResourceGroupBeingDeleted', what: 'A landing zone resource group is still being deleted.', fix: 'Wait until the deletion finishes, then deploy again.', action: 'redeploy' },
    { code: 'RoleAssignmentExists', what: 'A role assignment already exists (usually harmless on a redeploy).', fix: 'Deploy again; the template is idempotent.', action: 'redeploy' }
  ];
  function armErrors(text) {
    var seen = {}, out = [];
    ARM_ERRORS.forEach(function (e) { if (text.indexOf(e.code) >= 0 && !seen[e.code]) { seen[e.code] = 1; out.push(e); } });
    return out;
  }
  function armCodes(text) {
    var codes = {}, re = /"code"\s*:\s*"([A-Za-z]+)"/g, m;
    while ((m = re.exec(text))) if (!/^(DeploymentFailed|ResourceDeploymentFailure|Failed)$/.test(m[1])) codes[m[1]] = 1;
    return Object.keys(codes);
  }

  // Output from before state lines existed (or cut off): infer what we can from the text.
  function inferFromText(text) {
    var failures = [], re = /\[FAIL \] (.+)\n(?:[ \t]{6,}(?!->)(.+)\n)?(?:[ \t]{6,}-> (.+))?/g, m;
    while ((m = re.exec(text + '\n'))) failures.push({ id: '', check: m[1].trim(), detail: (m[2] || '').trim(), remediation: (m[3] || '').trim() });
    var fix = /\(FIX mode\)/.test(text);
    var ready = /(^|\n)\s*Ready\.\s*(\n|$)/.test(text), notReady = /Not ready: \d+ failure/.test(text);
    if (/PRE-DEPLOYMENT preflight/.test(text) && (ready || notReady)) {
      // The clean run prints the deploy command: take the parameter file, region and groups from it.
      var ctx = {}, dm = /deploy\.sh -p (\S+) -l (\S+) --users-group '((?:[^']|'')*)' --admins-group '((?:[^']|'')*)'/.exec(text);
      var pf = /PRE-DEPLOYMENT preflight - (\S+\.bicepparam)/.exec(text);
      if (pf) ctx.parameterFile = pf[1];
      if (dm) { ctx.parameterFile = dm[1]; ctx.location = dm[2]; ctx.usersGroup = dm[3].replace(/''/g, "'"); ctx.adminsGroup = dm[4].replace(/''/g, "'"); }
      var pm = /prefix ([a-z0-9]+), env (dev|test|prod), ([a-z0-9]+),/.exec(text);
      if (pm) { ctx.namePrefix = pm[1]; ctx.environment = pm[2]; ctx.location = ctx.location || pm[3]; }
      return { v: 0, stage: 'predeploy', status: ready && !notReady ? 'ready' : 'notready', fix: fix, context: ctx, failures: failures, warnings: [] };
    }
    if (/AVD landing zone preflight - /.test(text) && (ready || notReady)) {
      var c = /preflight - ([a-z0-9]+)\/(dev|test|prod)/.exec(text);
      return { v: 0, stage: 'postdeploy', status: ready && !notReady ? 'ready' : 'notready', fix: fix, context: c ? { namePrefix: c[1], environment: c[2] } : {}, failures: failures, warnings: [] };
    }
    if (/==> Landing zone deployed\./.test(text)) {
      var s = /-NamePrefix ([a-z0-9]+) -Environment (dev|test|prod)/.exec(text);
      return { v: 0, stage: 'deploy', status: 'succeeded', context: s ? { namePrefix: s[1], environment: s[2] } : {} };
    }
    if (/"status"\s*:\s*"Failed"/.test(text) && /"code"\s*:\s*"DeploymentFailed"/.test(text)) return { v: 0, stage: 'deploy', status: 'failed', context: {} };
    var d = /==> Deploying \(([^)]+)\)/.exec(text);
    if (d) return { v: 0, stage: 'deploy', status: 'started', context: { deploymentName: d[1] } };
    return null;
  }

  // Errors that stop a command before our scripts can report anything.
  function shellProblems(text) {
    var p = [];
    if (/The term '\.\/scripts\/[^']+' is not recognized/.test(text) || /No such file or directory.*scripts\/deploy/.test(text))
      p.push({ id: 'not-in-repo', what: 'Cloud Shell was not in the repository folder (a new Cloud Shell session starts in your home folder).', fix: 'Every block below starts by moving into the repository.' });
    var pm = /A parameter cannot be found that matches parameter name '([^']+)'/.exec(text);
    if (pm) p.push({ id: 'bad-parameter', what: "The command had an unknown parameter '" + pm[1] + "' (often a stray keystroke when pasting).", fix: 'Copy the block again and paste it as-is.' });
    if (/DeviceCodeCredential authentication failed/.test(text))
      p.push({ id: 'graph-token', what: 'The Microsoft Graph sign-in could not get a token.', fix: 'Sign out of Graph and run the step again; it asks for a new device code.' });
    if (/Please run 'az login'|Run 'az login'|No subscription found|az account set/.test(text) && !/<<<AVDLZ-STATE/.test(text))
      p.push({ id: 'az-login', what: 'The Azure CLI is not signed in to the right subscription.', fix: 'Run: az account set --subscription "<your subscription>", then the step again.' });
    if (/To sign in, use a web browser to open the page https:\/\/(login\.)?microsoft\.com\/device/.test(text) && !/<<<AVDLZ-STATE/.test(text) && !/== Summary/.test(text))
      p.push({ id: 'device-code', what: 'The output stops at a device-code sign-in prompt.', fix: 'Open the link, enter the code, then wait for the script to finish before pasting the output.' });
    return p;
  }

  // Which of our commands the pasted output was running, read from the prompt line, e.g.
  // "PS /home/builder> ./scripts/ops/Test-AvdLandingZoneReadiness.ps1 -NamePrefix ... -Fix".
  // A redacted report (docs/portal/report.js) has "PS /home/<user-1>>".
  function commandInText(text) {
    var lines = text.split('\n'), i, m;
    for (i = lines.length - 1; i >= 0; i--) {
      m = /^PS (?:<[a-z]+-\d+>|[^>])*> (.*\b(Test-AvdLandingZoneReadiness|deploy\.sh|Deploy-AvdDemo|Remove-AvdDemo)\b.*)$/.exec(lines[i]);
      if (!m) continue;
      var c = m[1], fix = /\s-Fix\b/.test(c);
      if (/Test-AvdLandingZoneReadiness/.test(c)) return { step: /-PreDeployment\b/.test(c) ? 'predeploy' : 'postdeploy', fix: fix };
      if (/deploy\.sh/.test(c)) return { step: 'deploy', fix: false };
      if (/Deploy-AvdDemo/.test(c)) return { step: 'signin', fix: false };
      if (/Remove-AvdDemo/.test(c)) return { step: 'signin', removeDemo: true };
    }
    return null;
  }

  // ---------------------------------------------------------------- deciding the next step
  function hasFixable(items) { return items.some(function (f) { return /-Fix\b/.test(f.remediation || ''); }); }
  function byId(items, id) { return items.filter(function (f) { return f.id === id; }); }

  function decide(state, cfg, ctx) {
    var a = [], failures = state.failures || [], warnings = state.warnings || [], S = state.stage;
    var note = function (title, why, command) { a.push({ title: title, why: why, command: command || '' }); };

    if (S === 'predeploy') {
      if (state.status === 'ready') {
        note('Deploy the landing zone', 'The pre-deployment preflight is clean. Deployment takes 30-45 minutes and keeps running in Azure if Cloud Shell disconnects; paste its output here when it ends (or when you reconnect).', cmd.deploy(cfg));
        return { step: 'deploy', actions: a };
      }
      var quota = byId(failures, 'quota'), kv = byId(failures, 'kv-softdeleted'), hp = byId(failures, 'hostpool-region'), lzr = byId(failures, 'lz-region');
      var others = failures.filter(function (f) { return ['quota', 'kv-softdeleted', 'hostpool-region', 'lz-region'].indexOf(f.id) < 0; });
      var fixFirst = others.length > 0 && hasFixable(others) && !state.fix;
      var regionChange = false;
      if (fixFirst)
        note('Run the preflight again with -Fix', 'It creates the missing groups and service principal and registers providers and features, waiting until they finish.', cmd.predeploy(cfg, true));
      if (hp.length) {
        var regions = (hp[0].data && hp[0].data.regions) || [];
        var pick = (ctx.rankedRegions || []).filter(function (r) { return regions.indexOf(r) >= 0; })[0] || regions[0];
        if (pick) {
          regionChange = true;
          note('Choose a region that offers AVD host pools', cfg.location + ' does not offer AVD host pools. ' + (ctx.rankedRegions ? 'The closest one that does, by your latency test, is ' + pick + '.' : 'For example ' + pick + '; run the latency test in step 1 to pick the closest.'), cmd.predeploy(merge(cfg, { location: pick }), false));
        }
      }
      if (lzr.length) {
        var where = (lzr[0].data && lzr[0].data.deployedIn || [])[0];
        if (where) regionChange = true;
        note('Use the region the landing zone is already in', 'Resource groups cannot move region. Check against ' + where + ', or remove the existing landing zone first.', where ? cmd.predeploy(merge(cfg, { location: where }), false) : '');
      }
      if (quota.length)
        note('Request more vCPU quota', quota.map(function (q) { return q.check + ': ' + q.detail; }).join('; ') + '. Small increases are usually approved within minutes; if it goes to review, follow it in Portal > Quotas > My requests. Then run the preflight again.', cmd.quota(quota.map(function (q) { return q.data || {}; }).filter(function (d) { return d.quotaName; })));
      if (kv.length)
        note('Resolve the soft-deleted Key Vault', 'A deleted, purge-protected vault (' + ((kv[0].data && kv[0].data.vaults) || []).join(', ') + ') still holds the vault name for 90 days. Change namePrefix in ' + cfg.parameterFile + ', or recover it with Undo-AzKeyVaultRemoval.', '');
      if (others.length && !fixFirst)
        others.forEach(function (f) { note('Fix: ' + f.check, [f.detail, f.remediation].filter(Boolean).join(' '), ''); });
      // Close with a rerun unless an action above already reruns it (with -Fix or in another region).
      if (!fixFirst && !regionChange)
        note(a.length ? 'Then run the preflight again' : 'Run the preflight again', 'It should come back Ready.', cmd.predeploy(cfg, false));
      return { step: 'predeploy', actions: a };
    }

    if (S === 'deploy') {
      if (state.status === 'succeeded') {
        note('Run the post-deployment setup', 'The landing zone is deployed. This grants admin consent for the storage app, checks Conditional Access and sets the profile share permissions (starting the session host if needed). It asks for a Microsoft Graph device code.', cmd.postdeploy(cfg, true));
        return { step: 'postdeploy', actions: a };
      }
      if (state.status === 'whatif') {
        note('Deploy for real', 'The what-if ran. Deployment takes 30-45 minutes.', cmd.deploy(cfg));
        return { step: 'deploy', actions: a };
      }
      if (state.status === 'started') {
        note('Check on the deployment', 'The output ends while the deployment was running. It keeps running in Azure even if Cloud Shell disconnected. Run this and paste the result; when it shows Succeeded, the post-deployment setup is next. Do not start the deployment again while it runs.', cmd.deployStatus(cfg, state.context && state.context.deploymentName));
        return { step: 'deploy', actions: a };
      }
      var known = armErrors(ctx.text), codes = armCodes(ctx.text);
      if (known.length) {
        known.forEach(function (e) { note(e.code + ': ' + e.what, e.fix, e.action === 'redeploy' ? cmd.deploy(cfg) : cmd.predeploy(cfg, false)); });
      }
      else {
        note('Find out what failed', 'The deployment failed' + (codes.length ? ' (' + codes.join(', ') + ')' : '') + '. This lists the failed resources and their error codes; paste the result here.', cmd.deployStatus(cfg, state.context && state.context.deploymentName));
      }
      return { step: 'deploy', actions: a };
    }

    if (S === 'postdeploy') {
      var missing = byId(failures, 'lz-missing');
      if (missing.length) {
        var found = (missing[0].data && missing[0].data.found) || [];
        if (found.length) note('Check the landing zone that exists', 'No landing zone named ' + cfg.namePrefix + '-' + cfg.environment + ' in this subscription, but there is ' + found.map(function (f) { return f.namePrefix + '-' + f.environment; }).join(', ') + '.', cmd.postdeploy(merge(cfg, found[0]), false));
        else note('Deploy the landing zone first', 'Nothing is deployed under this name in this subscription. Start with the pre-deployment preflight (or switch subscription with Set-AzContext).', cmd.predeploy(cfg, false));
        return { step: found.length ? 'postdeploy' : 'predeploy', actions: a };
      }
      if (state.status === 'ready') {
        var waf = (state.warnings || []).filter(function (w) { return /^waf-/.test(w.id || ''); });
        if (state.context && state.context.wellArchitected) {
          var open = waf.filter(function (w) { return !(w.data && w.data.accepted); }), expected = waf.length - open.length;
          var pillars = {};
          open.forEach(function (w) { var p = (w.data && w.data.pillar) || 'Other'; pillars[p] = (pillars[p] || 0) + 1; });
          note(waf.length ? 'Review the Well-Architected findings' : 'Well-Architected: every check passes',
            waf.length ? (open.length ? 'To review: ' + ['Reliability', 'Security', 'Cost Optimization', 'Operational Excellence', 'Performance Efficiency', 'Other'].filter(function (p) { return pillars[p]; }).map(function (p) { return pillars[p] + ' ' + p; }).join(', ') + '.' : 'Nothing beyond the expected ones.') +
              (expected ? ' ' + expected + ' are trade-offs the ' + cfg.environment + ' parameter file makes on purpose; change them before production.' : '') + ' The findings are listed above; none of them blocks sign-in.'
              : 'Design checks, Azure Advisor, Defender for Cloud, Azure Policy and PSRule for Azure found nothing to review.', '');
        }
        note('Sign in to the desktop', 'Everything checks out. Open https://windows.cloud.microsoft (or the Windows App) as a member of ' + cfg.usersGroup + ' and open the desktop. New group members can take up to an hour to see it; a stopped host starts on the first connection.', '');
        note('Optional: validate sign-in end to end with a demo host pool', 'Deploys a separate demo host pool, checks the host and your test user, and tells you how to remove it.', cmd.demo(cfg));
        if (!(state.context && state.context.wellArchitected))
          note('Optional: Well-Architected review', 'Reviews the deployed landing zone by pillar (reliability, security, cost, operations, performance): design checks, Azure Advisor, Defender for Cloud, Azure Policy and PSRule for Azure. Findings are warnings; no Graph sign-in needed. A few minutes.', cmd.wellArchitected(cfg));
        return { step: 'signin', actions: a };
      }
      if (hasFixable(failures) && !state.fix) {
        note('Run the setup with -Fix', 'It applies the tenant steps (admin consent, Conditional Access exclusion, profile share permissions) and starts the session host if it is stopped.', cmd.postdeploy(cfg, true));
        return { step: 'postdeploy', actions: a };
      }
      failures.forEach(function (f) { note('Fix: ' + f.check, [f.detail, f.remediation].filter(Boolean).join(' '), ''); });
      note('Then run the check again', 'It should come back Ready.', cmd.postdeploy(cfg, false));
      return { step: 'postdeploy', actions: a };
    }

    if (S === 'demo') {
      if (state.status === 'ready') {
        note('Sign in to the demo desktop', 'Open https://windows.cloud.microsoft as ' + (cfg.testUserUpn || 'a member of ' + cfg.usersGroup) + ' and open the Desktop in the ' + ((state.context && state.context.workspace) || 'demo') + ' workspace.', '');
        note('Remove the demo when you are done', 'Removes the demo resource group and its device objects; the landing zone stays.', cmd.removeDemo(cfg));
      }
      else {
        failures.forEach(function (f) { note('Fix: ' + f.check, [f.detail, f.remediation].filter(Boolean).join(' '), ''); });
        note('Then run the demo validation again', '', cmd.demo(cfg));
      }
      return { step: 'signin', actions: a };
    }

    if (S === 'cleanup') {
      if (state.context && state.context.includeLandingZone) note('The landing zone is removed', 'To deploy again, start with the pre-deployment preflight. The Key Vault name stays reserved for 90 days: change namePrefix to reuse the subscription sooner.', cmd.predeploy(cfg, false));
      else note('The demo is removed', 'The landing zone is untouched.', '');
      return { step: state.context && state.context.includeLandingZone ? 'predeploy' : 'signin', actions: a };
    }
    return { step: null, actions: a };
  }

  var STAGE_LABEL = { predeploy: 'Pre-deployment preflight', deploy: 'Deployment', postdeploy: 'Post-deployment setup', demo: 'Demo validation', cleanup: 'Cleanup' };
  var STATUS_LABEL = { done: 'Done', ready: 'Ready', notready: 'Not ready', succeeded: 'Succeeded', failed: 'Failed', started: 'Still running (or disconnected)', whatif: 'What-if only' };

  /*
   * analyze(text, config, options) -> {
   *   recognised, stage, status, headline, source ('state' | 'text' | 'none'),
   *   problems [{what, fix}], failures [...], warnings [...],
   *   actions [{title, why, command}], step (next step id), config (updated with the run's context)
   * }
   * options.rankedRegions: regions ordered by measured latency, closest first.
   */
  function analyze(text, config, options) {
    text = String(text || '').replace(/\r\n/g, '\n');
    options = options || {};
    var cfg = merge(DEFAULTS, config);
    var states = extractStates(text).filter(function (s) { return !s.parseError; });
    var state = states.length ? states[states.length - 1] : inferFromText(text);
    var source = states.length ? 'state' : (state ? 'text' : 'none');
    var problems = shellProblems(text);

    if (state && state.context) cfg = merge(cfg, state.context);
    if (state && state.context && state.context.parameterFile && !state.context.environment) cfg.environment = envFromFile(state.context.parameterFile) || cfg.environment;

    var result = { recognised: !!state || problems.length > 0, source: source, problems: problems, config: cfg, failures: [], warnings: [], actions: [], stage: null, status: null, headline: '', step: options.currentStep || null,
      estimate: (state && state.context && state.context.estimate) || null, sizing: (state && state.context && state.context.sizing) || null };
    if (state) {
      var d = decide(state, cfg, { text: text, rankedRegions: options.rankedRegions });
      result.stage = state.stage; result.status = state.stage === 'cleanup' && state.status === 'ready' ? 'done' : state.status;
      result.failures = state.failures || []; result.warnings = state.warnings || [];
      result.actions = d.actions; result.step = d.step;
      result.headline = (STAGE_LABEL[state.stage] || state.stage) + ': ' + (STATUS_LABEL[result.status] || result.status) +
        (state.fix ? ' (fix mode)' : '') + (state.counts ? ' — ' + ['fail', 'warn', 'fixed', 'pass'].filter(function (k) { return state.counts[k]; }).map(function (k) { return state.counts[k] + ' ' + k; }).join(', ') : '');
    }
    // A shell problem means the step didn't really run: repeat the step we were on.
    if (problems.length && (!state || source === 'text' && !/Summary|deployed|Deploying/.test(text))) {
      // Repeat the command that was pasted (from its prompt line), else the step we were on.
      var ran = commandInText(text);
      var redo = ran && ran.removeDemo ? cmd.removeDemo(cfg) : rerunForStep(ran ? ran.step : (options.currentStep || 'predeploy'), cfg, ran ? ran.fix : undefined);
      if (ran && !state) result.step = ran.step;
      problems.forEach(function (p) {
        var command = p.id === 'graph-token' ? cmd.graphReset(cfg, redo) : (p.id === 'device-code' ? '' : redo);
        result.actions.unshift({ title: p.what, why: p.fix, command: command });
      });
      result.headline = result.headline || 'The step did not run to completion';
    }
    if (!result.recognised) {
      result.headline = 'No landing zone output found';
      result.actions = [{ title: 'Paste the whole output of the command', why: 'Include everything from the command to the prompt that follows it. The scripts end with a line starting <<<AVDLZ-STATE, which is what this page reads.', command: '' }];
    }
    return result;
  }

  function rerunForStep(step, cfg, fix) {
    switch (step) {
      case 'deploy': return cmd.deploy(cfg);
      case 'postdeploy': return cmd.postdeploy(cfg, fix === undefined ? true : fix);
      case 'signin': return cmd.demo(cfg);
      default: return cmd.predeploy(cfg, !!fix);
    }
  }

  // The first command for someone who has not run anything yet.
  function firstStep(config) {
    var cfg = merge(DEFAULTS, config);
    return { title: 'Run the pre-deployment preflight', why: 'Checks that the subscription and tenant are ready for the landing zone in ' + cfg.location + '. It asks for a Microsoft Graph device code. Paste its output here afterwards.', command: cmd.predeploy(cfg, false) };
  }

  // What to run at a given step when there is no pasted output to go on (e.g. picked in the tracker).
  function actionsForStep(step, config) {
    var cfg = merge(DEFAULTS, config);
    switch (step) {
      case 'region': return [{ title: 'Measure latency from where your users work', why: 'Run the test below from your users\' network (not over a VPN), then use the closest region. The preflight confirms the region offers AVD host pools.', command: '' }];
      case 'size': return [{ title: 'Size the host pool', why: 'Enter how many people will use it and how they work, below. The commands then check quota and availability for that size, and the pre-deployment preflight prices it for ' + cfg.location + ' at Azure list prices.', command: '' },
        firstStep(cfg)];
      case 'predeploy': return [firstStep(cfg)];
      case 'deploy': return [{ title: 'Deploy the landing zone', why: 'Run this once the pre-deployment preflight is Ready. It takes 30-45 minutes and keeps running in Azure if Cloud Shell disconnects.', command: cmd.deploy(cfg) },
        { title: 'Already started? Check on it', why: 'Shows the latest deployment and any failed resources.', command: cmd.deployStatus(cfg) }];
      case 'postdeploy': return [{ title: 'Run the post-deployment setup', why: 'Admin consent for the storage app, the Conditional Access exclusion and the profile share permissions. It asks for a Microsoft Graph device code.', command: cmd.postdeploy(cfg, true) }];
      case 'signin': return [{ title: 'Sign in to the desktop', why: 'Open https://windows.cloud.microsoft (or the Windows App) as a member of ' + cfg.usersGroup + '.', command: '' },
        { title: 'Optional: validate sign-in with a demo host pool', why: 'Deploys a separate demo host pool and checks the host and your test user.', command: cmd.demo(cfg) },
        { title: 'Optional: Well-Architected review', why: 'Reviews the deployed landing zone by pillar. Findings are warnings; no Graph sign-in needed.', command: cmd.wellArchitected(cfg) }];
      default: return [firstStep(cfg)];
    }
  }

  return { STEPS: STEPS, DEFAULTS: DEFAULTS, WORKLOADS: WORKLOADS, VM_SIZES: VM_SIZES, HOST_POOL_DEFAULTS: HOST_POOL_DEFAULTS, MAX_HOST_POOLS: MAX_HOST_POOLS, computePool: computePool, toSizing: toSizing, analyze: analyze, extractStates: extractStates, firstStep: firstStep, actionsForStep: actionsForStep, commands: cmd, psQuote: psQuote };
});
