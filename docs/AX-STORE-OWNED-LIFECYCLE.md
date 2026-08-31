# AX Store owned lifecycle

Workspace Widget may start and gracefully stop the local AX Store control and runtime servers, but only when the exact running instance was started by the packaged Widget lifecycle broker.

## Trust boundary

- AX Store is recognized only by the fixed `ax-store` shortcut identity, loopback ports `4520` and `4521`, and the trusted `workspace-widget-launcher.js` entry point.
- The bundled Node.js runtime starts a dedicated broker. The broker captures the process ID, creation time, executable, command line, broker, external launcher, and runtime-contract hashes.
- An ACL-protected per-instance directory contains a random capability, signed activation, signed ownership receipt, and append-only lifecycle events.
- A Widget restart recovers ownership only after the signature, ACL inheritance protection, PID/start time, file hashes, command line, both port owners, and exact health endpoints still match.
- Stop requests use a capability-authenticated named pipe, require a human reason and explicit impact acknowledgement, and call AX Store's exported graceful shutdown function. They never call `taskkill`, `Stop-Process`, or a generic shell command.
- A missing, stale, altered, externally started, partially stopped, or ambiguous instance fails closed as `STOP_DENIED_NOT_OWNER`. Workspace Widget does not kill it.

This is a current-user integrity boundary, not a sandbox against malware already
running as the same Windows user. The per-instance pipe name is unpredictable,
the capability is stored below a protected directory, requests are bounded and
authenticated, and remote clients cannot authorize a stop without that
capability. A same-user compromise can access the same local resources and must
be handled as a workstation-security incident.

## User experience

The AX Store card exposes one of three states in its context menu:

1. **Start AX Store** — no listener is present, so the trusted broker can start it.
2. **Stop AX Store…** — a fully verified Widget-owned instance is online.
3. **Running · not Widget-owned** — a process is using an AX Store port but cannot be proven as Widget-owned; stop is disabled.

The stop confirmation describes the affected control and runtime ports, requires a reason and acknowledgement, then reports success only when both listeners are closed and a signed completion receipt exists.

## Deliberate exclusions

- No LocalDock registration or Windows startup registration is created.
- AX Runtime Agent application targets are not reused for AX Store core lifecycle.
- PostgreSQL is not stopped.
- Enterprise Production remains a separate HOLD until its PKI, service-account, HA/DR, rotation, and independent review gates are satisfied.
