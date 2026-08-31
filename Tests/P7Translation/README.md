# P7 Translation XPC checkpoint-one tests

`run-xpc-integration-tests.zsh` starts a loopback-only OpenAI-compatible fake server and runs the
hosted XPC integration tests plus short-policy network-operation tests. The fixture accepts only the
checkpoint-one minimal Chat Completions body and returns streaming, non-streaming, rate-limit,
early-EOF, heartbeat-only, idle-heartbeat, oversized-frame, timeout, and cancellable responses
without using a real API key or real document text. Production timeout constants remain fixed at
30/90/120 seconds; focused timeout tests inject shorter policies so CI does not wait minutes.

Run from the repository root:

```zsh
Tests/P7Translation/run-xpc-integration-tests.zsh
```

After building the `LurumeTranslationProbe` scheme in Release, verify that the signed, sandboxed,
network-less probe can stream through its Release XPC and record cold-start/idle-reclamation timing:

```zsh
Tests/P7Translation/run-release-probe.zsh
```
