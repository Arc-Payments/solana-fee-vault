# Pre-publish checklist

Run through this before the first public push. The goal is to publish only the
material you intend to share and keep private infrastructure, credentials,
local backups, and experiment files out of the repo.

## 1. Publish from a clean tree

If this directory was extracted from a larger private repository, make the
first public push from a clean checkout or export that contains only the files
you want to open-source. Review `git status` before the first commit and verify
every tracked file by name.

```bash
git init
git add .
git status                      # review every tracked file before the first push
git commit -m "Initial commit"
```

Then create the empty GitHub repo and push:

```bash
gh repo create <name> --public --source=. --remote=origin
git push -u origin main
```

If you prefer to keep developing in a larger private repo, publish from a clean
export rather than directly from a working tree that still contains private
code, backups, or local scratch files nearby.

## 2. Generate a fresh program ID

The checked-in `declare_id!` and `Anchor.toml` values are for this public
reference repo. Forks and real deployments should mint their own program ID and
sync it before building.

```bash
solana-keygen new --no-bip39-passphrase --outfile target/deploy/fee_vault-keypair.json
anchor keys sync
anchor build
```

Do **not** commit `target/deploy/fee_vault-keypair.json` — `.gitignore`
already excludes common keypair filenames, but verify with `git status` before
every push.

## 3. Rotate anything private you touched during extraction

If you copied or adapted code from a private app, assume any secret you handled
during the extraction process may need rotation in the private systems. That
usually includes:

- RPC or API keys
- backend tokens and webhook secrets
- sponsor or authority keypairs
- mobile app configs with embedded credentials
- CI or deployment secrets

Move secrets out of source files and into environment variables or a secret
manager in the private project. Keep local backups, exported key files, and
archive snapshots outside the public repo workspace.

## 4. Final scrub before push

In the public repo (after `git init`):

```bash
# Review the exact file set that will be public.
git ls-files

# Scan tracked files for obviously secret-looking material.
git ls-files | xargs rg -n -e 'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' \
                            -e 'sk_(live|test)_' \
                            -e '\b[A-Za-z0-9+/=]{40,}\b' || true

# Confirm what cargo and dart would package, in case you later publish them.
cargo package --list --manifest-path programs/fee_vault/Cargo.toml | head -20
( cd client-dart && dart pub publish --dry-run )

# Verify the test suites still pass on a clean machine.
anchor build
anchor test --skip-lint --skip-build
( cd client-dart && dart pub get && dart test )
```

The long-base64 regex is intentionally noisy and will flag some non-secret
values. Inspect each hit rather than blindly deleting matches.

## 5. Repository hygiene after push

- Set the GitHub repo description and topics.
- Enable Dependabot or equivalent dependency update tooling.
- Add a `CODEOWNERS` file for the program and tests if you want tighter review
  controls.
- Document which values are placeholders or devnet-only so forks do not
  accidentally reuse them in production.
