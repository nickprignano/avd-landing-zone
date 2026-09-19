# Gotchas — a taste of why it gets complicated

The baseline deploys cleanly. These are the things that bite once you point it at a real environment.

## 1. Resource providers not registered (fresh subscriptions)

On a brand-new subscription — exactly what you get swiping a personal card — the resource providers an AVD landing zone needs aren't registered yet, and the deployment fails with an opaque error. The deploy script registers them for you, but if you deploy by hand:

```bash
for ns in Microsoft.DesktopVirtualization Microsoft.Compute Microsoft.Storage Microsoft.Network Microsoft.Insights; do
  az provider register -n "$ns"
done
# Registration is async; the first run can take a few minutes.
az provider show -n Microsoft.DesktopVirtualization --query registrationState -o tsv
```

## 2. vCPU quota in your target region

The deployment fails fast if you don't have vCPU quota for your session-host VM size. **Brand-new subscriptions often start with very low quota** — this is the most likely thing to stop a personal-sub demo.

```bash
az vm list-usage --location eastus2 -o table | grep -i "standard d"
```

Request an increase early (portal → Subscriptions → Usage + quotas), or drop `sessionHostCount` to 1 and use a smaller size.

## 3. DNS propagation for private endpoints

A private endpoint gives storage a private IP. **Nothing resolves to it** until the private DNS zone is linked to the VNet *and* the link has propagated. The failure mode is cruel: the endpoint exists, but session hosts get **"access denied"** rather than a DNS error, so you go looking in the wrong place.

```bash
# From a session host, confirm the storage account resolves to a private (10.x) IP
nslookup <storageaccount>.file.core.windows.net
# If it returns a public IP, the DNS zone link hasn't taken effect yet.
```

## 4. FSLogix share permissions and Entra Kerberos

The single most common reason profiles silently fail to load. With Entra-ID-only
session hosts (this template's default) there are **three** layers, not two, and
only some of them are automated:

- **Identity source — Entra Kerberos.** An Entra-joined host has no AD DS to
  authenticate against, so the storage account is configured with
  `directoryServiceOptions: AADKERB` and the hosts get
  `CloudKerberosTicketRetrievalEnabled`. Both are handled for you (Bicep and
  `Configure-FSLogix.ps1` respectively). **The registry change needs a reboot.**
- **Admin consent — manual, once per storage account.** Enabling Entra Kerberos
  creates an app registration for the storage account, and it needs admin
  consent from a Global Administrator before any host can get a ticket:

  ```bash
  # Find the app registration created for the storage account, then consent
  az ad app list --display-name "[Storage Account] <your-storage-account-name>" --query "[].appId" -o tsv
  az ad app permission admin-consent --id <that-app-id>
  ```

  Skip this and mounting the share fails with a Kerberos error. This is the step
  people miss.
- **Share-level (RBAC):** session host users need *Storage File Data SMB Share
  Contributor*. The Bicep grants this to everything in `desktopUserObjectIds`.
- **NTFS:** set on the share itself — users need Modify on their own profile
  path. **Still manual.**

Get any of these wrong and logins succeed but profiles don't roam, with no
obvious error.

## 5. The scaling plan that never scales

A scaling plan runs as the **Azure Virtual Desktop service principal**, not as
you. If that principal has no power on/off rights over the session hosts, the
plan deploys clean, shows healthy in the portal, and never starts or stops
anything — the most expensive kind of silent failure in this template.

The deploy script resolves the service principal and the Bicep assigns
*Desktop Virtualization Power On Off Contributor* at the resource group scope.
If the lookup fails, the script warns and tells you to run:

```bash
az ad sp create --id 9cdead84-a844-4324-93f2-b2e6bb768d07
```

Note the assignment is at **resource group** scope here because the template is
resource-group scoped. Microsoft documents subscription scope; if you run
several host pools across a subscription, hoist it up yourself.

## 6. Sign-in fails on an Entra-joined session host

*Desktop Virtualization User* on the app group only makes the desktop **appear**
in the client. Actually signing in to the VM behind it needs **Virtual Machine
User Login**. Miss it and the connection is accepted and then the sign-in
fails — which looks like a credential problem and isn't. The Bicep assigns it at
resource group scope to everything in `desktopUserObjectIds`.

## 7. Region capacity for your VM size

Quota and *capacity* are different things. You can have quota and still get an allocation failure because the specific VM size isn't available in that region/zone right now. Have a fallback size (e.g. `Standard_D4as_v5` → `Standard_D4s_v5`) and don't hard-code one size everywhere.
