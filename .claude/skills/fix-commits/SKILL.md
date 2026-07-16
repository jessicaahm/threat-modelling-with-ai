---
name: fix-commits
description: Pre-commit readiness check — ensures the Vault Radar license file exists in .devcontainer; if missing, verifies Vault login and fetches the license from Vault (namespace admin, mount tmai, secret radar) without ever exposing the secret to AI context.
---

# Fix commits

Ensure the Vault Radar license file is in place so the pre-commit secret scan
can run (the hook fails closed and blocks the commit when the file is absent).

## Steps

1. Run the helper script from the repo root:

   ```bash
   ./script/validate-commits.sh
   ```

   The script does all license-file handling internally and prints status
   only — it never outputs the license value.

2. Interpret the exit code:
   - **0** — license file present (already existed, or was just fetched from
     Vault). Report that commits are ready and the Radar scan will run.
   - **2** — not logged in to Vault (or Vault unreachable), so the license
     cannot be fetched. **Stop the skill here.** Give the user the login
     command, tell them to re-run `/fix-commits` once they are logged in, and
     end the turn. Do not proceed to step 3, do not re-run the script hoping
     the state changed, and do not attempt any other route to the license —
     nothing further can succeed until they log in.

     They must run the login themselves via the **userpass** auth method
     (never type or ask for their password in chat — it would enter AI
     context). Tell them to type this in the prompt, where the `!` prefix
     runs it interactively in this session and Vault prompts for the password
     securely (no echo):

     ```
     ! VAULT_ADDR=https://vault-cluster-public-vault-289b32ee.99820ad2.z1.hashicorp.cloud:8200 VAULT_NAMESPACE=admin vault login -method=userpass username=<their-username>
     ```

     Substitute their actual Vault username for `<their-username>`. Use the
     `VAULT_ADDR`/`VAULT_NAMESPACE` values printed by the script if they
     differ. Remind them NOT to pass `password=...` on the command line (it
     would be captured in shell history and this session's output) — let
     Vault prompt for it.
   - **3** — logged in but the fetch failed (missing policy rights, wrong
     field name, empty secret). Relay the script's error message verbatim.
     A common cause is a userpass account that isn't bound to the `tmai`
     policy — the login succeeds but the token can't read `tmai/radar`.

3. Optionally confirm end-to-end by running `pre-commit run --all-files` and
   reporting whether the "Vault Radar scan" hook passed.

## Hard rules

- NEVER read, cat, echo, or otherwise display the license file or its
  contents — `.claude/settings.json` deny rules and a PreToolUse hook block
  this, and any Bash command mentioning the license filename will be denied.
  Interact with the file only through `./script/validate-commits.sh`.
- NEVER run `vault kv get` against the `tmai` mount directly; only the
  helper script may do that (it redirects the value straight to the file).
