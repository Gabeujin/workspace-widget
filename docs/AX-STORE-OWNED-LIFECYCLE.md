# AX Store owned lifecycle

Workspace Widget may start and gracefully stop the local AX Store control and runtime servers, but only when the exact running instance was started by the packaged Widget lifecycle broker.

## Trust boundary

- The local installer must receive the canonical AX Store launcher as an explicit absolute path. It issues an ACL-protected, HMAC-signed registration that pins the launcher path/hash, runtime-contract path/hash, exact versioned health URLs, and health-contract digest. User-editable shortcut state can select the reserved UI path but cannot authorize lifecycle operations.
- The bundled Node.js runtime starts a dedicated broker. The broker captures the process ID, creation time, executable, command line, broker, external launcher, and runtime-contract hashes.
- An ACL-protected per-instance directory contains a random capability, signed activation, signed ownership receipt, and append-only lifecycle events.
- The broker binds an unpredictable named pipe but does not launch AX Store until Windows PowerShell 5.1 verifies the broker PID, replaces the pipe DACL with exactly the current user, SYSTEM, and Administrators, and reads the descriptor back through a second connection. A signed challenge/attestation binds the DACL digest to ownership.
- A Widget restart recovers ownership only after signed registration, the exact process creation FILETIME, file hashes, command line, both port owners, health endpoints, and the live pipe DACL still match.
- Stop requests use a capability-authenticated named pipe, require a human reason and explicit impact acknowledgement, and call AX Store's exported graceful shutdown function. They never call `taskkill`, `Stop-Process`, or a generic shell command.
- A missing, stale, altered, externally started, partially stopped, or ambiguous instance fails closed as `STOP_DENIED_NOT_OWNER`. Workspace Widget does not kill it.

This is a current-user integrity boundary, not a sandbox against malware already
running as the same Windows user. The per-instance pipe name is unpredictable,
the capability and registration key are stored below protected directories,
requests are bounded and authenticated, and non-allowlisted Windows principals
cannot connect after pipe hardening. No AX Store process is launched when pipe
DACL setup or independent readback fails. Remote clients cannot authorize a stop without that
capability. A same-user compromise can access the same local resources and must
be handled as a workstation-security incident.

## User experience

The AX Store card exposes one of three states in its context menu:

1. **Start AX Store** — no listener is present, so the trusted broker can start it.
2. **Stop AX Store…** — a fully verified Widget-owned instance is online.
3. **Running · not Widget-owned** — a process is using an AX Store port but cannot be proven as Widget-owned; stop is disabled.
4. **AX Store lifecycle unavailable** — signed registration or pipe-DACL evidence is missing or stale; start and stop are disabled.

The stop confirmation describes the affected control and runtime ports, requires a reason and acknowledgement, then reports success only when both listeners are closed and a signed completion receipt exists.

## Deliberate exclusions

- No LocalDock registration or Windows startup registration is created.
- AX Runtime Agent application targets are not reused for AX Store core lifecycle.
- PostgreSQL is not stopped.
- Enterprise Production remains a separate HOLD until its PKI, service-account, HA/DR, rotation, and independent review gates are satisfied.
