# P6 local release script tests

`run-release-script-tests.zsh` exercises the non-networked validation shared by
`prepare-release` and `publish-release`. It verifies version/build inputs,
release-note identity, manifest hashes and path traversal rejection without
reading the production private key or changing GitHub state.

It also locks three entitlement boundaries: the main App requires explicit
user-selected read-write access but rejects read-only residue, broad folders,
generic networking and debug access; Translation XPC and Zotero Import XPC each
require only sandbox plus outbound network client and reject file, Keychain,
Mach lookup, network server, device, personal-information and debug
permissions. Fixed P7/P8 fixture text, paths, keys, outputs and local fixture
endpoints are rejected from production executables.

Run from the repository root:

```sh
Tests/P6Release/run-release-script-tests.zsh
```
