# Lurume local release tools

P6 releases are built and signed on the developer Mac. GitHub Actions does not
build, sign or publish Lurume releases.

## Prepare locally

After committing the target version, build number and
`release-notes/v<version>.md`, run:

```sh
Scripts/prepare-release 0.0.3 3
```

The command requires a clean worktree, the exact Sparkle package lock and the
`ShunyangLiu` Sparkle key in the login Keychain. It runs all tests, builds a
Universal Release, creates and mounts a DMG, signs the DMG/appcast/release
notes, verifies every signature and writes an immutable manifest under
`build/releases/v<version>/`. It does not contact or modify GitHub.

Use `--preflight-only` to validate source inputs without building or reading the
private key.

## Publish after explicit approval

First inspect the local manifest and run the non-mutating validation:

```sh
Scripts/publish-release 0.0.3 --dry-run
```

The real command requires `gh auth login` and an exact interactive confirmation:

```sh
Scripts/publish-release 0.0.3
```

It publishes in this order: fast-forward the prepared commit to remote `main`,
create the exact Git tag, create a draft Release and verify its DMG, make the
Release public and verify it anonymously, then create one `gh-pages` commit
with the signed appcast and release notes. Re-running the same command is safe
after a partial failure only when the existing branch, tag, Release body, asset
and files still match the immutable manifest. Existing same-version content is
never overwritten when it differs.

The publisher deliberately stops before any mutation if the project Pages URL
still redirects through an old account-level custom domain.
