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

## 4. FSLogix share permissions

The single most common reason profiles silently fail to load. Two layers, both required:

- **Share-level (RBAC):** session host users need *Storage File Data SMB Share Contributor* on the storage account.
- **NTFS:** set on the share itself — users need Modify on their own profile path.

Get either wrong and logins succeed but profiles don't roam, with no obvious error. The `Configure-FSLogix.ps1` script sets the *client* config; it assumes these permissions are already correct.

## 5. Region capacity for your VM size

Quota and *capacity* are different things. You can have quota and still get an allocation failure because the specific VM size isn't available in that region/zone right now. Have a fallback size (e.g. `Standard_D4as_v5` → `Standard_D4s_v5`) and don't hard-code one size everywhere.
