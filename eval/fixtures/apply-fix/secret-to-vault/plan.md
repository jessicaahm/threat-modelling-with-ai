- **tag** — [blocking-this-diff]
- **suggestion** — Remove the hardcoded API_TOKEN literal from deploy.sh and load it from Vault via the existing fetch-deploy-token.sh helper instead.
- **location** — script/deploy.sh:6
- **why** — A hardcoded credential in a committed script is a leak. The repo already provides script/fetch-deploy-token.sh, which reads the token from Vault (kv-v2, mount tmai, secret eval-apply-fix) and exports $API_TOKEN. The secret value is seeded into Vault out-of-band (eval/seed-eval-vault.sh --seed-vault); the app must fetch it, not carry it.
- **approved plan**
  1. Delete the `API_TOKEN="ghp_..."` assignment on line 6 (secret leaves the source tree entirely).
  2. In its place, source the existing helper so $API_TOKEN is populated from Vault: `source "$(dirname "$0")/fetch-deploy-token.sh"`.
  3. No other changes — the `: "${API_TOKEN:?...}"` guard, the deploy() function, and the stdin-fed request all stay as-is.

The golden fix must confirm three things (the eval enforces them end-to-end):
  1. The secret lives in Vault (tmai/eval-apply-fix), not in the source.
  2. The application fetches it from Vault (via the sourced helper) at run time.
  3. The application still runs (exit 0) after the fix, with no secret in its output.
