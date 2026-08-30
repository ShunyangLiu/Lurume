# P6 local release script tests

`run-release-script-tests.zsh` exercises the non-networked validation shared by
`prepare-release` and `publish-release`. It verifies version/build inputs,
release-note identity, manifest hashes and path traversal rejection without
reading the production private key or changing GitHub state.

Run from the repository root:

```sh
Tests/P6Release/run-release-script-tests.zsh
```
