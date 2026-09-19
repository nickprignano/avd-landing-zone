// Copy this file to dev.bicepparam and fill in the values for YOUR tenant.
//   cp parameters/dev.example.bicepparam parameters/dev.bicepparam
// Everything you need to change for a basic deployment lives in this one file.

using '../bicep/main.bicep'

// ---- Core ----
param namePrefix = 'avdlz'                 // 2-10 chars; resource names derive from this
param location = 'eastus2'
param environment = 'dev'

// ---- Hub (LEAVE EMPTY for a standalone demo on a personal subscription) ----
// Standalone mode: no hub peering, default internet egress — clone-and-run works.
// To peer to an existing hub instead, put its VNet resource ID here.
param hubVnetResourceId = ''

// ---- Networking (defaults are fine for a lab; change for real ranges) ----
param spokeAddressPrefix = '10.20.0.0/24'
param sessionHostSubnetPrefix = '10.20.0.0/25'
param privateEndpointSubnetPrefix = '10.20.0.128/26'

// ---- Host pool ----
param sessionHostCount = 2
param sessionHostVmSize = 'Standard_D4as_v5'   // CHECK vCPU QUOTA in your region first

// Entra ID object IDs (users or groups) to grant desktop access. These get
// Desktop Virtualization User on the app group, Virtual Machine User Login on
// the session hosts, and SMB access to the FSLogix profile share.
param desktopUserObjectIds = [
  // '00000000-0000-0000-0000-000000000000'
]

// Must match what's in desktopUserObjectIds above. If you leave that list empty
// the deploy script grants the desktop to you and overrides this to 'User'.
param desktopUserPrincipalType = 'Group'

// Object ID of the "Azure Virtual Desktop" service principal in your tenant.
// Needed for the scaling plan to actually start/stop hosts. Leave empty --
// the deploy script resolves it for you.
param avdServicePrincipalObjectId = ''

// ---- Cost control (read docs/cost-controls.md before you deploy) ----
// Azure has NO hard spending cap on pay-as-you-go. These bound the damage.

// Daily hard stop for the session hosts. The only control here with no data
// lag, and the one that will actually save you money. Leave it on.
param enableAutoShutdown = true
param autoShutdownTime = '1900'                  // HHmm, 24-hour
param autoShutdownTimeZone = 'Eastern Standard Time'

// Budget + alerts + automated stop. A BACKSTOP: budget data lags real usage by
// 8-24 hours, so this fires late. It is not a cap.
param enableCostGuard = true
param monthlyBudgetAmount = 50                   // in your subscription's billing currency

// Where budget alerts go. Leave empty and the deploy script uses your signed-in
// address -- but on a personal subscription that address is often not
// deliverable, so setting a real inbox here is safer.
param costAlertEmails = [
  // 'you@example.com'
]

// ---- Session host local admin ----
param adminUsername = 'avdadmin'
// Do NOT commit a real password. Pass it at deploy time or use Key Vault.
// The deploy script will prompt for it if left empty.
param adminPassword = ''
