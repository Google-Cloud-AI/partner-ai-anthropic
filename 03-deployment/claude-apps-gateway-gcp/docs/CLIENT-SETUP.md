# Connecting developers

**A deployed gateway is not a usable gateway.** There is no option in the
`/login` picker that a developer can select manually — the gateway URL has to
arrive on their machine through managed settings first. This step is the most
common reason a working deployment appears broken.

## The managed settings snippet

Three keys go in the per-OS managed settings file, normally delivered by MDM:

```json
{
  "forceLoginMethod": "gateway",
  "forceLoginGatewayUrl": "https://claude-gateway.internal.example.com",
  "parentSettingsBehavior": "merge"
}
```

| Key | What it does |
|---|---|
| `forceLoginMethod` | Opens `/login` directly on the **Cloud gateway** screen. |
| `forceLoginGatewayUrl` | Pre-fills your gateway URL. Must equal `listen.public_url` exactly. |
| `parentSettingsBehavior: "merge"` | Lets Claude Desktop pass the gateway policy down to the Claude Code sessions it launches. Without it, desktop-launched sessions do not inherit the gateway. |

Terraform prints this ready to copy:

```bash
cd terraform && terraform output -raw managed_settings_snippet
```

## Where the file goes

| OS | Path |
|---|---|
| macOS | `/Library/Application Support/ClaudeCode/managed-settings.json` |
| Linux | `/etc/claude-code/managed-settings.json` |
| Windows | `C:\ProgramData\ClaudeCode\managed-settings.json` |

Deploy it with whatever you already use — Jamf, Intune, Workspace ONE, Ansible,
a configuration-management agent. Confirm the paths against the
[settings documentation](https://code.claude.com/docs/en/settings) for the
Claude Code version you are standardizing on.

## Certificate pinning

The CLI fingerprints the gateway's TLS leaf certificate on first connect and
pins it per hostname. **Publish the expected SHA-256 fingerprint alongside the
gateway URL**, so developers have something to compare the prompt against
instead of clicking through it:

```bash
openssl x509 -noout -fingerprint -sha256 -in cert.pem
```

The `/login` prompt shows the first 16 characters of the digest, lowercase hex,
no separators.

When the certificate rotates, **every developer sees the trust prompt again**.
Treat rotations as a planned, announced event and republish the fingerprint —
otherwise the one time it matters is indistinguishable from the routine case.

## What a developer experiences

1. Runs `/login`, lands on the **Cloud gateway** screen with the URL filled in.
2. Presses Enter; a browser opens to your IdP.
3. Signs in with their corporate account. The gateway checks the email domain
   against `allowed_email_domains`, mints a session JWT, and stores the session.
4. Back in the CLI, the model picker shows the models in their `availableModels`
   allowlist.

No claude.ai account, no API key, no subscription — inference runs on the
organization's upstream credential, held by the gateway.

Sessions refresh silently before `ttl_hours` expiry. After IdP deprovisioning
the refresh fails and the developer is prompted to sign in again, which is the
intended offboarding path.

## When sign-in fails

| Symptom | Likely cause |
|---|---|
| `/login` rejects the URL outright | The hostname resolves to a public address, or the corporate proxy host does. See [NETWORKING.md](NETWORKING.md). |
| Browser returns `redirect_uri_mismatch` | `<public_url>/oauth/callback` is not registered on the OAuth client, character for character. |
| Sign-in succeeds, then access is denied | The user's email domain is outside `allowed_email_domains`. |
| No **Cloud gateway** screen appears | Managed settings never landed. Verify the file exists at the path above and is valid JSON. |
