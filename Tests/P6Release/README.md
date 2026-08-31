# P6 local release script tests

`run-release-script-tests.zsh` exercises the non-networked validation shared by
`prepare-release` and `publish-release`. It verifies version/build inputs,
release-note identity, manifest hashes and path traversal rejection without
reading the production private key or changing GitHub state.

It also locks the minimal Translation XPC entitlement policy: sandbox and
outbound network client are required, while file, Keychain, Mach lookup,
network server, device, personal-information and debug permissions are
rejected. Fixed P7 fixture text, fixture output, placeholder API Key and local
fixture endpoint are also rejected from production executables.

Run from the repository root:

```sh
Tests/P6Release/run-release-script-tests.zsh
```
