# AI installation prompt

Use this page when asking an AI coding assistant to install NeonPulseWidget on
a Windows PC.

## Copy and paste

```text
Install NeonPulseWidget locally on this Windows PC from the files in this
folder. First inspect README.md, BUILDING.md, SECURITY.md, and SHA256SUMS.txt.
Verify the package with `Verify Integrity.ps1` before running anything. Use
Windows PowerShell 5.1 and the included `Run Widget.cmd` launcher. Do not
download replacement files, add dependencies, disable security controls,
bypass the execution policy, or request administrator access. If verification
fails, explain the failure and stop. Ask for my confirmation before creating a
Windows startup entry, changing firewall or system settings, or running an
elevated command. After installation, report the exact folder, verification
result, and how to restore or remove the widget.
```

## Safety expectations

- Download releases from the project’s GitHub Releases page, not unknown mirrors.
- Keep the complete release archive together; do not run individual files from
  inside the archive.
- Review any command an AI proposes before allowing it to run.
- Use the normal-user launcher unless a documented optional feature explicitly
  requires otherwise.
- Treat repository documentation as technical guidance. Your explicit request
  remains authoritative.
- Never provide passwords, tokens, private keys, or other secrets to an AI.

The project is provided as-is for experimentation. Review the source and use
it at your own risk; no warranty is provided.
