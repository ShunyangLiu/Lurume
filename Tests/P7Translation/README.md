# P7 Translation XPC checkpoint tests

`run-xpc-integration-tests.zsh` starts a loopback-only OpenAI-compatible fake server and runs the
hosted XPC integration tests plus short-policy network-operation tests. The fixture accepts only the
minimal Chat Completions body and returns streaming, non-streaming, rate-limit, hanging-error-body,
early-EOF, heartbeat-only, idle-heartbeat, oversized-frame, timeout, finite/looping redirect,
cancellable, and settings connection-test responses without using a real API key or real document
text. The connection-test fixture only accepts Lurume's fixed built-in test sentence. Production
timeout constants remain fixed at 30/90/120 seconds; focused timeout tests inject shorter policies
so CI does not wait minutes. The hosted XPC tests also exercise the service's connection-level code
signing requirement through a real embedded XPC launch. The checkpoint-three controller fixture
accepts only Lurume's system prompt and the normalized fixed selection `fixture selection only`, then
streams the result through the complete controller → embedded XPC → HTTP/SSE path.

Run from the repository root:

```zsh
Tests/P7Translation/run-xpc-integration-tests.zsh
```

After building the `LurumeTranslationProbe` scheme in Release, verify that the signed, sandboxed,
network-less probe can stream through its Release XPC and record cold-start/idle-reclamation timing:

```zsh
Tests/P7Translation/run-release-probe.zsh
```
