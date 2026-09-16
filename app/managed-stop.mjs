'use strict';

// This is intentionally a declarative graceful-stop adapter, not an
// application command runner.  The authenticated native supervisor verifies
// this file's hash, runs it in a kill-on-close helper job with a restricted
// environment, then sends the actual Ctrl+Break only to its owned job.
if (process.argv.length !== 2) {
  process.stderr.write('managed-stop accepts no command-line arguments.\n');
  process.exitCode = 2;
} else {
  const instanceId = process.env.WORKSPACE_WIDGET_INSTANCE_ID || '';
  const itemId = process.env.WORKSPACE_WIDGET_ITEM_ID || '';
  const contractDigest = process.env.WORKSPACE_WIDGET_CONTRACT_DIGEST || '';
  if (!/^[0-9a-f]{32}$/i.test(instanceId) || !/^[0-9a-f]{64}$/i.test(itemId) ||
      !/^[A-Za-z0-9_:-]{1,256}$/.test(contractDigest)) {
    process.stderr.write('managed-stop context was not supplied by the lifecycle supervisor.\n');
    process.exitCode = 3;
  } else {
    process.stdout.write('{"action":"signal"}\n');
  }
}
