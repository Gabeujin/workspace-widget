# Local server lifecycle

Every server card uses the same lifecycle implementation with its configured
start target, stop target, arguments, working directory, and ordered loopback
health checks. No application name or fixed port selects a
different lifecycle implementation.

## User controls

The card starts a trusted local server on demand. Local-server context menus
always show separate **Start** and **Stop** actions; ordinary shortcuts show
neither. Availability of the Stop menu does not grant termination authority:
Stop refuses to terminate an instance whose ownership cannot be verified. It first
requests shutdown and waits up to 40 seconds so cooperating servers can drain
their child services. If the server remains running,
the user can confirm a force-stop. Cancellation leaves the service running.

**Exit Widget (servers keep running)** closes the launcher only. A later Widget
launch can reconnect to the surviving server supervisor. Closing the PC ends
these local processes; this feature does not register server auto-start.

An existing server launched by a pre-supervisor Widget release (0.1.4 or earlier)
or by another program is not adopted. Use its own shutdown procedure before
starting a new owned instance. Compatible retained supervisors from the managed
lifecycle implementation can be reconnected without adopting a port-discovered PID.
Editing a running card's start, stop or health contract also prevents automatic adoption of the
old instance. Preserve the original card configuration until that instance stops.

## Ownership and shutdown

One hidden native supervisor retains a Windows Job Object for each launch. The
configured root process is created suspended, assigned to that job, and then
resumed. Ordinary descendants remain in the job even if the wrapper exits.
Forced termination targets the retained job, never a PID discovered from a port.

Ownership evidence binds the item and instance, process creation time, executable
identity, command digest, and configured launch digest. Reconnection also checks
the live protected control pipe. Capability material is stored separately under
Windows user protection. Raw startup arguments are not copied into ownership
receipts. Each stop records its intent and result; an incomplete observation is
reported as a failure or unknown state, not a successful stop.

Startup output is not a control channel: server stdout/stderr are drained in
fixed-size buffers and cannot claim launch success. Within a bounded 15-second
startup window, the client matches authenticated ownership to the newly spawned
supervisor and confirms that exact instance over its protected control pipe.
Transient pipe readiness failures are retried within that same deadline; an
identity or contract mismatch fails closed. An unconfirmed launch is not blindly
started again or forcibly killed.

`commandSha256` authenticates the launch executable/arguments/working directory
recorded at creation. It is not a fresh operating-system command-line query and
does not prove the running application's current code or business state. The
live supervisor, creation identity, protected pipe, and retained Job Object
provide the lifecycle ownership boundary. Changing a source script on disk does
not turn this launch receipt into a code-integrity assertion.

Project-folder starts use only the package-local npm/pnpm runner through one
fixed `cmd.exe` launch grammar. Shell metacharacters in wrapper paths are rejected;
direct `.cmd` and `.bat` targets are rejected. The Widget UI accepts a Node entry
file, a PowerShell `.ps1` script, or a package script name, not arbitrary shell command text. The internal
native client is a trusted launch facility, not an API for untrusted callers.
The selected package script itself remains trusted application code.

The V2 contract binds all configured health endpoints and the explicit stop
helper. The helper is created suspended, assigned to its own bounded job before
resume, and limited to 4 KiB on each captured output stream. JavaScript helpers
use the authenticated package-local Node path and hash even when the server root
is npm's `cmd.exe` or PowerShell. This constrains lifecycle control and resource
use; it is not a sandbox for untrusted scripts. Only register code you trust.

A V1-owned running server cannot be silently adopted under a changed V2 digest.
Keep the original registration intact and stop that instance through its original
verified contract before migrating the registration. An unavailable or foreign
listener is never enough evidence to force termination.

Windows console applications can handle `SIGBREAK` (Node.js) to close listeners
and flush application work. Programs that ignore the request or launch a detached
console may require the explicit force fallback. Receiving a signal alone does
not prove application data has been flushed. A cooperative application can write
the exact `WORKSPACE_WIDGET_GRACEFUL_ACK_TOKEN` to
`WORKSPACE_WIDGET_GRACEFUL_ACK_PATH` after its cleanup. Only that acknowledgement,
an empty job, and an offline listener produce a `Graceful` receipt. An exit
without this acknowledgement is reported as `Stopped`, not a verified graceful
shutdown. The token is a local lifecycle marker, not an application credential.
Job containment is process management, not a sandbox for untrusted scripts or programs.

If a supervisor crashes, recovery does not adopt a running process. It requires
an authenticated record and independent absence checks for the recorded
supervisor identity, root identity, control pipe, and health-port listener. Only
then is the old instance terminalized with a recovery receipt. This uses the
kill-on-job-close contract plus absence evidence, not a query of a surviving job
handle. A foreign listener or uncertain observation keeps the stale instance
non-stoppable and blocks automatic restart. Active pointers and history are
preserved; cross-root ownership pointers are rejected. If the shortcut contract
changed after that old instance became fully absent, the same authenticated
absence proof terminalizes the stale contract before the new contract starts.
A live old instance, surviving pipe, occupied old health port, or occupied new
health port still fails closed and is never adopted or terminated by discovery.

The lifecycle files are located beside the selected Widget state directory in
`managed-services`. Keep that directory when updating the Widget. Older release folders
must remain available while their supervisors are running. The local upgrade
helper ignores supervisors when looking for a UI that needs to close and never
terminates them as part of installation.

The Windows PowerShell client uses .NET Framework file-path limits. The default
state location is supported. A custom state directory that would make ownership
history paths too long is rejected before a server starts; choose a shorter
`StatePath` in that case. Receipt filenames use unique IDs; their UTC timestamps
and prior-receipt digests are stored inside the JSON, and prior records are never
automatically pruned.

## Verification

Run `scripts/Test-WorkspaceWidgetManagedLifecycle.ps1` against the exact built
`WorkspaceWidget.exe` and its bundled `node.exe`. The harness uses unique state
directories, ephemeral ports, and test-only servers. It retains evidence and
does not contact application databases.

Use Windows PowerShell 5.1 (`powershell.exe`), not PowerShell 7 (`pwsh`), for this
harness: the managed client is compiled for the Widget's .NET Framework runtime.

The checks cover cooperative shutdown, timed-out shutdown and confirmed force,
fresh-client recovery, wrapper/child lifetime, crash recovery, cross-root and
mismatched ownership, a foreign listener, and the separation between tray Exit
and server Stop. The optional legacy-host fixture keeps the old supervisor
binary and uses the new client to query and stop it. These tests do
not certify Microsoft Store packaging or another application's shutdown logic.

Additional isolated suites check direct/project-folder startup, launch command
and path refusal, and the real lifecycle UI functions in a test WPF window.
The UI-function test is not a manual Windows tray-click or a complete desktop
installation test.

Windows API references:

- [Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
- [GenerateConsoleCtrlEvent](https://learn.microsoft.com/en-us/windows/console/generateconsolectrlevent)
- [Process creation flags](https://learn.microsoft.com/en-us/windows/win32/procthread/process-creation-flags)
