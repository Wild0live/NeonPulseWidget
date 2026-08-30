# Security policy

## Supported versions

Security fixes are provided for the latest tagged release on the `main` branch.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting feature for this repository. Do not
include exploit details, credentials, or personal data in a public issue. If
private reporting is not enabled, open a short public issue asking the maintainer
for a private contact channel.

Include the affected version, Windows version, reproduction steps, and whether
the optional PawnIO CPU-temperature helper was enabled. The maintainer should
acknowledge a report within seven days and coordinate disclosure after a fix is
available.

## Trust boundaries

The normal launcher runs without administrator rights. CPU temperature is an
optional elevated path that depends on a separately installed signed PawnIO
driver. Review `SECURITY.txt`, `SECURITY-AUDIT.txt`, `SHA256SUMS.txt`, and
`dependencies.lock.json` before enabling it.
