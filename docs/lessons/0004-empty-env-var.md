# 0004. `readEnvironmentVariable` returns an empty string, not the default, when the variable is set but empty

- **Area:** Bicep parameters
- **Found in / fixed by:** PR #8

## What happened
With `AVD_LOCATION` set to an empty value (for example an unset CI variable), `location` compiled to `''`.

## Why
`readEnvironmentVariable('X', 'default')` only falls back when X is unset.

## Fix
`empty(readEnvironmentVariable('AVD_LOCATION', '')) ? 'northcentralus' : readEnvironmentVariable('AVD_LOCATION', '')`.

## Guard
`tests/Template.Tests.ps1` (Region override).

## Rule
For optional environment variables in `.bicepparam`, guard with `empty(...)`, never rely on the second argument alone.
