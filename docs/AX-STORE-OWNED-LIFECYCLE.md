# AX Store owned lifecycle

> Historical repository evidence only. This design is not loaded, installed,
> packaged, or supported by Workspace Widget 0.1.3 and later. Workspace Widget
> now uses one product-agnostic server shortcut contract and has no dependency
> on this product or its lifecycle protocol.

Workspace Widget 0.1.2 could start and gracefully stop the local AX Store control and runtime servers, but only when the exact running instance was started by the packaged Widget lifecycle broker. It also provided one narrowly scoped migration path for the pre-broker AX Store instance that could remain after an upgrade. It did not adopt that process as Widget-owned.

## Trust boundary

- The local installer must receive the canonical AX Store launcher and bundled Node.js runtime as explicit absolute paths. Registration schema v2 issues an ACL-protected, HMAC-signed document that pins the launcher, server entry point, runtime contract, bundled Node.js runtime, optional pre-broker Node.js runtime, current-user SID, exact versioned health URLs, and all corresponding SHA-256 digests. User-editable shortcut state can select the reserved UI path but cannot authorize lifecycle operations.
- The bundled Node.js runtime starts a dedicated broker. The broker captures the process ID, creation time, executable, command line, broker, external launcher, and runtime-contract hashes.
- An ACL-protected per-instance directory contains a random capability, signed activation, signed ownership receipt, and append-only lifecycle events.
- The broker binds an unpredictable named pipe but does not launch AX Store until Windows PowerShell 5.1 verifies the broker PID, replaces the pipe DACL with exactly the current user, SYSTEM, and Administrators, and reads the descriptor back through a second connection. A signed challenge/attestation binds the DACL digest to ownership.
- A Widget restart recovers ownership only after signed registration, the exact process creation FILETIME, file hashes, command line, both port owners, health endpoints, and the live pipe DACL still match.
- Stop requests use a capability-authenticated named pipe, require a human reason and explicit impact acknowledgement, and call AX Store's exported graceful shutdown function. They never call `taskkill`, `Stop-Process`, or a generic shell command.
- A missing, stale, altered, externally started, partially stopped, or ambiguous instance fails closed as `STOP_DENIED_NOT_OWNER`. Workspace Widget does not kill it.

### One-time pre-broker transition

The migration action is shown only when one PID exclusively owns both AX Store ports and every signed registration and live observation matches: canonical non-reparse executable/server/contract paths and hashes, exact two-argument command line, process creation FILETIME, current-user SID, both health identities, and the exact runtime-contract response digest. Any extra argument, split port ownership, PID reuse, hash drift, stale registration, different SID, failed health readback, or concurrent/replayed request disables the action.

The user must enter a reason and acknowledge both service impact and the exceptional process termination. Because the pre-broker process has no authenticated graceful IPC, the Widget does not send an unverified window or console signal. It atomically creates one deterministic signed claim for the registered legacy runtime identity, opens a native handle to the exact PID, verifies that handle's creation FILETIME, image, hash, and token SID against the baseline, re-reads the full process/port/command identity, and terminates only through that same verified handle. It never searches by port or name and never retries a different PID. The fixed claim blocks later attempts for the same runtime identity across Widget processes and Windows sessions. Success is reported only after that process is absent, both ports are closed, and an exclusive signed completion receipt records `STOPPED_FOR_MIGRATION`. An exception, partial close, or unknown result records `PARTIAL_OR_UNKNOWN` when a claim was issued and is never presented as success.

This is a current-user integrity boundary, not a sandbox against malware already
running as the same Windows user. The per-instance pipe name is unpredictable,
the capability and registration key are stored below protected directories,
requests are bounded and authenticated, and non-allowlisted Windows principals
cannot connect after pipe hardening. No AX Store process is launched when pipe
DACL setup or independent readback fails. Remote clients cannot authorize a stop without that
capability. A same-user compromise can access the same local resources and must
be handled as a workstation-security incident.

## User experience

The AX Store card exposes one of five states in its context menu:

1. **Start AX Store** — no listener is present, so the trusted broker can start it.
2. **Stop AX Store…** — a fully verified Widget-owned instance is online.
3. **Running · not Widget-owned** — a process is using an AX Store port but cannot be proven as Widget-owned; stop is disabled.
4. **Verify and stop outdated AX Store once…** — the exact signed pre-broker instance is a migration candidate; a second live verification and two acknowledgements are still required.
5. **AX Store lifecycle unavailable** — signed registration or pipe-DACL evidence is missing or stale; start and stop are disabled.

The stop confirmation describes the affected control and runtime ports, requires a reason and acknowledgement, then reports success only when both listeners are closed and a signed completion receipt exists.

## Deliberate exclusions

- No LocalDock registration or Windows startup registration is created.
- AX Runtime Agent application targets are not reused for AX Store core lifecycle.
- PostgreSQL is not stopped.
- The one-time migration path is not a generic process manager, port cleaner, ownership adoption mechanism, or application dependency.
- Enterprise Production remains a separate HOLD until its PKI, service-account, HA/DR, rotation, and independent review gates are satisfied.
