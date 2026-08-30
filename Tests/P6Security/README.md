# P6 signing security matrix

This directory contains deterministic, non-secret fixtures for Sparkle's P6
signing rejection tests. It never stores a private key, generated signature, or
signed release artifact in the repository.

Run with the production key in the login Keychain:

```sh
Tests/P6Security/run-signing-matrix.sh
```

For an isolated recovery rehearsal, mount the encrypted backup image and point
the test at its private-key file:

```sh
LURUME_SPARKLE_PRIVATE_KEY_FILE="/Volumes/Lurume Update Key Backup/sparkle-ed25519-private-key" \
  Tests/P6Security/run-signing-matrix.sh
```

`SPARKLE_BIN_DIR` may be supplied when the fixed Sparkle tools are not under
Xcode's normal DerivedData location. The default Keychain account is
`ShunyangLiu`; override it only for a deliberately isolated rehearsal by setting
`LURUME_SPARKLE_ACCOUNT`.

The script creates a private temporary directory, signs the archive, external
release notes, and appcast, verifies all three, then confirms that modifying any
one of them is rejected. It prints status only; signatures and private-key data
are not printed.

