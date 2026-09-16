using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Net;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace WorkspaceWidget.Native
{
    // Generic, per-user lifecycle ownership for local services. This file deliberately
    // contains no product identifiers or application-specific shutdown behavior.
    public static class ManagedServiceClient
    {
        private const int ProtocolVersion = 2;
        private const int MaximumMessageBytes = 64 * 1024;
        private const int ConnectTimeoutMilliseconds = 3000;
        private const int StartupAuthenticationDeadlineMilliseconds = 15000;
        private const int StartupRecoveryDeadlineMilliseconds = 45000;
        private const int HealthProbeDeadlineMilliseconds = 1500;
        private const int MaximumSupervisorDiagnosticBytes = 4096;
        private static readonly JavaScriptSerializer Json = CreateSerializer();
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        public static string Start(
            string hostPath,
            string runtimeRoot,
            string itemId,
            string contractDigest,
            string executable,
            string arguments,
            string workingDirectory,
            string healthUrl,
            string pathValue)
        {
            return StartCore(hostPath, runtimeRoot, itemId, contractDigest, executable,
                arguments, workingDirectory, healthUrl, pathValue, 0);
        }

        // V2 deliberately keeps the v1 pipe protocol intact while binding its complete
        // health/stop configuration into the authenticated ownership record.
        public static string StartV2(
            string hostPath, string runtimeRoot, string itemId, string contractDigest,
            string executable, string arguments, string workingDirectory,
            string healthUrlsJson, string stopTarget, string stopArgs, string pathValue)
        {
            try
            {
                IList<Uri> healthUrls = RequireHealthUrls(healthUrlsJson);
                ValidateStopContract(stopTarget, stopArgs);
                string existing = Status(runtimeRoot, itemId, contractDigest, healthUrls[0].AbsoluteUri);
                Dictionary<string, object> existingResult = LifecycleJson.Parse(existing);
                string existingState = LifecycleJson.String(existingResult, "state");
                if (String.Equals(existingState, "Owned", StringComparison.Ordinal))
                {
                    RequireV2Binding(runtimeRoot, itemId, contractDigest, healthUrls, stopTarget,
                        stopArgs, true);
                    return StatusV2(runtimeRoot, itemId, contractDigest, healthUrlsJson);
                }
                if (!String.Equals(existingState, "Stopped", StringComparison.Ordinal))
                {
                    return WithV2HealthEvidence(existing, healthUrls);
                }
                if (!AreAllPortsOffline(healthUrls))
                {
                    return LifecycleJson.Result(false, "RunningUnowned", false, false, 0, 0,
                        null, null, "A configured v2 health port is already owned by another process.",
                        false, false);
                }
                string response = Start(hostPath, runtimeRoot, itemId, contractDigest, executable,
                    arguments, workingDirectory, healthUrls[0].AbsoluteUri, pathValue);
                Dictionary<string, object> result = LifecycleJson.Parse(response);
                if (!LifecycleJson.Boolean(result, "success") ||
                    !String.Equals(LifecycleJson.String(result, "state"), "Owned", StringComparison.Ordinal))
                {
                    return response;
                }
                LifecycleRecord record = RequireV2Binding(runtimeRoot, itemId, contractDigest,
                    healthUrls, stopTarget, stopArgs, true);
                if (!WaitForAllHealthy(healthUrls, StartupAuthenticationDeadlineMilliseconds))
                {
                    string degraded = LifecycleJson.Result(false, "OwnedDegraded", true, true,
                        LifecycleJson.Integer(result, "processId", 0),
                        LifecycleJson.Integer(result, "rootProcessId", 0),
                        LifecycleJson.String(result, "instanceId"),
                        LifecycleJson.String(result, "receiptPath"),
                        "The owned service did not make every configured health endpoint healthy.", false, false);
                    return WithV2HealthEvidence(degraded, healthUrls);
                }
                return WithV2HealthEvidence(response, healthUrls);
            }
            catch (Exception exception)
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                    null, null, exception.Message, false, false);
            }
        }

        public static Task<string> StartV2Async(string hostPath, string runtimeRoot,
            string itemId, string contractDigest, string executable, string arguments,
            string workingDirectory, string healthUrlsJson, string stopTarget, string stopArgs,
            string pathValue)
        {
            return Task.Factory.StartNew(delegate
            {
                return StartV2(hostPath, runtimeRoot, itemId, contractDigest, executable,
                    arguments, workingDirectory, healthUrlsJson, stopTarget, stopArgs, pathValue);
            });
        }

        public static string StatusV2(string runtimeRoot, string itemId, string contractDigest,
            string healthUrlsJson)
        {
            try
            {
                IList<Uri> healthUrls = RequireHealthUrls(healthUrlsJson);
                LifecycleRecord record;
                string ownershipError;
                string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
                string safeItem = LifecycleStorage.NormalizeItemId(itemId);
                if (LifecycleStorage.TryReadActive(safeRuntime, safeItem, out record, out ownershipError))
                {
                    LifecycleStorage.VerifyV2Configuration(record, healthUrls, null, null, false);
                }
                else if (!String.IsNullOrEmpty(ownershipError))
                {
                    throw new InvalidOperationException(ownershipError);
                }
                string response = Status(runtimeRoot, itemId, contractDigest, healthUrls[0].AbsoluteUri);
                Dictionary<string, object> result = LifecycleJson.Parse(response);
                bool allOnline = AreAllHealthy(healthUrls);
                bool allOffline = AreAllPortsOffline(healthUrls);
                result["allHealthOnline"] = allOnline;
                result["allHealthOffline"] = allOffline;
                if (!LifecycleJson.Boolean(result, "owned") &&
                    String.Equals(LifecycleJson.String(result, "state"), "Stopped", StringComparison.Ordinal) &&
                    !allOffline)
                {
                    result["state"] = "RunningUnowned";
                    result["success"] = false;
                    result["error"] = "A configured v2 health port is owned without an active lifecycle record.";
                }
                if (LifecycleJson.Boolean(result, "owned") && !allOnline)
                {
                    result["state"] = "OwnedDegraded";
                    result["success"] = false;
                    result["error"] = "The owned service does not satisfy every configured health endpoint.";
                }
                return Json.Serialize(result);
            }
            catch (Exception exception)
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                    null, null, exception.Message, false, false);
            }
        }

        public static Task<string> StatusV2Async(string runtimeRoot, string itemId,
            string contractDigest, string healthUrlsJson)
        {
            return Task.Factory.StartNew(delegate { return StatusV2(runtimeRoot, itemId, contractDigest, healthUrlsJson); });
        }

        public static Task<string> StopV2Async(string runtimeRoot, string itemId,
            string contractDigest, string healthUrlsJson, string stopTarget, string stopArgs,
            bool force, int gracefulTimeoutMs)
        {
            return Task.Factory.StartNew(delegate
            {
                return StopV2(runtimeRoot, itemId, contractDigest, healthUrlsJson, stopTarget,
                    stopArgs, force, gracefulTimeoutMs);
            });
        }

        public static string StopV2(string runtimeRoot, string itemId, string contractDigest,
            string healthUrlsJson, string stopTarget, string stopArgs, bool force,
            int gracefulTimeoutMs)
        {
            try
            {
                IList<Uri> healthUrls = RequireHealthUrls(healthUrlsJson);
                ValidateStopContract(stopTarget, stopArgs);
                string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
                string safeItem = LifecycleStorage.NormalizeItemId(itemId);
                LifecycleRecord activeRecord;
                string ownershipError;
                if (!LifecycleStorage.TryReadActive(safeRuntime, safeItem, out activeRecord, out ownershipError))
                {
                    bool allOffline = AreAllPortsOffline(healthUrls);
                    return LifecycleJson.Result(allOffline && String.IsNullOrEmpty(ownershipError),
                        allOffline ? "Stopped" : "RunningUnowned", false, false, 0, 0, null, null,
                        ownershipError ?? (allOffline ? null :
                            "A configured v2 health port is owned without a lifecycle record."),
                        allOffline, allOffline);
                }
                RequireV2Binding(runtimeRoot, itemId, contractDigest, healthUrls, stopTarget,
                    stopArgs, false);
                string status = Status(runtimeRoot, itemId, contractDigest, healthUrls[0].AbsoluteUri);
                Dictionary<string, object> statusResult = LifecycleJson.Parse(status);
                if (!LifecycleJson.Boolean(statusResult, "stoppable")) { return status; }

                // A force request is deliberately handled only by the authenticated
                // job boundary.  A helper is a graceful-action hook, never a second
                // force mechanism.
                if (!force)
                {
                    // The helper is allowed only after the existing authenticated ownership
                    // path has confirmed this exact record.  It receives no lifecycle capability.
                    string helperAction = RunStopHelper(stopTarget, stopArgs, runtimeRoot, itemId,
                        contractDigest, LifecycleJson.String(statusResult, "instanceId"), healthUrls,
                        gracefulTimeoutMs);
                    if (String.Equals(helperAction, "complete", StringComparison.Ordinal))
                    {
                        Stopwatch watch = Stopwatch.StartNew();
                        int bounded = Math.Max(1000, Math.Min(60000, gracefulTimeoutMs));
                        while (watch.ElapsedMilliseconds < bounded)
                        {
                            string current = Status(runtimeRoot, itemId, contractDigest, healthUrls[0].AbsoluteUri);
                            Dictionary<string, object> currentResult = LifecycleJson.Parse(current);
                            if (!LifecycleJson.Boolean(currentResult, "owned"))
                            {
                                return AreAllPortsOffline(healthUrls) ? WithV2HealthEvidence(current, healthUrls) : LifecycleJson.Result(false,
                                    "Partial", false, false, LifecycleJson.Integer(currentResult, "processId", 0),
                                    LifecycleJson.Integer(currentResult, "rootProcessId", 0),
                                    LifecycleJson.String(currentResult, "instanceId"), null,
                                    "The owned job stopped but a configured health port remains occupied.", true, false);
                            }
                            Thread.Sleep(100);
                        }
                        return LifecycleJson.Result(false, "NeedsForce", true, true,
                            LifecycleJson.Integer(statusResult, "processId", 0),
                            LifecycleJson.Integer(statusResult, "rootProcessId", 0),
                            LifecycleJson.String(statusResult, "instanceId"), null,
                            "The configured stop helper completed but the owned job remained active.", false, false);
                    }
                }
                string stopped = Stop(runtimeRoot, itemId, contractDigest, healthUrls[0].AbsoluteUri,
                    force, gracefulTimeoutMs);
                Dictionary<string, object> stoppedResult = LifecycleJson.Parse(stopped);
                if (LifecycleJson.Boolean(stoppedResult, "success") && !AreAllPortsOffline(healthUrls))
                {
                    return LifecycleJson.Result(false, "Partial", false, false,
                        LifecycleJson.Integer(stoppedResult, "processId", 0),
                        LifecycleJson.Integer(stoppedResult, "rootProcessId", 0),
                        LifecycleJson.String(stoppedResult, "instanceId"),
                        LifecycleJson.String(stoppedResult, "receiptPath"),
                        "The owned job stopped but a configured health port remains occupied.", true, false);
                }
                return WithV2HealthEvidence(stopped, healthUrls);
            }
            catch (Exception exception)
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                    null, null, exception.Message, false, false);
            }
        }

        private static IList<Uri> RequireHealthUrls(string healthUrlsJson)
        {
            if (String.IsNullOrWhiteSpace(healthUrlsJson) ||
                Encoding.UTF8.GetByteCount(healthUrlsJson) > 8192)
            {
                throw new ArgumentException("healthUrlsJson is invalid.");
            }
            object decoded = Json.DeserializeObject(healthUrlsJson);
            object[] values = decoded as object[];
            if (values == null || values.Length < 1 || values.Length > 16)
            {
                throw new ArgumentException("healthUrlsJson must contain between one and sixteen health URLs.");
            }
            List<Uri> urls = new List<Uri>();
            HashSet<string> unique = new HashSet<string>(StringComparer.Ordinal);
            foreach (object value in values)
            {
                string text = value as string;
                Uri uri = LifecycleStorage.RequireLoopbackHealthUrl(text);
                if (!unique.Add(uri.AbsoluteUri))
                {
                    throw new ArgumentException("healthUrlsJson contains a duplicate health URL.");
                }
                urls.Add(uri);
            }
            return urls;
        }

        private static void ValidateStopContract(string stopTarget, string stopArgs)
        {
            if (String.Equals(stopTarget, "@managed-signal", StringComparison.Ordinal))
            {
                if (!String.IsNullOrEmpty(stopArgs))
                {
                    throw new ArgumentException("The managed-signal stop action does not accept arguments.");
                }
                return;
            }
            string target = LifecycleStorage.RequireFile(stopTarget, "stopTarget");
            string extension = Path.GetExtension(target);
            if (!String.Equals(extension, ".js", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(extension, ".mjs", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(extension, ".cjs", StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(extension, ".ps1", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("stopTarget must be a local Node or PowerShell script, or @managed-signal.");
            }
            string args = stopArgs ?? String.Empty;
            if (args.Length > 2048 || args.IndexOf('\0') >= 0 || args.IndexOf('\r') >= 0 ||
                args.IndexOf('\n') >= 0)
            {
                throw new ArgumentException("stopArgs contain unsupported characters or exceed 2,048 characters.");
            }
        }

        private static LifecycleRecord RequireV2Binding(string runtimeRoot, string itemId,
            string contractDigest, IList<Uri> healthUrls, string stopTarget, string stopArgs,
            bool allowInitialBind)
        {
            string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
            string safeItem = LifecycleStorage.NormalizeItemId(itemId);
            string safeContract = LifecycleStorage.RequireDigest(contractDigest, "contractDigest");
            LifecycleRecord record;
            string error;
            if (!LifecycleStorage.TryReadActive(safeRuntime, safeItem, out record, out error) ||
                !String.IsNullOrEmpty(error) || record == null)
            {
                throw new InvalidOperationException(String.IsNullOrEmpty(error)
                    ? "The v2 lifecycle ownership record is unavailable." : error);
            }
            if (!String.Equals(record.ContractDigest, safeContract, StringComparison.Ordinal) ||
                !String.Equals(record.HealthUrl, healthUrls[0].AbsoluteUri, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The v2 lifecycle binding did not match the owned contract.");
            }
            string identityError;
            if (!String.Equals(record.TerminalState, "Stopped", StringComparison.Ordinal) &&
                !LifecycleStorage.ValidateSupervisorIdentity(record, out identityError))
            {
                throw new InvalidOperationException(identityError);
            }
            if (allowInitialBind)
            {
                LifecycleStorage.BindOrVerifyV2Configuration(record, healthUrls, stopTarget, stopArgs);
            }
            else
            {
                LifecycleStorage.VerifyV2Configuration(record, healthUrls, stopTarget, stopArgs, true);
            }
            return record;
        }

        private static string WithV2HealthEvidence(string response, IList<Uri> healthUrls)
        {
            Dictionary<string, object> result = LifecycleJson.Parse(response);
            bool allOnline = AreAllHealthy(healthUrls);
            bool allOffline = AreAllPortsOffline(healthUrls);
            result["allHealthOnline"] = allOnline;
            result["allHealthOffline"] = allOffline;
            return Json.Serialize(result);
        }

        private static bool AreAllPortsOffline(IList<Uri> healthUrls)
        {
            foreach (Uri uri in healthUrls)
            {
                if (NativeMethods.GetListeningProcessIds(uri.Port).Count != 0) { return false; }
            }
            return true;
        }

        private static bool AreAllHealthy(IList<Uri> healthUrls)
        {
            return AreAllHealthy(healthUrls, HealthProbeDeadlineMilliseconds);
        }

        private static bool AreAllHealthy(IList<Uri> healthUrls, int timeoutMilliseconds)
        {
            if (healthUrls == null || healthUrls.Count == 0 || timeoutMilliseconds <= 0)
            {
                return false;
            }
            int perRequestTimeout = Math.Max(1, Math.Min(1000, timeoutMilliseconds));
            Task<bool>[] probes = healthUrls.Select(delegate(Uri uri)
            {
                return Task.Factory.StartNew(delegate { return IsHealthy(uri, perRequestTimeout); });
            }).ToArray();
            try
            {
                if (!Task.WaitAll(probes, timeoutMilliseconds)) { return false; }
                return probes.All(delegate(Task<bool> probe) { return probe.Status == TaskStatus.RanToCompletion && probe.Result; });
            }
            catch { return false; }
        }

        private static bool WaitForAllHealthy(IList<Uri> healthUrls, int timeoutMilliseconds)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                int remaining = timeoutMilliseconds - (int)watch.ElapsedMilliseconds;
                if (AreAllHealthy(healthUrls, Math.Min(HealthProbeDeadlineMilliseconds, remaining))) { return true; }
                if (watch.ElapsedMilliseconds < timeoutMilliseconds)
                {
                    Thread.Sleep(Math.Min(100, timeoutMilliseconds - (int)watch.ElapsedMilliseconds));
                }
            }
            return false;
        }

        private static bool IsHealthy(Uri healthUrl)
        {
            return IsHealthy(healthUrl, 1000);
        }

        private static bool IsHealthy(Uri healthUrl, int timeoutMilliseconds)
        {
            try
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(healthUrl);
                request.Method = "GET";
                request.Timeout = Math.Max(1, timeoutMilliseconds);
                request.ReadWriteTimeout = Math.Max(1, timeoutMilliseconds);
                request.AllowAutoRedirect = false;
                using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                {
                    int status = (int)response.StatusCode;
                    return status >= 200 && status < 400;
                }
            }
            catch (WebException exception)
            {
                HttpWebResponse response = exception.Response as HttpWebResponse;
                if (response == null) { return false; }
                using (response)
                {
                    int status = (int)response.StatusCode;
                    return status >= 200 && status < 400;
                }
            }
            catch { return false; }
        }

        private static string RunStopHelper(string stopTarget, string stopArgs, string runtimeRoot,
            string itemId, string contractDigest, string instanceId, IList<Uri> healthUrls,
            int timeoutMilliseconds)
        {
            if (String.Equals(stopTarget, "@managed-signal", StringComparison.Ordinal)) { return "signal"; }
            string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
            string safeItem = LifecycleStorage.NormalizeItemId(itemId);
            string safeContract = LifecycleStorage.RequireDigest(contractDigest, "contractDigest");
            LifecycleRecord record;
            string recordError;
            if (!LifecycleStorage.TryReadActive(safeRuntime, safeItem, out record, out recordError) ||
                !String.IsNullOrEmpty(recordError) || record == null ||
                !String.Equals(record.InstanceId, instanceId, StringComparison.Ordinal) ||
                !String.Equals(record.ContractDigest, safeContract, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The owned lifecycle record changed before the stop helper could run.");
            }
            string supervisorError;
            if (!LifecycleStorage.ValidateSupervisorIdentity(record, out supervisorError))
            {
                throw new InvalidOperationException(supervisorError);
            }
            V2LifecycleConfiguration configuration = LifecycleStorage.VerifyV2Configuration(
                record, healthUrls, stopTarget, stopArgs, true);
            string target = LifecycleStorage.RequireFile(stopTarget, "stopTarget");
            ValidateStopContract(target, stopArgs);
            string targetExtension = Path.GetExtension(target);
            string helperExecutable;
            string helperArguments;
            if (String.Equals(targetExtension, ".ps1", StringComparison.OrdinalIgnoreCase))
            {
                string systemPowerShell = LifecycleStorage.RequireFile(Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "WindowsPowerShell", "v1.0", "powershell.exe"), "systemPowerShell");
                helperExecutable = systemPowerShell;
                helperArguments = "-NoProfile -NonInteractive -File " + QuoteArgument(target) +
                    (String.IsNullOrWhiteSpace(stopArgs) ? String.Empty : " " + stopArgs);
            }
            else
            {
                helperExecutable = configuration.NodeRuntime;
                helperArguments = QuoteArgument(target) +
                    (String.IsNullOrWhiteSpace(stopArgs) ? String.Empty : " " + stopArgs);
            }
            int bounded = Math.Max(1000, Math.Min(30000, timeoutMilliseconds));
            using (NativeHelperProcess helper = NativeMethods.CreateSuspendedHelper(helperExecutable,
                helperArguments, Path.GetDirectoryName(target), instanceId, safeItem, safeContract))
            {
                IntPtr helperJob = IntPtr.Zero;
                try
                {
                    helperJob = NativeMethods.CreateManagedJob();
                    if (!NativeMethods.AssignProcessToJobObject(helperJob, helper.Process.ProcessHandle))
                    {
                        NativeMethods.AbortSuspendedProcess(helper.Process.ProcessHandle);
                        throw new InvalidOperationException("The managed stop helper could not be assigned to its job.");
                    }
                    if (NativeMethods.ResumeThread(helper.Process.ThreadHandle) == UInt32.MaxValue)
                    {
                        NativeMethods.TerminateJobObject(helperJob, 1);
                        throw new InvalidOperationException("The managed stop helper could not be resumed.",
                            new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
                    }
                    helper.Process.CloseThreadHandle();
                    Task<string> output = ReadBoundedHelperText(helper.StandardOutput, 4096);
                    Task<string> errors = ReadBoundedHelperText(helper.StandardError, 4096);
                    try
                    {
                        if (!NativeMethods.WaitForProcessExit(helper.Process.ProcessHandle, bounded) ||
                            !Task.WaitAll(new Task[] { output, errors }, bounded))
                        {
                            throw new TimeoutException("The managed stop helper exceeded its bounded timeout.");
                        }
                    }
                    catch
                    {
                        NativeMethods.TerminateJobObject(helperJob, 1);
                        throw;
                    }
                    int helperExitCode;
                    if (!NativeMethods.TryGetProcessExitCode(helper.Process.ProcessHandle, out helperExitCode) ||
                        helperExitCode != 0)
                    {
                        throw new InvalidOperationException("The managed stop helper failed without an accepted action.");
                    }
                    Dictionary<string, object> action = LifecycleJson.Parse(output.Result.Trim());
                    string value = LifecycleJson.String(action, "action");
                    if (!String.Equals(value, "signal", StringComparison.Ordinal) &&
                        !String.Equals(value, "complete", StringComparison.Ordinal) || action.Count != 1)
                    {
                        throw new InvalidOperationException("The managed stop helper action is invalid.");
                    }
                    return value;
                }
                finally
                {
                    if (helperJob != IntPtr.Zero) { NativeMethods.CloseHandle(helperJob); }
                }
            }
        }

        private static Task<string> ReadBoundedHelperText(Stream stream, int maximumBytes)
        {
            return Task.Factory.StartNew(delegate
            {
                byte[] buffer = new byte[1024];
                using (MemoryStream value = new MemoryStream())
                {
                    while (true)
                    {
                        int read = stream.Read(buffer, 0, buffer.Length);
                        if (read <= 0) { break; }
                        if (value.Length + read > maximumBytes)
                        {
                            throw new InvalidOperationException("The managed stop helper exceeded its output limit.");
                        }
                        value.Write(buffer, 0, read);
                    }
                    return Encoding.UTF8.GetString(value.ToArray());
                }
            });
        }

        private static string QuoteArgument(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static string StartCore(
            string hostPath,
            string runtimeRoot,
            string itemId,
            string contractDigest,
            string executable,
            string arguments,
            string workingDirectory,
            string healthUrl,
            string pathValue,
            int startupDelayMilliseconds)
        {
            Mutex startMutex = null;
            bool startLockTaken = false;
            Process launchedSupervisor = null;
            long launchedSupervisorCreationTime = 0;
            string launchedSupervisorHost = null;
            bool authenticatedStartupConfirmed = false;
            try
            {
                string safeHost = LifecycleStorage.RequireFile(hostPath, "hostPath");
                string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
                LifecycleStorage.ValidateLifecyclePathBudget(safeRuntime);
                string safeExecutable = LifecycleStorage.RequireFile(executable, "executable");
                string safeWorking = LifecycleStorage.RequireDirectory(workingDirectory, "workingDirectory", false);
                string safeItem = LifecycleStorage.NormalizeItemId(itemId);
                if (startupDelayMilliseconds < -60000 || startupDelayMilliseconds > 60000)
                {
                    throw new ArgumentOutOfRangeException("startupDelayMilliseconds");
                }
                startMutex = new Mutex(false, "Local\\WorkspaceWidget.ManagedService.Start." + safeItem);
                try { startLockTaken = startMutex.WaitOne(10000); }
                catch (AbandonedMutexException) { startLockTaken = true; }
                if (!startLockTaken)
                {
                    throw new TimeoutException("Another lifecycle start is already in progress for this item.");
                }
                string safeContract = LifecycleStorage.RequireDigest(contractDigest, "contractDigest");
                Uri health = LifecycleStorage.RequireLoopbackHealthUrl(healthUrl);
                LifecycleStorage.ValidateLaunchContract(
                    safeHost, safeExecutable, arguments ?? String.Empty);

                string existing = Status(safeRuntime, itemId, safeContract, health.AbsoluteUri);
                Dictionary<string, object> existingObject = LifecycleJson.Parse(existing);
                string existingState = LifecycleJson.String(existingObject, "state");
                if (String.Equals(existingState, "Owned", StringComparison.Ordinal))
                {
                    return existing;
                }
                if (!String.Equals(existingState, "Stopped", StringComparison.Ordinal))
                {
                    return LifecycleJson.Result(false, existingState, false, false, 0, 0,
                        LifecycleJson.String(existingObject, "instanceId"), null,
                        "A new service was refused because lifecycle ownership is not safely stopped.",
                        false, false);
                }

                IList<int> foreignOwners = NativeMethods.GetListeningProcessIds(health.Port);
                if (foreignOwners.Count != 0)
                {
                    return LifecycleJson.Result(false, "RunningUnowned", false, false, 0, 0,
                        null, null, "The configured health port is already owned by another process.",
                        false, false);
                }

                string instanceId = Guid.NewGuid().ToString("N");
                LifecyclePaths paths = LifecycleStorage.CreateInstance(safeRuntime, safeItem, instanceId);
                byte[] capability = LifecycleStorage.CreateAndProtectCapability(paths);
                Dictionary<string, object> descriptor = new Dictionary<string, object>();
                descriptor["schemaVersion"] = 1;
                descriptor["protocolVersion"] = ProtocolVersion;
                descriptor["instanceId"] = instanceId;
                descriptor["itemId"] = safeItem;
                descriptor["contractDigest"] = safeContract;
                descriptor["executable"] = safeExecutable;
                descriptor["arguments"] = arguments ?? String.Empty;
                descriptor["workingDirectory"] = safeWorking;
                descriptor["healthUrl"] = health.AbsoluteUri;
                descriptor["pathValue"] = pathValue ?? String.Empty;
                descriptor["instanceDirectory"] = paths.InstanceDirectory;
                descriptor["capability"] = Convert.ToBase64String(capability);
                descriptor["startupDelayMilliseconds"] = startupDelayMilliseconds;
                string descriptorJson = Json.Serialize(descriptor);
                int descriptorUtf8Bytes;
                try { descriptorUtf8Bytes = StrictUtf8.GetByteCount(descriptorJson); }
                catch (EncoderFallbackException)
                {
                    throw new InvalidOperationException("The lifecycle descriptor contains malformed Unicode.");
                }
                if (descriptorUtf8Bytes > MaximumMessageBytes)
                {
                    throw new InvalidOperationException("The lifecycle descriptor is too large.");
                }
                string descriptorWireJson = EscapeDescriptorForAsciiWire(descriptorJson);
                if (descriptorWireJson.Length > MaximumMessageBytes)
                {
                    throw new InvalidOperationException("The lifecycle descriptor is too large.");
                }

                ProcessStartInfo start = new ProcessStartInfo();
                start.FileName = safeHost;
                start.Arguments = "--service-supervisor " + instanceId;
                start.WorkingDirectory = Path.GetDirectoryName(safeHost);
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                start.RedirectStandardInput = true;
                start.RedirectStandardOutput = true;
                start.RedirectStandardError = true;
                // The descriptor contains ASCII JSON only.  It therefore crosses
                // normal Windows console code pages unchanged without changing the
                // process-wide Console.InputEncoding state.
                Process supervisor = Process.Start(start);
                if (supervisor == null)
                {
                    throw new InvalidOperationException("The lifecycle supervisor did not start.");
                }
                launchedSupervisor = supervisor;
                launchedSupervisorHost = safeHost;
                // The child can inherit this console on Windows.  Keep draining it so
                // it cannot block the supervisor, but accept only the supervisor's
                // fixed structured startup diagnostic after that exact host exits.
                Task<string> supervisorOutput = ReadBoundedSupervisorDiagnostic(
                    supervisor.StandardOutput.BaseStream);
                DrainUntrustedOutput(supervisor.StandardError.BaseStream);
                supervisor.StandardInput.WriteLine(descriptorWireJson);
                supervisor.StandardInput.Flush();
                supervisor.StandardInput.Close();
                Stopwatch startupWatch = Stopwatch.StartNew();
                long supervisorCreationTime = NativeMethods.GetCreationFileTime(supervisor.Handle);
                launchedSupervisorCreationTime = supervisorCreationTime;
                bool recoveringSlowStartup = false;
                while (startupWatch.ElapsedMilliseconds < StartupRecoveryDeadlineMilliseconds)
                {
                    LifecycleRecord startedRecord;
                    string ownershipError;
                    bool active = LifecycleStorage.TryReadActive(safeRuntime, safeItem,
                        out startedRecord, out ownershipError);
                    if (!String.IsNullOrEmpty(ownershipError))
                    {
                        throw new InvalidOperationException(ownershipError);
                    }
                    // A preceding stopped instance may remain active until the
                    // new supervisor atomically publishes its ownership pointer.
                    if (active && String.Equals(startedRecord.InstanceId, instanceId, StringComparison.Ordinal))
                    {
                        if (startedRecord.SupervisorPid != supervisor.Id ||
                            !String.Equals(startedRecord.ContractDigest, safeContract, StringComparison.Ordinal) ||
                            !String.Equals(startedRecord.HealthUrl, health.AbsoluteUri, StringComparison.Ordinal))
                        {
                            throw new InvalidOperationException("The startup ownership did not match the requested instance.");
                        }
                        int remaining = RemainingBudget(startupWatch, StartupRecoveryDeadlineMilliseconds);
                        string response;
                        try
                        {
                            response = SendOnce(startedRecord, "status", false, 0, ProtocolVersion, remaining);
                            if (LifecycleJson.IsUnsupportedProtocolDowngradeResponse(response, instanceId, supervisor.Id))
                            {
                                remaining = RemainingBudget(startupWatch, StartupRecoveryDeadlineMilliseconds);
                                response = SendOnce(startedRecord, "status", false, 0, 1, remaining);
                            }
                        }
                        catch (IOException)
                        {
                            if (supervisor.HasExited || startupWatch.ElapsedMilliseconds >= StartupRecoveryDeadlineMilliseconds) { throw; }
                            Thread.Sleep(25);
                            continue;
                        }
                        catch (TimeoutException)
                        {
                            if (supervisor.HasExited || startupWatch.ElapsedMilliseconds >= StartupRecoveryDeadlineMilliseconds) { throw; }
                            Thread.Sleep(25);
                            continue;
                        }
                        Dictionary<string, object> result = LifecycleJson.Parse(response);
                        if (!LifecycleJson.Boolean(result, "success") ||
                            !LifecycleJson.Boolean(result, "owned") || !LifecycleJson.Boolean(result, "stoppable") ||
                            !String.Equals(LifecycleJson.String(result, "state"), "Owned", StringComparison.Ordinal) ||
                            !String.Equals(LifecycleJson.String(result, "instanceId"), instanceId, StringComparison.Ordinal) ||
                            LifecycleJson.Integer(result, "processId", 0) != supervisor.Id ||
                            LifecycleJson.Integer(result, "rootProcessId", 0) != startedRecord.RootPid)
                        {
                            throw new InvalidOperationException("The authenticated supervisor did not confirm startup ownership.");
                        }
                        authenticatedStartupConfirmed = true;
                        return response;
                    }
                    if (supervisor.HasExited)
                    {
                        throw new InvalidOperationException(DescribeSupervisorExit(
                            supervisor, supervisorOutput));
                    }
                    // The record includes image hashes and is deliberately written only
                    // after the child is assigned to the kill-on-close job.  On a cold
                    // or protected volume that verification can outlast the normal UI
                    // deadline.  Continue only for the exact host process this call
                    // created; this is not a broad timeout extension or a PID-only adopt.
                    if (!recoveringSlowStartup &&
                        startupWatch.ElapsedMilliseconds >= StartupAuthenticationDeadlineMilliseconds)
                    {
                        if (!LifecycleStorage.IsExactProcessIdentity(
                            supervisor.Id, supervisorCreationTime, safeHost))
                        {
                            throw new InvalidOperationException(
                                "The slow lifecycle supervisor identity could not be verified.");
                        }
                        recoveringSlowStartup = true;
                    }
                    Thread.Sleep(25);
                }
                throw new TimeoutException(
                    "The lifecycle supervisor did not confirm authenticated startup within the bounded recovery window.");
            }
            catch (Exception exception)
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                    null, null, exception.Message, false, false);
            }
            finally
            {
                // Every failed path after Process.Start, including a pipe read or
                // authenticated-response failure, owns only this exact supervisor.
                // Its kill-on-close job drains a published or suspended child before
                // this call can return an ambiguous result.
                if (!authenticatedStartupConfirmed && launchedSupervisor != null &&
                    launchedSupervisorCreationTime != 0 &&
                    LifecycleStorage.IsExactProcessIdentity(launchedSupervisor.Id,
                        launchedSupervisorCreationTime, launchedSupervisorHost))
                {
                    try { launchedSupervisor.Kill(); }
                    catch (InvalidOperationException) { }
                    catch (System.ComponentModel.Win32Exception) { }
                    try { launchedSupervisor.WaitForExit(5000); }
                    catch (InvalidOperationException) { }
                }
                if (launchedSupervisor != null) { launchedSupervisor.Dispose(); }
                if (startLockTaken && startMutex != null) { startMutex.ReleaseMutex(); }
                if (startMutex != null) { startMutex.Dispose(); }
            }
        }

        public static string Status(
            string runtimeRoot,
            string itemId,
            string contractDigest,
            string healthUrl)
        {
            try
            {
                string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
                string safeItem = LifecycleStorage.NormalizeItemId(itemId);
                string safeContract = LifecycleStorage.RequireDigest(contractDigest, "contractDigest");
                Uri health = LifecycleStorage.RequireLoopbackHealthUrl(healthUrl);
                LifecycleRecord record;
                string error;
                if (!LifecycleStorage.TryReadActive(safeRuntime, safeItem, out record, out error))
                {
                    IList<int> listeners = NativeMethods.GetListeningProcessIds(health.Port);
                    if (!String.IsNullOrEmpty(error))
                    {
                        return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                            null, null, error, false, listeners.Count == 0);
                    }
                    return LifecycleJson.Result(true, listeners.Count == 0 ? "Stopped" : "RunningUnowned",
                        false, false, 0, 0, null, null, null, listeners.Count == 0, listeners.Count == 0);
                }
                bool contractMatches =
                    String.Equals(record.ContractDigest, safeContract, StringComparison.Ordinal) &&
                    String.Equals(record.HealthUrl, health.AbsoluteUri, StringComparison.Ordinal);
                if (!contractMatches)
                {
                    string transitionedStatus;
                    int recordedHealthPort = LifecycleStorage.RequireLoopbackHealthUrl(
                        record.HealthUrl).Port;
                    if (LifecycleStorage.TryRecoverStaleStopped(
                        safeRuntime, safeItem, record, recordedHealthPort, health.Port,
                        false, out transitionedStatus))
                    {
                        return transitionedStatus;
                    }
                    return LifecycleJson.Result(false, "Ambiguous", false, false,
                        record.SupervisorPid, record.RootPid, record.InstanceId, record.LastReceiptPath,
                        "The active lifecycle contract does not match this shortcut.", false, false);
                }
                if (String.Equals(record.TerminalState, "Stopped", StringComparison.Ordinal))
                {
                    bool terminalPortOffline = NativeMethods.GetListeningProcessIds(health.Port).Count == 0;
                    return LifecycleJson.ResultWithEvidence(true,
                        terminalPortOffline ? "Stopped" : "RunningUnowned", false, false,
                        record.SupervisorPid, record.RootPid, record.InstanceId,
                        record.LastReceiptPath,
                        terminalPortOffline ? null :
                            "The owned job stopped, but another process now owns the configured health port.",
                        true, terminalPortOffline, "persisted-state", false);
                }
                string recoveredStatus;
                if (LifecycleStorage.TryRecoverStaleStopped(
                    safeRuntime, safeItem, record, health.Port, health.Port,
                    false, out recoveredStatus))
                {
                    return recoveredStatus;
                }
                return Send(safeRuntime, safeItem, record, "status", false, 0);
            }
            catch (Exception exception)
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                    null, null, exception.Message, false, false);
            }
        }

        public static Task<string> StopAsync(
            string runtimeRoot,
            string itemId,
            string contractDigest,
            string healthUrl,
            bool force,
            int gracefulTimeoutMs)
        {
            return Task.Factory.StartNew(delegate
            {
                return Stop(runtimeRoot, itemId, contractDigest, healthUrl, force, gracefulTimeoutMs);
            });
        }

        public static Task<string> StatusAsync(
            string runtimeRoot,
            string itemId,
            string contractDigest,
            string healthUrl)
        {
            return Task.Factory.StartNew(delegate
            {
                return Status(runtimeRoot, itemId, contractDigest, healthUrl);
            });
        }

        public static string Stop(
            string runtimeRoot,
            string itemId,
            string contractDigest,
            string healthUrl,
            bool force,
            int gracefulTimeoutMs)
        {
            try
            {
                string safeRuntime = LifecycleStorage.RequireDirectory(runtimeRoot, "runtimeRoot", true);
                string safeItem = LifecycleStorage.NormalizeItemId(itemId);
                string safeContract = LifecycleStorage.RequireDigest(contractDigest, "contractDigest");
                Uri health = LifecycleStorage.RequireLoopbackHealthUrl(healthUrl);
                LifecycleRecord record;
                string error;
                if (!LifecycleStorage.TryReadActive(safeRuntime, safeItem, out record, out error))
                {
                    IList<int> listeners = NativeMethods.GetListeningProcessIds(health.Port);
                    string state = String.IsNullOrEmpty(error)
                        ? (listeners.Count == 0 ? "Stopped" : "RunningUnowned")
                        : "Ambiguous";
                    return LifecycleJson.Result(listeners.Count == 0 && String.IsNullOrEmpty(error), state,
                        false, false, 0, 0, null, null, error, listeners.Count == 0, listeners.Count == 0);
                }
                bool contractMatches =
                    String.Equals(record.ContractDigest, safeContract, StringComparison.Ordinal) &&
                    String.Equals(record.HealthUrl, health.AbsoluteUri, StringComparison.Ordinal);
                if (!contractMatches)
                {
                    string transitionedStatus;
                    int recordedHealthPort = LifecycleStorage.RequireLoopbackHealthUrl(
                        record.HealthUrl).Port;
                    if (LifecycleStorage.TryRecoverStaleStopped(
                        safeRuntime, safeItem, record, recordedHealthPort, health.Port,
                        true, out transitionedStatus))
                    {
                        return transitionedStatus;
                    }
                    return LifecycleJson.Result(false, "Ambiguous", false, false,
                        record.SupervisorPid, record.RootPid, record.InstanceId, record.LastReceiptPath,
                        "The active lifecycle contract does not match this shortcut.", false, false);
                }
                if (String.Equals(record.TerminalState, "Stopped", StringComparison.Ordinal))
                {
                    bool terminalPortOffline = NativeMethods.GetListeningProcessIds(health.Port).Count == 0;
                    return LifecycleJson.ResultWithEvidence(terminalPortOffline,
                        terminalPortOffline ? "Stopped" : "RunningUnowned", false, false,
                        record.SupervisorPid, record.RootPid, record.InstanceId,
                        record.LastReceiptPath,
                        terminalPortOffline ? null :
                            "Stop is unavailable because another process owns the configured health port.",
                        true, terminalPortOffline, "persisted-state", false);
                }
                string recoveredStatus;
                if (LifecycleStorage.TryRecoverStaleStopped(
                    safeRuntime, safeItem, record, health.Port, health.Port,
                    true, out recoveredStatus))
                {
                    return recoveredStatus;
                }
                int timeout = Math.Max(1000, Math.Min(60000, gracefulTimeoutMs));
                return Send(safeRuntime, safeItem, record, "stop", force, timeout);
            }
            catch (Exception exception)
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false, 0, 0,
                    null, null, exception.Message, false, false);
            }
        }

        private static string Send(string runtimeRoot, string itemId, LifecycleRecord record,
            string action, bool force, int timeout)
        {
            int maximumAttempts = String.Equals(action, "status", StringComparison.Ordinal) ? 3 : 1;
            IOException responseError = null;
            bool protocolOneAttempted = false;
            for (int attempt = 0; attempt < maximumAttempts; attempt++)
            {
                try
                {
                    string response = SendOnce(record, action, force, timeout, ProtocolVersion);
                    if (LifecycleJson.IsUnsupportedProtocolDowngradeResponse(
                        response, record.InstanceId, record.SupervisorPid))
                    {
                        // An exact authenticated refusal proves that protocol 2 was not acted on.
                        // Protocol 1 is attempted once; no other failure may trigger downgrade.
                        protocolOneAttempted = true;
                        return SendOnce(record, action, force, timeout, 1);
                    }
                    return response;
                }
                catch (IOException exception)
                {
                    responseError = exception;
                    if (protocolOneAttempted ||
                        !String.Equals(action, "status", StringComparison.Ordinal)) { break; }
                    if (attempt + 1 < maximumAttempts) { Thread.Sleep(100); }
                }
            }
            string recovered;
            if (String.Equals(action, "stop", StringComparison.Ordinal) && responseError != null &&
                LifecycleStorage.TryRecoverCompletedStopResponse(
                    runtimeRoot, itemId, record, responseError, out recovered))
            {
                return recovered;
            }
            throw responseError ?? new IOException("The lifecycle response was unavailable.");
        }

        private static string SendOnce(LifecycleRecord record, string action, bool force, int timeout,
            int requestProtocolVersion, int operationBudgetMilliseconds = 0)
        {
            Stopwatch operationWatch = Stopwatch.StartNew();
            string identityError;
            if (!LifecycleStorage.ValidateSupervisorIdentity(record, out identityError))
            {
                return LifecycleJson.Result(false, "Ambiguous", false, false,
                    record.SupervisorPid, record.RootPid, record.InstanceId, record.LastReceiptPath,
                    identityError, false, false);
            }
            byte[] capability = LifecycleStorage.ReadCapability(record.InstanceDirectory);
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(
                ".", record.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous,
                TokenImpersonationLevel.Identification))
            {
                pipe.Connect(operationBudgetMilliseconds > 0
                    ? Math.Min(ConnectTimeoutMilliseconds, RemainingBudget(operationWatch, operationBudgetMilliseconds))
                    : ConnectTimeoutMilliseconds);
                int serverPid;
                if (!NativeMethods.TryGetNamedPipeServerPid(pipe, out serverPid) || serverPid != record.SupervisorPid)
                {
                    throw new InvalidOperationException("The lifecycle pipe server identity did not match the ownership record.");
                }
                Dictionary<string, object> request = new Dictionary<string, object>();
                request["schemaVersion"] = 1;
                request["protocolVersion"] = requestProtocolVersion;
                request["action"] = action;
                request["instanceId"] = record.InstanceId;
                request["capability"] = Convert.ToBase64String(capability);
                request["force"] = force;
                request["gracefulTimeoutMs"] = timeout;
                LifecycleJson.WriteMessage(pipe, request, MaximumMessageBytes);
                string response = LifecycleJson.ReadMessage(
                    pipe, MaximumMessageBytes, operationBudgetMilliseconds > 0
                        ? RemainingBudget(operationWatch, operationBudgetMilliseconds)
                        : Math.Max(5000, timeout + 15000));
                if (requestProtocolVersion >= ProtocolVersion)
                {
                    Dictionary<string, object> acknowledgement = new Dictionary<string, object>();
                    acknowledgement["protocolVersion"] = ProtocolVersion;
                    acknowledgement["action"] = "response-ack";
                    acknowledgement["instanceId"] = record.InstanceId;
                    try { LifecycleJson.WriteMessage(pipe, acknowledgement, MaximumMessageBytes); }
                    catch { }
                }
                return response;
            }
        }

        private static int RemainingBudget(Stopwatch watch, int budget)
        {
            int remaining = budget - (int)watch.ElapsedMilliseconds;
            if (remaining <= 0) { throw new TimeoutException("The lifecycle startup budget was exhausted."); }
            return remaining;
        }

        private static void DrainUntrustedOutput(Stream stream)
        {
            stream.CopyToAsync(Stream.Null, 4096).ContinueWith(delegate(Task completed)
            {
                if (completed.IsFaulted) { completed.Exception.Handle(delegate(Exception ignored) { return true; }); }
            }, TaskScheduler.Default);
        }

        private static async Task<string> ReadBoundedSupervisorDiagnostic(Stream stream)
        {
            byte[] capture = new byte[MaximumSupervisorDiagnosticBytes];
            byte[] drain = new byte[1024];
            int captured = 0;
            while (true)
            {
                byte[] target = captured < capture.Length ? capture : drain;
                int offset = captured < capture.Length ? captured : 0;
                int count = captured < capture.Length ? capture.Length - captured : drain.Length;
                int read = await stream.ReadAsync(target, offset, count).ConfigureAwait(false);
                if (read == 0) { break; }
                if (captured < capture.Length) { captured += read; }
            }
            return Encoding.UTF8.GetString(capture, 0, captured);
        }

        private static string DescribeSupervisorExit(Process supervisor, Task<string> output)
        {
            int exitCode = 0;
            try { exitCode = supervisor.ExitCode; }
            catch (InvalidOperationException) { }
            string stage = "unknown";
            int nativeError = 0;
            try
            {
                if (output.Wait(250) && output.Status == TaskStatus.RanToCompletion)
                {
                    Dictionary<string, object> result = LifecycleJson.Parse(output.Result.Trim());
                    string error = LifecycleJson.String(result, "error");
                    if (!LifecycleJson.Boolean(result, "success") &&
                        !LifecycleJson.Boolean(result, "owned") &&
                        String.Equals(LifecycleJson.String(result, "state"), "Ambiguous",
                            StringComparison.Ordinal) &&
                        LifecycleJson.Integer(result, "processId", 0) == supervisor.Id)
                    {
                        Match match = Regex.Match(error ?? String.Empty,
                            "^supervisor-stage=(descriptor|launch-contract|capability|preflight|job|console|launch|assign-job|record|active-pointer|resume|pipe);native-error=(-?\\d+)$",
                            RegexOptions.CultureInvariant);
                        if (match.Success)
                        {
                            stage = match.Groups[1].Value;
                            Int32.TryParse(match.Groups[2].Value, NumberStyles.Integer,
                                CultureInfo.InvariantCulture, out nativeError);
                        }
                    }
                }
            }
            catch (Exception) { }
            return "The lifecycle supervisor exited before authenticated startup completed " +
                "(stage=" + stage + "; exitCode=" + exitCode.ToString(CultureInfo.InvariantCulture) +
                "; nativeError=" + nativeError.ToString(CultureInfo.InvariantCulture) + ").";
        }

        private static string EscapeDescriptorForAsciiWire(string descriptorJson)
        {
            StringBuilder escaped = new StringBuilder(descriptorJson.Length);
            for (int index = 0; index < descriptorJson.Length; index++)
            {
                char value = descriptorJson[index];
                if (value <= 0x7f)
                {
                    escaped.Append(value);
                }
                else
                {
                    escaped.Append("\\u");
                    escaped.Append(((int)value).ToString("X4", CultureInfo.InvariantCulture));
                }
            }
            return escaped.ToString();
        }

        private static JavaScriptSerializer CreateSerializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = MaximumMessageBytes;
            serializer.RecursionLimit = 12;
            return serializer;
        }
    }

    public static class ManagedServiceSupervisor
    {
        private const int ProtocolVersion = 2;
        private const int MaximumMessageBytes = 64 * 1024;
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer
        {
            MaxJsonLength = MaximumMessageBytes,
            RecursionLimit = 12
        };
        private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false, true);

        public static int Run(string instanceId)
        {
            NativeProcess root = null;
            IntPtr job = IntPtr.Zero;
            string startupStage = "descriptor";
            try
            {
                if (!LifecycleStorage.IsOpaqueInstanceId(instanceId))
                {
                    throw new ArgumentException("The lifecycle instance identifier is invalid.");
                }
                string descriptorLine = ReadBoundedUtf8Descriptor(Console.OpenStandardInput(),
                    MaximumMessageBytes);
                Dictionary<string, object> descriptor = LifecycleJson.Parse(descriptorLine);
                RequireDescriptor(descriptor, instanceId);
                startupStage = "launch-contract";
                string instanceDirectory = LifecycleStorage.RequireDirectory(
                    LifecycleJson.String(descriptor, "instanceDirectory"), "instanceDirectory", false);
                string itemId = LifecycleStorage.RequireNormalizedItemId(
                    LifecycleJson.String(descriptor, "itemId"));
                string contractDigest = LifecycleStorage.RequireDigest(
                    LifecycleJson.String(descriptor, "contractDigest"), "contractDigest");
                string executable = LifecycleStorage.RequireFile(
                    LifecycleJson.String(descriptor, "executable"), "executable");
                string arguments = LifecycleJson.String(descriptor, "arguments") ?? String.Empty;
                string workingDirectory = LifecycleStorage.RequireDirectory(
                    LifecycleJson.String(descriptor, "workingDirectory"), "workingDirectory", false);
                Uri health = LifecycleStorage.RequireLoopbackHealthUrl(
                    LifecycleJson.String(descriptor, "healthUrl"));
                string pathValue = LifecycleJson.String(descriptor, "pathValue") ?? String.Empty;
                int startupDelayMilliseconds = LifecycleJson.Integer(
                    descriptor, "startupDelayMilliseconds", 0);
                if (startupDelayMilliseconds < -60000 || startupDelayMilliseconds > 60000)
                {
                    throw new InvalidOperationException("The lifecycle test startup delay is invalid.");
                }
                string currentHostImage = LifecycleStorage.RequireFile(
                    Process.GetCurrentProcess().MainModule.FileName, "supervisorHost");
                LifecycleStorage.ValidateLaunchContract(currentHostImage, executable, arguments);
                startupStage = "capability";
                byte[] capability = Convert.FromBase64String(LifecycleJson.String(descriptor, "capability"));
                byte[] persistedCapability = LifecycleStorage.ReadCapability(instanceDirectory);
                if (!LifecycleStorage.FixedEquals(capability, persistedCapability))
                {
                    throw new InvalidOperationException("The lifecycle capability did not match protected storage.");
                }
                LifecyclePaths paths = LifecycleStorage.FromInstanceDirectory(instanceDirectory, itemId, instanceId);
                string pipeName = "WorkspaceWidget.ManagedService." + instanceId;

                startupStage = "preflight";
                IList<int> listeners = NativeMethods.GetListeningProcessIds(health.Port);
                if (listeners.Count != 0)
                {
                    throw new InvalidOperationException("The configured health port became occupied before launch.");
                }

                startupStage = "job";
                job = NativeMethods.CreateManagedJob();
                startupStage = "console";
                NativeMethods.PrepareHiddenConsole();
                string gracefulAckPath = Path.Combine(instanceDirectory, "graceful-ack.txt");
                string gracefulAckToken = Guid.NewGuid().ToString("N");
                startupStage = "launch";
                root = NativeMethods.CreateSuspendedProcess(executable, arguments, workingDirectory,
                    pathValue, gracefulAckPath, gracefulAckToken);
                startupStage = "assign-job";
                if (!NativeMethods.AssignProcessToJobObject(job, root.ProcessHandle))
                {
                    int assignmentError = Marshal.GetLastWin32Error();
                    NativeMethods.AbortSuspendedProcess(root.ProcessHandle);
                    throw new InvalidOperationException("The service root could not be assigned to its lifecycle job.",
                        new System.ComponentModel.Win32Exception(assignmentError));
                }
                startupStage = "record";
                LifecycleRecord record = LifecycleStorage.CreateRecord(
                    paths, itemId, instanceId, contractDigest, health.AbsoluteUri, pipeName,
                    capability, root, executable, arguments, workingDirectory);
                record.GracefulAckPath = gracefulAckPath;
                record.GracefulAckToken = gracefulAckToken;
                record.GracefulAckTokenDigest = LifecycleStorage.HashTextValue(gracefulAckToken);
                if (startupDelayMilliseconds > 0)
                {
                    Thread.Sleep(startupDelayMilliseconds);
                }
                // Publish only after both process identities were hashed and the root
                // belongs to this kill-on-close job.  The child remains suspended until
                // the authenticated ownership boundary exists.
                LifecycleStorage.WriteOwnership(record, capability);
                startupStage = "active-pointer";
                LifecycleStorage.WriteActivePointer(paths, record, capability);
                if (startupDelayMilliseconds < 0)
                {
                    Thread.Sleep(-startupDelayMilliseconds);
                }
                startupStage = "resume";
                if (NativeMethods.ResumeThread(root.ThreadHandle) == UInt32.MaxValue)
                {
                    throw new InvalidOperationException("The service root could not be resumed.",
                        new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
                }
                root.CloseThreadHandle();

                string started = LifecycleJson.Result(true, "Owned", true, true,
                    record.SupervisorPid, record.RootPid, instanceId, null, null, false, false);
                Console.Out.WriteLine(started);
                Console.Out.Flush();

                startupStage = "pipe";
                using (NamedPipeServerStream server = CreateServer(pipeName))
                {
                    while (true)
                    {
                        server.WaitForConnection();
                        bool continueRunning = true;
                        int requestProtocolVersion = 1;
                        try
                        {
                            string requestText = LifecycleJson.ReadMessage(server, MaximumMessageBytes, 5000);
                            Dictionary<string, object> request = LifecycleJson.Parse(requestText);
                            requestProtocolVersion = LifecycleJson.Integer(
                                request, "protocolVersion", 1);
                            string response = HandleRequest(request, record, capability, job, root, health,
                                out continueRunning);
                            LifecycleJson.WriteRawMessage(server, response, MaximumMessageBytes);
                            if (requestProtocolVersion >= ProtocolVersion)
                            {
                                try { AwaitResponseAcknowledgement(server, record.InstanceId); }
                                catch { }
                            }
                            else
                            {
                                WaitForLegacyResponseDrain(server);
                            }
                        }
                        catch (Exception exception)
                        {
                            string response = LifecycleJson.Result(false, "Ambiguous", true, false,
                                record.SupervisorPid, record.RootPid, record.InstanceId,
                                record.LastReceiptPath, exception.Message, false, false);
                            try { LifecycleJson.WriteRawMessage(server, response, MaximumMessageBytes); }
                            catch { }
                            if (requestProtocolVersion >= ProtocolVersion)
                            {
                                try { AwaitResponseAcknowledgement(server, record.InstanceId); }
                                catch { }
                            }
                            else
                            {
                                WaitForLegacyResponseDrain(server);
                            }
                        }
                        finally
                        {
                            if (server.IsConnected) { server.Disconnect(); }
                        }
                        if (!continueRunning) { break; }
                    }
                }
                return 0;
            }
            catch (Exception exception)
            {
                Console.Out.WriteLine(LifecycleJson.Result(false, "Ambiguous", false, false,
                    Process.GetCurrentProcess().Id, root == null ? 0 : root.ProcessId,
                    instanceId, null, BuildStartupDiagnostic(startupStage, exception), false, false));
                Console.Out.Flush();
                return 1;
            }
            finally
            {
                if (root != null) { root.Dispose(); }
                if (job != IntPtr.Zero) { NativeMethods.CloseHandle(job); }
            }
        }

        private static string BuildStartupDiagnostic(string stage, Exception exception)
        {
            string safeStage = Regex.IsMatch(stage ?? String.Empty,
                "^(descriptor|launch-contract|capability|preflight|job|console|launch|assign-job|record|active-pointer|resume|pipe)$",
                RegexOptions.CultureInvariant) ? stage : "unknown";
            int nativeError = 0;
            for (Exception current = exception; current != null; current = current.InnerException)
            {
                System.ComponentModel.Win32Exception win32 = current as System.ComponentModel.Win32Exception;
                if (win32 != null)
                {
                    nativeError = win32.NativeErrorCode;
                    break;
                }
            }
            return "supervisor-stage=" + safeStage + ";native-error=" +
                nativeError.ToString(CultureInfo.InvariantCulture);
        }

        private static string HandleRequest(
            Dictionary<string, object> request,
            LifecycleRecord record,
            byte[] capability,
            IntPtr job,
            NativeProcess root,
            Uri health,
            out bool continueRunning)
        {
            continueRunning = true;
            int protocolVersion = LifecycleJson.Integer(request, "protocolVersion", 1);
            if (protocolVersion < 1 || protocolVersion > ProtocolVersion)
            {
                throw new InvalidOperationException("The lifecycle protocol version is unsupported.");
            }
            if (!String.Equals(LifecycleJson.String(request, "instanceId"), record.InstanceId,
                StringComparison.Ordinal) ||
                !LifecycleStorage.FixedEquals(Convert.FromBase64String(
                    LifecycleJson.String(request, "capability")), capability))
            {
                throw new UnauthorizedAccessException("The lifecycle request was not authenticated.");
            }
            string action = LifecycleJson.String(request, "action");
            IList<int> members = NativeMethods.GetJobProcessIds(job);
            bool jobEmpty = members.Count == 0;
            bool healthOffline = NativeMethods.GetListeningProcessIds(health.Port).Count == 0;
            if (String.Equals(action, "status", StringComparison.Ordinal))
            {
                if (jobEmpty)
                {
                    record.TerminalState = "Stopped";
                    LifecycleStorage.WriteOwnership(record, capability);
                    continueRunning = false;
                    return LifecycleJson.Result(true,
                        healthOffline ? "Stopped" : "RunningUnowned", false, false,
                        record.SupervisorPid, record.RootPid, record.InstanceId,
                        record.LastReceiptPath,
                        healthOffline ? null :
                            "The owned job stopped, but another process owns the configured health port.",
                        true, healthOffline);
                }
                return LifecycleJson.Result(true, "Owned", true, true,
                    record.SupervisorPid, record.RootPid, record.InstanceId,
                    record.LastReceiptPath, null, false, healthOffline);
            }
            if (!String.Equals(action, "stop", StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The lifecycle action is unsupported.");
            }

            bool force = LifecycleJson.Boolean(request, "force");
            int timeout = LifecycleJson.Integer(request, "gracefulTimeoutMs", 10000);
            if (jobEmpty)
            {
                record.TerminalState = "Stopped";
                string intentPath = LifecycleStorage.WriteReceipt(record, capability, "stop-intent",
                    "already-stopped", null, true, healthOffline);
                record.LastReceiptPath = intentPath;
                string emptyState = healthOffline ? "Stopped" : "Partial";
                string stoppedPath = LifecycleStorage.WriteReceipt(record, capability, "stop-result",
                    emptyState,
                    healthOffline ? null :
                        "The owned job is empty, but another process owns the configured health port.",
                    true, healthOffline);
                record.LastReceiptPath = stoppedPath;
                continueRunning = false;
                return LifecycleJson.Result(healthOffline, emptyState, false, false,
                    record.SupervisorPid, record.RootPid, record.InstanceId, stoppedPath,
                    healthOffline ? null :
                        "The owned job is empty, but another process owns the configured health port.",
                    true, healthOffline);
            }

            if (force && !record.ForceEligible)
            {
                string prematureIntentPath = LifecycleStorage.WriteReceipt(record, capability,
                    "stop-intent", "force-requested-before-timeout", null, false, healthOffline);
                record.LastReceiptPath = prematureIntentPath;
                string prematureForcePath = LifecycleStorage.WriteReceipt(record, capability,
                    "stop-result", "NeedsForce",
                    "Force-stop was refused because no prior graceful timeout was recorded.",
                    false, false);
                record.LastReceiptPath = prematureForcePath;
                return LifecycleJson.Result(false, "NeedsForce", true, true,
                    record.SupervisorPid, record.RootPid, record.InstanceId, prematureForcePath,
                    "Run the graceful stop phase before confirming force-stop.", false, false);
            }

            if (!force)
            {
                string gracefulIntentPath = LifecycleStorage.WriteReceipt(record, capability,
                    "stop-intent", "graceful-requested", null, false, healthOffline);
                record.LastReceiptPath = gracefulIntentPath;
                NativeMethods.GenerateConsoleCtrlEvent(NativeMethods.CtrlBreakEvent,
                    unchecked((uint)record.ProcessGroupId));
                if (NativeMethods.WaitForJobEmpty(job, timeout))
                {
                    healthOffline = NativeMethods.WaitForPortOffline(health.Port, 3000);
                    bool gracefulAcknowledged = LifecycleStorage.HasGracefulAcknowledgement(record);
                    string finalState = !healthOffline ? "Partial" :
                        (gracefulAcknowledged ? "Graceful" : "Stopped");
                    string gracefulPath = LifecycleStorage.WriteReceipt(record, capability,
                        "stop-result", finalState,
                        gracefulAcknowledged ? null : "The process exited without a cooperative graceful acknowledgement.",
                        true, healthOffline);
                    record.LastReceiptPath = gracefulPath;
                    record.TerminalState = healthOffline ? "Stopped" : null;
                    LifecycleStorage.WriteOwnership(record, capability);
                    continueRunning = false;
                    return LifecycleJson.Result(healthOffline, finalState,
                        false, false, record.SupervisorPid, record.RootPid, record.InstanceId,
                        gracefulPath, !healthOffline ? "The job exited but health remained online." :
                            (gracefulAcknowledged ? null : "Stopped without a cooperative graceful acknowledgement."),
                        true, healthOffline);
                }
                record.ForceSnapshot = LifecycleStorage.CaptureJobIdentitySnapshot(job);
                record.ForceSnapshotDigest = LifecycleStorage.HashProcessSnapshot(record.ForceSnapshot);
                record.ForceEligible = true;
                LifecycleStorage.WriteOwnership(record, capability);
                string needsForcePath = LifecycleStorage.WriteReceipt(record, capability,
                    "stop-result", "NeedsForce", "Graceful shutdown timed out.", false, false);
                record.LastReceiptPath = needsForcePath;
                return LifecycleJson.Result(false, "NeedsForce", true, true,
                    record.SupervisorPid, record.RootPid, record.InstanceId, needsForcePath,
                    "Graceful shutdown timed out; explicit force confirmation is required.", false, false);
            }

            string validationError;
            if (!LifecycleStorage.RevalidateBeforeForce(record, capability, job, health.Port,
                out validationError))
            {
                string refusedPath = LifecycleStorage.WriteReceipt(record, capability,
                    "stop-result", "Ambiguous", validationError, false, false);
                record.LastReceiptPath = refusedPath;
                return LifecycleJson.Result(false, "Ambiguous", false, false,
                    record.SupervisorPid, record.RootPid, record.InstanceId, refusedPath,
                    validationError, false, false);
            }
            string forceIntentPath = LifecycleStorage.WriteReceipt(record, capability,
                "stop-intent", "force-requested-after-timeout", null, false, healthOffline);
            record.LastReceiptPath = forceIntentPath;
            if (!LifecycleStorage.RevalidateBeforeForce(record, capability, job, health.Port,
                out validationError))
            {
                string changedPath = LifecycleStorage.WriteReceipt(record, capability,
                    "stop-result", "Ambiguous", validationError, false, false);
                record.LastReceiptPath = changedPath;
                return LifecycleJson.Result(false, "Ambiguous", false, false,
                    record.SupervisorPid, record.RootPid, record.InstanceId, changedPath,
                    validationError, false, false);
            }
            if (!NativeMethods.TerminateJobObject(job, 1))
            {
                throw new InvalidOperationException("The verified lifecycle job could not be terminated.",
                    new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
            }
            jobEmpty = NativeMethods.WaitForJobEmpty(job, 5000);
            healthOffline = NativeMethods.WaitForPortOffline(health.Port, 3000);
            bool forced = jobEmpty && healthOffline;
            string forcedPath = LifecycleStorage.WriteReceipt(record, capability, "stop-result",
                forced ? "Forced" : "Partial", forced ? null : "Forced stop could not be fully verified.",
                jobEmpty, healthOffline);
            record.LastReceiptPath = forcedPath;
            record.TerminalState = forced ? "Stopped" : null;
            LifecycleStorage.WriteOwnership(record, capability);
            continueRunning = !jobEmpty;
            return LifecycleJson.Result(forced, forced ? "Forced" : "Partial", !jobEmpty, !jobEmpty,
                record.SupervisorPid, record.RootPid, record.InstanceId, forcedPath,
                forced ? null : "Forced stop could not be fully verified.", jobEmpty, healthOffline);
        }

        private static void AwaitResponseAcknowledgement(Stream stream, string instanceId)
        {
            string acknowledgementText = LifecycleJson.ReadMessage(stream, 4096, 2000);
            Dictionary<string, object> acknowledgement = LifecycleJson.Parse(acknowledgementText);
            if (LifecycleJson.Integer(acknowledgement, "protocolVersion", 0) != ProtocolVersion ||
                !String.Equals(LifecycleJson.String(acknowledgement, "action"), "response-ack",
                    StringComparison.Ordinal) ||
                !String.Equals(LifecycleJson.String(acknowledgement, "instanceId"), instanceId,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The lifecycle response acknowledgement is invalid.");
            }
        }

        private static void WaitForLegacyResponseDrain(NamedPipeServerStream server)
        {
            Task drain = Task.Factory.StartNew(delegate
            {
                server.WaitForPipeDrain();
            });
            drain.ContinueWith(delegate(Task completed)
            {
                AggregateException ignored = completed.Exception;
            }, TaskContinuationOptions.OnlyOnFaulted);
            try
            {
                if (drain.Wait(2000)) { return; }
            }
            catch { return; }

            // Disconnect cancels a client that never consumes the v1 response and bounds
            // the otherwise synchronous WaitForPipeDrain operation.
            try { if (server.IsConnected) { server.Disconnect(); } }
            catch { }
            try { drain.Wait(250); }
            catch { }
        }

        private static NamedPipeServerStream CreateServer(string pipeName)
        {
            PipeSecurity security = new PipeSecurity();
            SecurityIdentifier current = WindowsIdentity.GetCurrent().User;
            security.SetAccessRuleProtection(true, false);
            security.AddAccessRule(new PipeAccessRule(current, PipeAccessRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(
                WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid, null), PipeAccessRights.FullControl,
                AccessControlType.Allow));
            return new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                PipeTransmissionMode.Byte, PipeOptions.WriteThrough | PipeOptions.Asynchronous,
                4096, 4096, security,
                HandleInheritability.None);
        }

        private static void RequireDescriptor(Dictionary<string, object> descriptor, string instanceId)
        {
            if (LifecycleJson.Integer(descriptor, "schemaVersion", 0) != 1 ||
                LifecycleJson.Integer(descriptor, "protocolVersion", 0) != ProtocolVersion ||
                !String.Equals(LifecycleJson.String(descriptor, "instanceId"), instanceId,
                    StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The lifecycle descriptor is invalid.");
            }
        }

        private static string ReadBoundedUtf8Descriptor(Stream stream, int maximumBytes)
        {
            List<byte> bytes = new List<byte>();
            int wireBytes = 0;
            while (true)
            {
                int value = stream.ReadByte();
                if (value < 0 || value == 0x0a) { break; }
                wireBytes++;
                // Include a possible UTF-8 BOM and the one CR from WriteLine in
                // the raw cap; never permit a CR flood to evade it.
                if (wireBytes > maximumBytes + 5)
                {
                    throw new InvalidOperationException("The lifecycle descriptor is too large.");
                }
                bytes.Add((byte)value);
            }
            if (bytes.Count > 0 && bytes[bytes.Count - 1] == 0x0d) { bytes.RemoveAt(bytes.Count - 1); }
            int offset = 0;
            if (bytes.Count >= 3 && bytes[0] == 0xef && bytes[1] == 0xbb && bytes[2] == 0xbf)
            {
                offset = 3;
            }
            int length = bytes.Count - offset;
            if (length == 0) { throw new InvalidOperationException("The lifecycle descriptor was empty."); }
            if (length > maximumBytes)
            {
                throw new InvalidOperationException("The lifecycle descriptor is too large.");
            }
            try { return StrictUtf8.GetString(bytes.ToArray(), offset, length); }
            catch (DecoderFallbackException)
            {
                throw new InvalidOperationException("The lifecycle descriptor encoding is invalid.");
            }
        }
    }

    internal sealed class LifecycleRecord
    {
        public string InstanceDirectory;
        public string InstanceId;
        public string ItemId;
        public string ContractDigest;
        public string HealthUrl;
        public string PipeName;
        public int SupervisorPid;
        public long SupervisorCreationTime;
        public string SupervisorImage;
        public string SupervisorImageHash;
        public int RootPid;
        public long RootCreationTime;
        public string RootImage;
        public string RootImageHash;
        public string CommandHash;
        public int ProcessGroupId;
        public bool ForceEligible;
        public string GracefulAckPath;
        public string GracefulAckToken;
        public string GracefulAckTokenDigest;
        public string TerminalState;
        public Dictionary<int, ProcessIdentity> ForceSnapshot;
        public string ForceSnapshotDigest;
        public string LastReceiptPath;
        public string PreviousReceiptHash;
        public string Hmac;
    }

    internal sealed class ProcessIdentity
    {
        public int ProcessId;
        public long CreationTime;
        public string ImagePath;
        public string ImageHash;
    }

    internal sealed class V2LifecycleConfiguration
    {
        public string InstanceId;
        public string ItemId;
        public string ContractDigest;
        public string[] HealthUrls;
        public string StopTarget;
        public string StopTargetHash;
        public string StopArgs;
        // Node helpers are bound to the exact interpreter selected at startup.  This
        // prevents a later package-runtime replacement from changing an authenticated action.
        public string NodeRuntime;
        public string NodeRuntimeHash;
    }

    internal sealed class LifecyclePaths
    {
        public string LifecycleRoot;
        public string ItemDirectory;
        public string InstanceDirectory;
        public string OwnershipPath;
        public string CredentialPath;
        public string ActivePath;
        public string ReceiptDirectory;
    }

    internal static class LifecycleStorage
    {
        private const string OwnershipFile = "ownership.json";
        private const string CredentialFile = "credential.dpapi";
        private const string V2ConfigurationFile = "v2-contract.json";
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer
        {
            MaxJsonLength = 64 * 1024,
            RecursionLimit = 12
        };

        public static string NormalizeItemId(string itemId)
        {
            if (String.IsNullOrWhiteSpace(itemId) || itemId.Length > 128)
            {
                throw new ArgumentException("itemId is required and must be at most 128 characters.");
            }
            using (SHA256 algorithm = SHA256.Create())
            {
                return Hex(algorithm.ComputeHash(Encoding.UTF8.GetBytes(itemId)));
            }
        }

        public static string RequireNormalizedItemId(string itemId)
        {
            if (String.IsNullOrEmpty(itemId) || itemId.Length != 64 ||
                itemId.Any(delegate(char c)
                {
                    return !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'));
                }))
            {
                throw new ArgumentException("The normalized lifecycle item identifier is invalid.");
            }
            return itemId;
        }

        public static bool IsOpaqueInstanceId(string value)
        {
            Guid parsed;
            return !String.IsNullOrEmpty(value) && value.Length == 32 &&
                Guid.TryParseExact(value, "N", out parsed);
        }

        public static string RequireDigest(string value, string name)
        {
            if (String.IsNullOrWhiteSpace(value) || value.Length > 256 ||
                value.Any(delegate(char c) { return !(Char.IsLetterOrDigit(c) || c == '-' || c == '_' || c == ':'); }))
            {
                throw new ArgumentException(name + " is invalid.");
            }
            return value;
        }

        public static void ValidateLaunchContract(string hostPath, string executable,
            string arguments)
        {
            string safeHost = RequireFile(hostPath, "hostPath");
            string safeExecutable = RequireFile(executable, "executable");
            string argumentText = arguments ?? String.Empty;
            if (argumentText.IndexOf('\0') >= 0 || argumentText.IndexOf('\r') >= 0 ||
                argumentText.IndexOf('\n') >= 0)
            {
                throw new ArgumentException("Lifecycle arguments contain unsupported control characters.");
            }
            string extension = Path.GetExtension(safeExecutable);
            if (String.Equals(extension, ".cmd", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(extension, ".bat", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("Batch files cannot be used as direct lifecycle executables.");
            }
            string systemCmd = RequireFile(Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe"),
                "systemCommandProcessor");
            bool namedCmd = String.Equals(Path.GetFileName(safeExecutable), "cmd.exe",
                StringComparison.OrdinalIgnoreCase);
            bool isSystemCmd = String.Equals(safeExecutable, systemCmd,
                StringComparison.OrdinalIgnoreCase);
            if (namedCmd && !isSystemCmd)
            {
                throw new ArgumentException("Only the canonical System32 command processor is allowed.");
            }
            if (!isSystemCmd) { return; }

            Match match = Regex.Match(argumentText,
                "^/d /s /c \"\"(?<runner>[A-Za-z]:\\\\[^\"\\r\\n]*)\" run \"(?<script>[A-Za-z0-9:_-]+)\"\"$",
                RegexOptions.CultureInvariant);
            if (!match.Success)
            {
                throw new ArgumentException("The command processor arguments do not match the fixed package-runner grammar.");
            }
            string runnerText = match.Groups["runner"].Value;
            if (runnerText.IndexOfAny(new char[] { '&', '|', '<', '>', '^', '!', '(', ')', '%' }) >= 0)
            {
                throw new ArgumentException("The package-runner path contains unsupported shell characters.");
            }
            string runner = RequireFile(runnerText, "packageRunner");
            string hostRoot = Path.GetDirectoryName(safeHost);
            string expectedNpm = Path.Combine(hostRoot, "runtime", "node", "npm.cmd");
            string expectedPnpm = Path.Combine(hostRoot, "runtime", "pnpm", "pnpm.cmd");
            if (!String.Equals(runner, Path.GetFullPath(expectedNpm), StringComparison.OrdinalIgnoreCase) &&
                !String.Equals(runner, Path.GetFullPath(expectedPnpm), StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("The package runner is outside the supervisor host runtime.");
            }
        }

        public static Uri RequireLoopbackHealthUrl(string value)
        {
            Uri uri;
            if (!Uri.TryCreate(value, UriKind.Absolute, out uri) ||
                !(uri.Scheme == Uri.UriSchemeHttp || uri.Scheme == Uri.UriSchemeHttps) ||
                !uri.IsLoopback || !String.IsNullOrEmpty(uri.UserInfo) || uri.Port < 1)
            {
                throw new ArgumentException("healthUrl must be an absolute loopback HTTP or HTTPS URL.");
            }
            return uri;
        }

        public static string RequireFile(string path, string name)
        {
            string full = RequirePath(path, name);
            if (!File.Exists(full)) { throw new FileNotFoundException(name + " was not found.", full); }
            EnsureNoReparsePoints(full, false);
            return full;
        }

        public static string RequireDirectory(string path, string name, bool create)
        {
            string full = RequirePath(path, name);
            if (create && !Directory.Exists(full))
            {
                EnsureExistingAncestorsNoReparse(full);
                Directory.CreateDirectory(full);
            }
            if (!Directory.Exists(full)) { throw new DirectoryNotFoundException(name + " was not found: " + full); }
            EnsureNoReparsePoints(full, true);
            return full;
        }

        private static string RequirePath(string path, string name)
        {
            if (String.IsNullOrWhiteSpace(path) || !Path.IsPathRooted(path))
            {
                throw new ArgumentException(name + " must be an absolute local path.");
            }
            string full = Path.GetFullPath(path);
            if (full.StartsWith("\\\\", StringComparison.Ordinal) ||
                full.StartsWith("\\\\?\\", StringComparison.Ordinal))
            {
                throw new ArgumentException(name + " must not be a network or device path.");
            }
            return full;
        }

        private static void EnsureNoReparsePoints(string path, bool isDirectory)
        {
            string cursor = isDirectory ? path : Path.GetDirectoryName(path);
            while (!String.IsNullOrEmpty(cursor))
            {
                DirectoryInfo directory = new DirectoryInfo(cursor);
                if (directory.Exists && (directory.Attributes & FileAttributes.ReparsePoint) != 0)
                {
                    throw new InvalidOperationException("Lifecycle paths must not traverse reparse points.");
                }
                DirectoryInfo parent = directory.Parent;
                if (parent == null) { break; }
                cursor = parent.FullName;
            }
            if (!isDirectory && (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            {
                throw new InvalidOperationException("Lifecycle executables must not be reparse points.");
            }
        }

        private static void EnsureExistingAncestorsNoReparse(string path)
        {
            string cursor = Path.GetDirectoryName(path.TrimEnd(Path.DirectorySeparatorChar));
            while (!String.IsNullOrEmpty(cursor))
            {
                DirectoryInfo directory = new DirectoryInfo(cursor);
                if (directory.Exists)
                {
                    EnsureNoReparsePoints(directory.FullName, true);
                    return;
                }
                DirectoryInfo parent = directory.Parent;
                if (parent == null) { break; }
                cursor = parent.FullName;
            }
            throw new InvalidOperationException("No verified local ancestor was available for lifecycle storage.");
        }

        public static LifecyclePaths CreateInstance(string runtimeRoot, string itemId, string instanceId)
        {
            string lifecycle = Path.Combine(runtimeRoot, "managed-services");
            string item = Path.Combine(lifecycle, itemId);
            string instance = Path.Combine(item, instanceId);
            RequireDirectory(runtimeRoot, "runtimeRoot", false);
            CreateVerifiedDirectory(lifecycle);
            CreateVerifiedDirectory(item);
            CreateVerifiedDirectory(instance);
            CreateVerifiedDirectory(Path.Combine(instance, "receipts"));
            ApplyDirectoryAcl(lifecycle);
            ApplyDirectoryAcl(item);
            ApplyDirectoryAcl(instance);
            ApplyDirectoryAcl(Path.Combine(instance, "receipts"));
            return FromInstanceDirectory(instance, itemId, instanceId);
        }

        public static void ValidateLifecyclePathBudget(string runtimeRoot)
        {
            // The Desktop PowerShell client uses legacy .NET Framework file APIs.
            // Refuse before launching rather than lose receipts after a path error.
            string longest = Path.Combine(runtimeRoot, "managed-services", new string('a', 64),
                new string('b', 32), "ownership.json.previous-" + new string('c', 32));
            if (longest.Length >= 260)
            {
                throw new ArgumentException("The Widget state directory is too long for lifecycle evidence. " +
                    "Select a shorter StatePath before starting a managed server.");
            }
        }

        private static void CreateVerifiedDirectory(string path)
        {
            if (!Directory.Exists(path))
            {
                EnsureExistingAncestorsNoReparse(path);
                Directory.CreateDirectory(path);
            }
            EnsureNoReparsePoints(path, true);
        }

        public static LifecyclePaths FromInstanceDirectory(string instanceDirectory, string itemId, string instanceId)
        {
            if (!IsOpaqueInstanceId(instanceId) ||
                !String.Equals(Path.GetFileName(instanceDirectory), instanceId, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(Path.GetFileName(Path.GetDirectoryName(instanceDirectory)), itemId,
                    StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException("The lifecycle instance directory does not match its identifiers.");
            }
            LifecyclePaths paths = new LifecyclePaths();
            paths.InstanceDirectory = instanceDirectory;
            paths.ItemDirectory = Path.GetDirectoryName(instanceDirectory);
            paths.LifecycleRoot = Path.GetDirectoryName(paths.ItemDirectory);
            paths.OwnershipPath = Path.Combine(instanceDirectory, OwnershipFile);
            paths.CredentialPath = Path.Combine(instanceDirectory, CredentialFile);
            paths.ActivePath = Path.Combine(paths.ItemDirectory, "active.json");
            paths.ReceiptDirectory = Path.Combine(instanceDirectory, "receipts");
            return paths;
        }

        public static byte[] CreateAndProtectCapability(LifecyclePaths paths)
        {
            byte[] capability = new byte[32];
            using (RandomNumberGenerator generator = RandomNumberGenerator.Create())
            {
                generator.GetBytes(capability);
            }
            byte[] protectedValue = ProtectedData.Protect(capability, null, DataProtectionScope.CurrentUser);
            WriteNewFile(paths.CredentialPath, protectedValue);
            ApplyFileAcl(paths.CredentialPath);
            return capability;
        }

        public static byte[] ReadCapability(string instanceDirectory)
        {
            string path = Path.Combine(instanceDirectory, CredentialFile);
            if (!File.Exists(path) || (new FileInfo(path)).Length > 4096)
            {
                throw new InvalidOperationException("The protected lifecycle capability is unavailable.");
            }
            EnsureNoReparsePoints(path, false);
            return ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        }

        public static LifecycleRecord CreateRecord(
            LifecyclePaths paths, string itemId, string instanceId, string contractDigest,
            string healthUrl, string pipeName, byte[] capability, NativeProcess root,
            string executable, string arguments, string workingDirectory)
        {
            Process current = Process.GetCurrentProcess();
            LifecycleRecord record = new LifecycleRecord();
            record.InstanceDirectory = paths.InstanceDirectory;
            record.InstanceId = instanceId;
            record.ItemId = itemId;
            record.ContractDigest = contractDigest;
            record.HealthUrl = healthUrl;
            record.PipeName = pipeName;
            record.SupervisorPid = current.Id;
            record.SupervisorCreationTime = NativeMethods.GetCreationFileTime(current.Handle);
            record.SupervisorImage = RequireFile(current.MainModule.FileName, "supervisorImage");
            record.SupervisorImageHash = HashFile(record.SupervisorImage);
            record.RootPid = root.ProcessId;
            record.RootCreationTime = NativeMethods.GetCreationFileTime(root.ProcessHandle);
            record.RootImage = RequireFile(NativeMethods.GetProcessImagePath(root.ProcessHandle), "rootImage");
            record.RootImageHash = HashFile(record.RootImage);
            record.CommandHash = HashText(executable + "\0" + arguments + "\0" + workingDirectory);
            record.ProcessGroupId = root.ProcessId;
            record.ForceEligible = false;
            return record;
        }

        public static void WriteOwnership(LifecycleRecord record, byte[] capability)
        {
            Dictionary<string, object> data = ToDictionary(record, false);
            string canonical = Json.Serialize(data);
            record.Hmac = Hmac(capability, canonical);
            data["hmacSha256"] = record.Hmac;
            AtomicWrite(Path.Combine(record.InstanceDirectory, OwnershipFile), Json.Serialize(data));
        }

        public static void BindOrVerifyV2Configuration(LifecycleRecord record,
            IList<Uri> healthUrls, string stopTarget, string stopArgs)
        {
            if (record == null) { throw new ArgumentNullException("record"); }
            string[] urls = healthUrls.Select(delegate(Uri value) { return value.AbsoluteUri; }).ToArray();
            string target = NormalizeV2StopTarget(stopTarget);
            string targetHash = String.Equals(target, "@managed-signal", StringComparison.Ordinal)
                ? null : HashFile(target);
            string args = stopArgs ?? String.Empty;
            string configurationPath = Path.Combine(record.InstanceDirectory, V2ConfigurationFile);
            if (File.Exists(configurationPath))
            {
                VerifyV2Configuration(record, healthUrls, stopTarget, stopArgs, true);
                return;
            }
            if (!String.Equals(record.HealthUrl, urls[0], StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The v2 primary health URL did not match the owned lifecycle record.");
            }
            V2LifecycleConfiguration configuration = new V2LifecycleConfiguration();
            configuration.InstanceId = record.InstanceId;
            configuration.ItemId = record.ItemId;
            configuration.ContractDigest = record.ContractDigest;
            configuration.HealthUrls = urls;
            configuration.StopTarget = target;
            configuration.StopTargetHash = targetHash;
            configuration.StopArgs = args;
            if (IsNodeStopTarget(target))
            {
                configuration.NodeRuntime = ResolveNodeRuntimeForV2Binding(record);
                configuration.NodeRuntimeHash = HashFile(configuration.NodeRuntime);
            }
            WriteV2Configuration(configurationPath, configuration,
                ReadCapability(record.InstanceDirectory));
        }

        public static V2LifecycleConfiguration VerifyV2Configuration(LifecycleRecord record, IList<Uri> healthUrls,
            string stopTarget, string stopArgs, bool requireStopTarget)
        {
            if (record == null)
            {
                throw new InvalidOperationException("The owned lifecycle record is unavailable.");
            }
            V2LifecycleConfiguration configuration = ReadV2Configuration(
                Path.Combine(record.InstanceDirectory, V2ConfigurationFile),
                ReadCapability(record.InstanceDirectory));
            if (!String.Equals(configuration.InstanceId, record.InstanceId, StringComparison.Ordinal) ||
                !String.Equals(configuration.ItemId, record.ItemId, StringComparison.Ordinal) ||
                !String.Equals(configuration.ContractDigest, record.ContractDigest, StringComparison.Ordinal) ||
                configuration.HealthUrls == null || configuration.HealthUrls.Length < 1 ||
                String.IsNullOrEmpty(configuration.StopTarget) || configuration.StopArgs == null)
            {
                throw new InvalidOperationException("The authenticated v2 lifecycle configuration did not match the owned record.");
            }
            if (configuration.HealthUrls.Length != healthUrls.Count ||
                !String.Equals(record.HealthUrl, configuration.HealthUrls[0], StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The persisted v2 health configuration is invalid.");
            }
            for (int index = 0; index < healthUrls.Count; index++)
            {
                if (!String.Equals(configuration.HealthUrls[index], healthUrls[index].AbsoluteUri,
                    StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("The requested health URLs did not match the owned v2 configuration.");
                }
            }
            bool managedSignal = String.Equals(configuration.StopTarget, "@managed-signal", StringComparison.Ordinal);
            if (managedSignal)
            {
                if (configuration.StopTargetHash != null || !String.IsNullOrEmpty(configuration.StopArgs))
                {
                    throw new InvalidOperationException("The persisted managed-signal stop configuration is invalid.");
                }
            }
            else
            {
                string currentTarget = RequireFile(configuration.StopTarget, "bound stopTarget");
                if (!String.Equals(currentTarget, configuration.StopTarget, StringComparison.OrdinalIgnoreCase) ||
                    String.IsNullOrEmpty(configuration.StopTargetHash) ||
                    !FixedEqualsHex(HashFile(currentTarget), configuration.StopTargetHash))
                {
                    throw new InvalidOperationException("The bound stop script changed after v2 startup.");
                }
            }
            if (IsNodeStopTarget(configuration.StopTarget))
            {
                string nodeRuntime = RequireFile(configuration.NodeRuntime, "bound Node runtime");
                if (String.IsNullOrEmpty(configuration.NodeRuntimeHash) ||
                    !FixedEqualsHex(HashFile(nodeRuntime), configuration.NodeRuntimeHash))
                {
                    throw new InvalidOperationException("The bound Node runtime changed after v2 startup.");
                }
            }
            else if (!String.IsNullOrEmpty(configuration.NodeRuntime) ||
                !String.IsNullOrEmpty(configuration.NodeRuntimeHash))
            {
                throw new InvalidOperationException("The v2 stop configuration has an unexpected Node runtime binding.");
            }
            if (!requireStopTarget) { return configuration; }
            string requestedTarget = NormalizeV2StopTarget(stopTarget);
            if (!String.Equals(configuration.StopTarget, requestedTarget, StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(configuration.StopArgs, stopArgs ?? String.Empty, StringComparison.Ordinal))
            {
                throw new InvalidOperationException("The requested stop target did not match the owned v2 configuration.");
            }
            return configuration;
        }

        private static bool IsNodeStopTarget(string stopTarget)
        {
            string extension = Path.GetExtension(stopTarget ?? String.Empty);
            return String.Equals(extension, ".js", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(extension, ".mjs", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(extension, ".cjs", StringComparison.OrdinalIgnoreCase);
        }

        private static string ResolveNodeRuntimeForV2Binding(LifecycleRecord record)
        {
            string supervisorError;
            if (!ValidateSupervisorIdentity(record, out supervisorError))
            {
                throw new InvalidOperationException(supervisorError);
            }
            string rootImage = RequireFile(record.RootImage, "rootImage");
            bool rootIsNode = String.Equals(Path.GetFileName(rootImage), "node.exe",
                StringComparison.OrdinalIgnoreCase);
            if (rootIsNode)
            {
                if (String.IsNullOrEmpty(record.RootImageHash) ||
                    !FixedEqualsHex(HashFile(rootImage), record.RootImageHash))
                {
                    throw new InvalidOperationException("The recorded Node root image did not match the trusted launch record.");
                }
                return rootImage;
            }
            string supervisorImage = RequireFile(record.SupervisorImage, "supervisorImage");
            return RequireFile(Path.Combine(Path.GetDirectoryName(supervisorImage), "runtime", "node", "node.exe"),
                "bundledNodeRuntime");
        }

        private static string NormalizeV2StopTarget(string stopTarget)
        {
            if (String.Equals(stopTarget, "@managed-signal", StringComparison.Ordinal))
            {
                return stopTarget;
            }
            return RequireFile(stopTarget, "stopTarget");
        }

        private static void WriteV2Configuration(string path, V2LifecycleConfiguration configuration,
            byte[] capability)
        {
            Dictionary<string, object> data = new Dictionary<string, object>();
            data["schemaVersion"] = 1;
            data["instanceId"] = configuration.InstanceId;
            data["itemId"] = configuration.ItemId;
            data["contractDigest"] = configuration.ContractDigest;
            data["healthUrls"] = configuration.HealthUrls;
            data["stopTarget"] = configuration.StopTarget;
            data["stopTargetSha256"] = configuration.StopTargetHash;
            data["stopArgs"] = configuration.StopArgs;
            data["nodeRuntime"] = configuration.NodeRuntime;
            data["nodeRuntimeSha256"] = configuration.NodeRuntimeHash;
            string canonical = Json.Serialize(data);
            data["hmacSha256"] = Hmac(capability, canonical);
            AtomicWrite(path, Json.Serialize(data));
        }

        private static V2LifecycleConfiguration ReadV2Configuration(string path, byte[] capability)
        {
            if (!File.Exists(path))
            {
                throw new InvalidOperationException("The owned lifecycle record has no complete v2 configuration.");
            }
            Dictionary<string, object> data = ReadJsonFile(path);
            string hmac = LifecycleJson.String(data, "hmacSha256");
            data.Remove("hmacSha256");
            if (!FixedEqualsHex(hmac, Hmac(capability, Json.Serialize(data))) ||
                LifecycleJson.Integer(data, "schemaVersion", 0) != 1)
            {
                throw new InvalidOperationException("The v2 lifecycle configuration failed authentication.");
            }
            object rawUrls;
            if (!data.TryGetValue("healthUrls", out rawUrls) || rawUrls == null || rawUrls is string)
            {
                throw new InvalidOperationException("The v2 health URL configuration is invalid.");
            }
            System.Collections.IEnumerable values = rawUrls as System.Collections.IEnumerable;
            if (values == null) { throw new InvalidOperationException("The v2 health URL configuration is invalid."); }
            List<string> urls = new List<string>();
            foreach (object value in values)
            {
                urls.Add(RequireLoopbackHealthUrl(value as string).AbsoluteUri);
            }
            V2LifecycleConfiguration result = new V2LifecycleConfiguration();
            result.InstanceId = LifecycleJson.String(data, "instanceId");
            result.ItemId = LifecycleJson.String(data, "itemId");
            result.ContractDigest = LifecycleJson.String(data, "contractDigest");
            result.HealthUrls = urls.ToArray();
            result.StopTarget = LifecycleJson.String(data, "stopTarget");
            result.StopTargetHash = LifecycleJson.String(data, "stopTargetSha256");
            result.StopArgs = LifecycleJson.String(data, "stopArgs");
            result.NodeRuntime = LifecycleJson.String(data, "nodeRuntime");
            result.NodeRuntimeHash = LifecycleJson.String(data, "nodeRuntimeSha256");
            return result;
        }

        public static void WriteActivePointer(LifecyclePaths paths, LifecycleRecord record, byte[] capability)
        {
            Dictionary<string, object> pointer = new Dictionary<string, object>();
            pointer["schemaVersion"] = 1;
            pointer["instanceId"] = record.InstanceId;
            pointer["instanceDirectory"] = record.InstanceDirectory;
            string canonical = Json.Serialize(pointer);
            pointer["hmacSha256"] = Hmac(capability, canonical);
            AtomicWrite(paths.ActivePath, Json.Serialize(pointer));
        }

        public static bool TryReadActive(string runtimeRoot, string itemId,
            out LifecycleRecord record, out string error)
        {
            record = null;
            error = null;
            string itemDirectory = Path.Combine(runtimeRoot, "managed-services", itemId);
            string activePath = Path.Combine(itemDirectory, "active.json");
            if (!File.Exists(activePath)) { return false; }
            try
            {
                Dictionary<string, object> pointer = ReadJsonFile(activePath);
                string instanceId = LifecycleJson.String(pointer, "instanceId");
                string instanceDirectory = LifecycleJson.String(pointer, "instanceDirectory");
                string expectedInstanceDirectory = Path.GetFullPath(
                    Path.Combine(itemDirectory, instanceId ?? String.Empty));
                if (!String.Equals(Path.GetFullPath(instanceDirectory ?? String.Empty),
                    expectedInstanceDirectory, StringComparison.OrdinalIgnoreCase))
                {
                    throw new InvalidOperationException(
                        "The active lifecycle pointer escaped its expected item directory.");
                }
                LifecyclePaths paths = FromInstanceDirectory(
                    RequireDirectory(instanceDirectory, "instanceDirectory", false), itemId, instanceId);
                byte[] capability = ReadCapability(paths.InstanceDirectory);
                string pointerHmac = LifecycleJson.String(pointer, "hmacSha256");
                pointer.Remove("hmacSha256");
                if (!FixedEqualsHex(pointerHmac, Hmac(capability, Json.Serialize(pointer))))
                {
                    throw new InvalidOperationException("The active lifecycle pointer failed authentication.");
                }
                Dictionary<string, object> data = ReadJsonFile(paths.OwnershipPath);
                string recordHmac = LifecycleJson.String(data, "hmacSha256");
                data.Remove("hmacSha256");
                if (!FixedEqualsHex(recordHmac, Hmac(capability, Json.Serialize(data))))
                {
                    throw new InvalidOperationException("The lifecycle ownership record failed authentication.");
                }
                record = FromDictionary(data);
                record.Hmac = recordHmac;
                if (!String.Equals(record.ItemId, itemId, StringComparison.Ordinal) ||
                    !String.Equals(record.InstanceId, instanceId, StringComparison.Ordinal))
                {
                    throw new InvalidOperationException("The lifecycle ownership identifiers did not match.");
                }
                return true;
            }
            catch (Exception exception)
            {
                error = "Lifecycle ownership could not be verified: " + exception.Message;
                return false;
            }
        }

        public static bool ValidateSupervisorIdentity(LifecycleRecord record, out string error)
        {
            error = null;
            IntPtr process = NativeMethods.OpenProcess(
                NativeMethods.ProcessQueryLimitedInformation | NativeMethods.Synchronize,
                false, record.SupervisorPid);
            if (process == IntPtr.Zero)
            {
                error = "The recorded lifecycle supervisor is not running.";
                return false;
            }
            try
            {
                long creation = NativeMethods.GetCreationFileTime(process);
                string image = NativeMethods.GetProcessImagePath(process);
                if (creation != record.SupervisorCreationTime ||
                    !String.Equals(image, record.SupervisorImage, StringComparison.OrdinalIgnoreCase) ||
                    !FixedEqualsHex(HashFile(image), record.SupervisorImageHash))
                {
                    error = "The live lifecycle supervisor identity did not match the ownership record.";
                    return false;
                }
                return true;
            }
            catch (Exception exception)
            {
                error = "The live lifecycle supervisor could not be verified: " + exception.Message;
                return false;
            }
            finally { NativeMethods.CloseHandle(process); }
        }

        public static bool IsExactProcessIdentity(int processId, long creationTime, string imagePath)
        {
            IntPtr process = NativeMethods.OpenProcess(
                NativeMethods.ProcessQueryLimitedInformation | NativeMethods.Synchronize,
                false, processId);
            if (process == IntPtr.Zero) { return false; }
            try
            {
                return NativeMethods.GetCreationFileTime(process) == creationTime &&
                    String.Equals(NativeMethods.GetProcessImagePath(process), imagePath,
                        StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
            finally { NativeMethods.CloseHandle(process); }
        }

        public static bool TryRecoverStaleStopped(string runtimeRoot, string itemId,
            LifecycleRecord record, int recordedHealthPort, int requestedHealthPort,
            bool stopRequest, out string result)
        {
            result = null;
            Mutex recoveryMutex = null;
            bool recoveryLockTaken = false;
            try
            {
                if (!NativeMethods.IsExactProcessAbsentOrTerminated(
                        record.SupervisorPid, record.SupervisorCreationTime) ||
                    !NativeMethods.IsExactProcessAbsentOrTerminated(
                        record.RootPid, record.RootCreationTime) ||
                    !NativeMethods.IsNamedPipeAbsent(record.PipeName, 250) ||
                    NativeMethods.GetListeningProcessIds(recordedHealthPort).Count != 0)
                {
                    return false;
                }
                recoveryMutex = new Mutex(false, "Local\\WorkspaceWidget.ManagedService.Recovery." +
                    itemId + "." + record.InstanceId);
                try { recoveryLockTaken = recoveryMutex.WaitOne(5000); }
                catch (AbandonedMutexException) { recoveryLockTaken = true; }
                if (!recoveryLockTaken) { return false; }

                LifecycleRecord current;
                string readError;
                if (!TryReadActive(runtimeRoot, itemId, out current, out readError) ||
                    current == null ||
                    !String.Equals(current.InstanceId, record.InstanceId, StringComparison.Ordinal) ||
                    !String.Equals(current.InstanceDirectory, record.InstanceDirectory,
                        StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                if (String.Equals(current.TerminalState, "Stopped", StringComparison.Ordinal))
                {
                    bool terminalPortOffline =
                        NativeMethods.GetListeningProcessIds(requestedHealthPort).Count == 0;
                    result = LifecycleJson.ResultWithEvidence(
                        !stopRequest || terminalPortOffline,
                        terminalPortOffline ? "Stopped" : "RunningUnowned", false, false,
                        current.SupervisorPid, current.RootPid, current.InstanceId,
                        current.LastReceiptPath,
                        terminalPortOffline ? null :
                            "The owned lifecycle is terminal, but another process owns the configured health port.",
                        true, terminalPortOffline, "persisted-state", false);
                    return true;
                }

                byte[] capability = ReadCapability(current.InstanceDirectory);
                if (!NativeMethods.IsExactProcessAbsentOrTerminated(
                        current.SupervisorPid, current.SupervisorCreationTime) ||
                    !NativeMethods.IsExactProcessAbsentOrTerminated(
                        current.RootPid, current.RootCreationTime) ||
                    !NativeMethods.IsNamedPipeAbsent(current.PipeName, 250) ||
                    NativeMethods.GetListeningProcessIds(recordedHealthPort).Count != 0)
                {
                    return false;
                }
                current.TerminalState = "Stopped";
                current.ForceEligible = false;
                string receiptPath = WriteReceiptWithEvidence(current, capability, "recovery",
                    "Stopped", "Authenticated stale ownership was terminalized after all recorded identities and endpoints were absent.",
                    true, true, "inferred-absent", true);
                bool requestedPortOffline =
                    NativeMethods.GetListeningProcessIds(requestedHealthPort).Count == 0;
                result = LifecycleJson.ResultWithEvidence(
                    !stopRequest || requestedPortOffline,
                    requestedPortOffline ? "Stopped" : "RunningUnowned", false, false,
                    current.SupervisorPid, current.RootPid, current.InstanceId, receiptPath,
                    requestedPortOffline ? null :
                        "The stale owned lifecycle was terminalized, but another process owns the requested health port.",
                    true, requestedPortOffline, "inferred-absent", true);
                return true;
            }
            catch
            {
                result = null;
                return false;
            }
            finally
            {
                if (recoveryLockTaken && recoveryMutex != null) { recoveryMutex.ReleaseMutex(); }
                if (recoveryMutex != null) { recoveryMutex.Dispose(); }
            }
        }

        public static bool TryRecoverCompletedStopResponse(string runtimeRoot, string itemId,
            LifecycleRecord requestedRecord, IOException responseError, out string result)
        {
            result = null;
            try
            {
                if (responseError == null) { return false; }
                LifecycleRecord current;
                string readError;
                if (!TryReadActive(runtimeRoot, itemId, out current, out readError) ||
                    current == null ||
                    !String.Equals(current.InstanceId, requestedRecord.InstanceId,
                        StringComparison.Ordinal) ||
                    !String.Equals(current.InstanceDirectory, requestedRecord.InstanceDirectory,
                        StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(current.ContractDigest, requestedRecord.ContractDigest,
                        StringComparison.Ordinal) ||
                    !String.Equals(current.HealthUrl, requestedRecord.HealthUrl,
                        StringComparison.Ordinal) ||
                    !String.Equals(current.TerminalState, "Stopped", StringComparison.Ordinal) ||
                    String.IsNullOrEmpty(current.LastReceiptPath) ||
                    String.Equals(current.LastReceiptPath, requestedRecord.LastReceiptPath,
                        StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }

                string receiptPath = RequireFile(current.LastReceiptPath, "stop receipt");
                string expectedReceiptDirectory = Path.GetFullPath(
                    Path.Combine(current.InstanceDirectory, "receipts"));
                if (!String.Equals(Path.GetDirectoryName(receiptPath), expectedReceiptDirectory,
                        StringComparison.OrdinalIgnoreCase))
                {
                    return false;
                }
                Dictionary<string, object> receipt = ReadJsonFile(receiptPath);
                string receiptHmac = LifecycleJson.String(receipt, "hmacSha256");
                receipt.Remove("hmacSha256");
                byte[] capability = ReadCapability(current.InstanceDirectory);
                string receiptId = LifecycleJson.String(receipt, "receiptId");
                string receiptResult = LifecycleJson.String(receipt, "result");
                if (!FixedEqualsHex(receiptHmac, Hmac(capability, Json.Serialize(receipt))) ||
                    !IsOpaqueInstanceId(receiptId) ||
                    !String.Equals(Path.GetFileName(receiptPath), receiptId + ".json",
                        StringComparison.OrdinalIgnoreCase) ||
                    !String.Equals(LifecycleJson.String(receipt, "instanceId"), current.InstanceId,
                        StringComparison.Ordinal) ||
                    !String.Equals(LifecycleJson.String(receipt, "itemId"), current.ItemId,
                        StringComparison.Ordinal) ||
                    !String.Equals(LifecycleJson.String(receipt, "operation"), "stop-result",
                        StringComparison.Ordinal) ||
                    !(String.Equals(receiptResult, "Graceful", StringComparison.Ordinal) ||
                      String.Equals(receiptResult, "Stopped", StringComparison.Ordinal) ||
                      String.Equals(receiptResult, "Forced", StringComparison.Ordinal)) ||
                    !LifecycleJson.Boolean(receipt, "jobEmpty") ||
                    !LifecycleJson.Boolean(receipt, "healthOffline") ||
                    !FixedEqualsHex(HashFile(receiptPath), current.PreviousReceiptHash))
                {
                    return false;
                }
                int healthPort = RequireLoopbackHealthUrl(current.HealthUrl).Port;
                if (!WaitForCompletedStopAbsence(current, healthPort, 3000)) { return false; }
                result = LifecycleJson.ResultWithRecoveredResponse(true, receiptResult, false, false,
                    current.SupervisorPid, current.RootPid, current.InstanceId, receiptPath,
                    null, true, true,
                    LifecycleJson.String(receipt, "jobObservation") ?? "direct-job-query",
                    false, true);
                return true;
            }
            catch
            {
                result = null;
                return false;
            }
        }

        private static bool WaitForCompletedStopAbsence(LifecycleRecord record, int healthPort,
            int timeoutMilliseconds)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (true)
            {
                if (NativeMethods.IsExactProcessAbsentOrTerminated(
                        record.SupervisorPid, record.SupervisorCreationTime) &&
                    NativeMethods.IsExactProcessAbsentOrTerminated(
                        record.RootPid, record.RootCreationTime) &&
                    NativeMethods.GetListeningProcessIds(healthPort).Count == 0)
                {
                    return true;
                }
                if (watch.ElapsedMilliseconds >= timeoutMilliseconds) { return false; }
                Thread.Sleep(50);
            }
        }

        public static bool RevalidateBeforeForce(LifecycleRecord record, byte[] capability,
            IntPtr job, int healthPort, out string error)
        {
            error = null;
            if (!record.ForceEligible)
            {
                error = "Force-stop is not eligible until a graceful timeout is recorded.";
                return false;
            }
            if (!ValidateSupervisorIdentity(record, out error)) { return false; }
            Dictionary<string, object> persisted = ReadJsonFile(
                Path.Combine(record.InstanceDirectory, OwnershipFile));
            string hmac = LifecycleJson.String(persisted, "hmacSha256");
            persisted.Remove("hmacSha256");
            if (!FixedEqualsHex(hmac, Hmac(capability, Json.Serialize(persisted))) ||
                !String.Equals(LifecycleJson.String(persisted, "instanceId"), record.InstanceId,
                    StringComparison.Ordinal) ||
                !String.Equals(LifecycleJson.String(persisted, "contractDigest"), record.ContractDigest,
                    StringComparison.Ordinal))
            {
                error = "The ownership record changed before force-stop.";
                return false;
            }
            IList<int> members = NativeMethods.GetJobProcessIds(job);
            if (members.Count == 0)
            {
                error = "The lifecycle job is already empty.";
                return false;
            }
            Dictionary<int, ProcessIdentity> liveSnapshot;
            try
            {
                liveSnapshot = CaptureJobIdentitySnapshot(job);
            }
            catch (Exception exception)
            {
                error = "The lifecycle job identity snapshot could not be revalidated: " + exception.Message;
                return false;
            }
            string liveDigest = HashProcessSnapshot(liveSnapshot);
            if (record.ForceSnapshot == null ||
                !FixedEqualsHex(liveDigest, record.ForceSnapshotDigest) ||
                !FixedEqualsHex(LifecycleJson.String(persisted, "forceSnapshotSha256"),
                    record.ForceSnapshotDigest))
            {
                error = "The lifecycle job membership or process identity changed after graceful timeout.";
                return false;
            }
            IList<int> listeners = NativeMethods.GetListeningProcessIds(healthPort);
            foreach (int listener in listeners)
            {
                if (!members.Contains(listener))
                {
                    error = "The configured health port is owned outside the verified lifecycle job.";
                    return false;
                }
            }
            return true;
        }

        public static Dictionary<int, ProcessIdentity> CaptureJobIdentitySnapshot(IntPtr job)
        {
            Dictionary<int, ProcessIdentity> snapshot = new Dictionary<int, ProcessIdentity>();
            foreach (int processId in NativeMethods.GetJobProcessIds(job))
            {
                IntPtr process = NativeMethods.OpenProcess(
                    NativeMethods.ProcessQueryLimitedInformation | NativeMethods.Synchronize,
                    false, processId);
                if (process == IntPtr.Zero)
                {
                    throw new InvalidOperationException("A lifecycle job member could not be opened for identity verification.");
                }
                try
                {
                    string image = RequireFile(NativeMethods.GetProcessImagePath(process), "job member image");
                    ProcessIdentity identity = new ProcessIdentity();
                    identity.ProcessId = processId;
                    identity.CreationTime = NativeMethods.GetCreationFileTime(process);
                    identity.ImagePath = image;
                    identity.ImageHash = HashFile(image);
                    snapshot[processId] = identity;
                }
                finally { NativeMethods.CloseHandle(process); }
            }
            if (snapshot.Count == 0)
            {
                throw new InvalidOperationException("The lifecycle job became empty before identity capture.");
            }
            return snapshot;
        }

        public static string HashProcessSnapshot(Dictionary<int, ProcessIdentity> snapshot)
        {
            if (snapshot == null || snapshot.Count == 0) { return HashText(String.Empty); }
            StringBuilder canonical = new StringBuilder();
            foreach (KeyValuePair<int, ProcessIdentity> entry in snapshot.OrderBy(
                delegate(KeyValuePair<int, ProcessIdentity> value) { return value.Key; }))
            {
                canonical.Append(entry.Key.ToString(CultureInfo.InvariantCulture)).Append('\0')
                    .Append(entry.Value.CreationTime.ToString(CultureInfo.InvariantCulture)).Append('\0')
                    .Append(entry.Value.ImagePath.ToUpperInvariant()).Append('\0')
                    .Append(entry.Value.ImageHash).Append('\n');
            }
            return HashText(canonical.ToString());
        }

        public static bool HasGracefulAcknowledgement(LifecycleRecord record)
        {
            try
            {
                if (String.IsNullOrEmpty(record.GracefulAckPath) ||
                    String.IsNullOrEmpty(record.GracefulAckToken) ||
                    !File.Exists(record.GracefulAckPath))
                {
                    return false;
                }
                RequireFile(record.GracefulAckPath, "graceful acknowledgement");
                FileInfo info = new FileInfo(record.GracefulAckPath);
                if (info.Length <= 0 || info.Length > 256) { return false; }
                string actual = File.ReadAllText(record.GracefulAckPath, Encoding.UTF8).Trim();
                return FixedEquals(Encoding.UTF8.GetBytes(actual),
                    Encoding.UTF8.GetBytes(record.GracefulAckToken));
            }
            catch { return false; }
        }

        public static string WriteReceipt(LifecycleRecord record, byte[] capability,
            string operation, string result, string error, bool jobEmpty, bool healthOffline)
        {
            return WriteReceiptWithEvidence(record, capability, operation, result, error,
                jobEmpty, healthOffline, "direct-job-query", false);
        }

        public static string WriteReceiptWithEvidence(LifecycleRecord record, byte[] capability,
            string operation, string result, string error, bool jobEmpty, bool healthOffline,
            string jobObservation, bool recoveryInference)
        {
            RequireDirectory(record.InstanceDirectory, "instanceDirectory", false);
            string receiptDirectory = Path.Combine(record.InstanceDirectory, "receipts");
            CreateVerifiedDirectory(receiptDirectory);
            Dictionary<string, object> receipt = new Dictionary<string, object>();
            receipt["schemaVersion"] = 1;
            receipt["receiptId"] = Guid.NewGuid().ToString("N");
            receipt["instanceId"] = record.InstanceId;
            receipt["itemId"] = record.ItemId;
            receipt["operation"] = operation;
            receipt["result"] = result;
            receipt["createdAtUtc"] = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            receipt["identityDigest"] = HashText(record.InstanceId + "\0" +
                record.SupervisorPid.ToString(CultureInfo.InvariantCulture) + "\0" +
                record.SupervisorCreationTime.ToString(CultureInfo.InvariantCulture) + "\0" +
                record.ContractDigest);
            receipt["previousReceiptSha256"] = record.PreviousReceiptHash;
            receipt["jobEmpty"] = jobEmpty;
            receipt["healthOffline"] = healthOffline;
            receipt["jobObservation"] = jobObservation;
            receipt["recoveryInference"] = recoveryInference;
            receipt["error"] = error;
            string canonical = Json.Serialize(receipt);
            receipt["hmacSha256"] = Hmac(capability, canonical);
            string name = LifecycleJson.String(receipt, "receiptId") + ".json";
            string path = Path.Combine(record.InstanceDirectory, "receipts", name);
            WriteNewFile(path, Encoding.UTF8.GetBytes(Json.Serialize(receipt)));
            ApplyFileAcl(path);
            record.PreviousReceiptHash = HashFile(path);
            record.LastReceiptPath = path;
            WriteOwnership(record, capability);
            return path;
        }

        private static Dictionary<string, object> ToDictionary(LifecycleRecord record, bool includeHmac)
        {
            Dictionary<string, object> data = new Dictionary<string, object>();
            data["schemaVersion"] = 1;
            data["instanceDirectory"] = record.InstanceDirectory;
            data["instanceId"] = record.InstanceId;
            data["itemId"] = record.ItemId;
            data["ownerUserSid"] = WindowsIdentity.GetCurrent().User.Value;
            data["contractDigest"] = record.ContractDigest;
            data["healthUrl"] = record.HealthUrl;
            data["pipeName"] = record.PipeName;
            data["supervisorPid"] = record.SupervisorPid;
            data["supervisorCreationTimeFileTimeUtc"] = record.SupervisorCreationTime;
            data["supervisorImage"] = record.SupervisorImage;
            data["supervisorImageSha256"] = record.SupervisorImageHash;
            data["rootPid"] = record.RootPid;
            data["rootCreationTimeFileTimeUtc"] = record.RootCreationTime;
            data["rootImage"] = record.RootImage;
            data["rootImageSha256"] = record.RootImageHash;
            data["commandSha256"] = record.CommandHash;
            data["processGroupId"] = record.ProcessGroupId;
            data["forceEligible"] = record.ForceEligible;
            data["gracefulAckPath"] = record.GracefulAckPath;
            data["gracefulAckTokenSha256"] = record.GracefulAckTokenDigest;
            data["terminalState"] = record.TerminalState;
            data["forceSnapshotSha256"] = record.ForceSnapshotDigest;
            data["lastReceiptPath"] = record.LastReceiptPath;
            data["previousReceiptSha256"] = record.PreviousReceiptHash;
            if (includeHmac) { data["hmacSha256"] = record.Hmac; }
            return data;
        }

        private static LifecycleRecord FromDictionary(Dictionary<string, object> data)
        {
            if (LifecycleJson.Integer(data, "schemaVersion", 0) != 1)
            {
                throw new InvalidOperationException("The lifecycle ownership schema is unsupported.");
            }
            string expectedSid = WindowsIdentity.GetCurrent().User.Value;
            if (!String.Equals(LifecycleJson.String(data, "ownerUserSid"), expectedSid,
                StringComparison.OrdinalIgnoreCase))
            {
                throw new UnauthorizedAccessException("The lifecycle ownership SID did not match the current user.");
            }
            LifecycleRecord record = new LifecycleRecord();
            record.InstanceDirectory = LifecycleJson.String(data, "instanceDirectory");
            record.InstanceId = LifecycleJson.String(data, "instanceId");
            record.ItemId = LifecycleJson.String(data, "itemId");
            record.ContractDigest = LifecycleJson.String(data, "contractDigest");
            record.HealthUrl = LifecycleJson.String(data, "healthUrl");
            record.PipeName = LifecycleJson.String(data, "pipeName");
            record.SupervisorPid = LifecycleJson.Integer(data, "supervisorPid", 0);
            record.SupervisorCreationTime = LifecycleJson.Long(data, "supervisorCreationTimeFileTimeUtc", 0);
            record.SupervisorImage = LifecycleJson.String(data, "supervisorImage");
            record.SupervisorImageHash = LifecycleJson.String(data, "supervisorImageSha256");
            record.RootPid = LifecycleJson.Integer(data, "rootPid", 0);
            record.RootCreationTime = LifecycleJson.Long(data, "rootCreationTimeFileTimeUtc", 0);
            record.RootImage = LifecycleJson.String(data, "rootImage");
            record.RootImageHash = LifecycleJson.String(data, "rootImageSha256");
            record.CommandHash = LifecycleJson.String(data, "commandSha256");
            record.ProcessGroupId = LifecycleJson.Integer(data, "processGroupId", 0);
            record.ForceEligible = LifecycleJson.Boolean(data, "forceEligible");
            record.GracefulAckPath = LifecycleJson.String(data, "gracefulAckPath");
            record.GracefulAckTokenDigest = LifecycleJson.String(data, "gracefulAckTokenSha256");
            record.TerminalState = LifecycleJson.String(data, "terminalState");
            record.ForceSnapshotDigest = LifecycleJson.String(data, "forceSnapshotSha256");
            record.LastReceiptPath = LifecycleJson.String(data, "lastReceiptPath");
            record.PreviousReceiptHash = LifecycleJson.String(data, "previousReceiptSha256");
            return record;
        }

        private static Dictionary<string, object> ReadJsonFile(string path)
        {
            RequireFile(path, "lifecycle record");
            FileInfo info = new FileInfo(path);
            if (info.Length <= 0 || info.Length > 64 * 1024)
            {
                throw new InvalidOperationException("The lifecycle record size is invalid.");
            }
            try
            {
                Dictionary<string, object> result = Json.Deserialize<Dictionary<string, object>>(
                    File.ReadAllText(path, Encoding.UTF8));
                if (result == null) { throw new InvalidOperationException(); }
                return result;
            }
            catch
            {
                throw new InvalidOperationException("The lifecycle JSON record is invalid.");
            }
        }

        private static void AtomicWrite(string path, string value)
        {
            ValidateWriteBoundary(path, true);
            string temporary = path + ".write-" + Guid.NewGuid().ToString("N") + ".tmp";
            WriteNewFile(temporary, Encoding.UTF8.GetBytes(value));
            ApplyFileAcl(temporary);
            if (File.Exists(path))
            {
                ValidateWriteBoundary(path, true);
                ValidateWriteBoundary(temporary, true);
                string previous = path + ".previous-" + Guid.NewGuid().ToString("N");
                ValidateWriteBoundary(previous, false);
                File.Replace(temporary, path, previous, true);
                RequireFile(previous, "previous lifecycle record");
                ApplyFileAcl(previous);
            }
            else
            {
                ValidateWriteBoundary(path, false);
                ValidateWriteBoundary(temporary, true);
                File.Move(temporary, path);
            }
            RequireFile(path, "lifecycle record");
            ApplyFileAcl(path);
        }

        private static void WriteNewFile(string path, byte[] bytes)
        {
            ValidateWriteBoundary(path, false);
            using (FileStream stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write,
                FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
            }
            RequireFile(path, "new lifecycle record");
        }

        private static void ValidateWriteBoundary(string path, bool allowExistingFile)
        {
            string full = RequirePath(path, "lifecycle write path");
            string parent = Path.GetDirectoryName(full);
            RequireDirectory(parent, "lifecycle write directory", false);
            EnsureExistingAncestorsNoReparse(full);
            if (Directory.Exists(full))
            {
                throw new InvalidOperationException("A lifecycle file path resolved to a directory.");
            }
            if (File.Exists(full))
            {
                RequireFile(full, "lifecycle write target");
                if (!allowExistingFile)
                {
                    throw new IOException("The lifecycle write target already exists.");
                }
            }
        }

        private static void ApplyDirectoryAcl(string path)
        {
            RequireDirectory(path, "lifecycle ACL directory", false);
            DirectorySecurity security = new DirectorySecurity();
            security.SetAccessRuleProtection(true, false);
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
            InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
            security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
                inheritance, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(
                WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl,
                inheritance, PropagationFlags.None, AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl,
                inheritance, PropagationFlags.None, AccessControlType.Allow));
            Directory.SetAccessControl(path, security);
        }

        private static void ApplyFileAcl(string path)
        {
            RequireFile(path, "lifecycle ACL file");
            FileSecurity security = new FileSecurity();
            security.SetAccessRuleProtection(true, false);
            SecurityIdentifier user = WindowsIdentity.GetCurrent().User;
            security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(
                WellKnownSidType.LocalSystemSid, null), FileSystemRights.FullControl,
                AccessControlType.Allow));
            security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(
                WellKnownSidType.BuiltinAdministratorsSid, null), FileSystemRights.FullControl,
                AccessControlType.Allow));
            File.SetAccessControl(path, security);
        }

        public static string HashFile(string path)
        {
            using (SHA256 algorithm = SHA256.Create())
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                FileShare.Read | FileShare.Delete))
            {
                return Hex(algorithm.ComputeHash(stream));
            }
        }

        private static string HashText(string value)
        {
            using (SHA256 algorithm = SHA256.Create())
            {
                return Hex(algorithm.ComputeHash(Encoding.UTF8.GetBytes(value ?? String.Empty)));
            }
        }

        public static string HashTextValue(string value)
        {
            return HashText(value);
        }

        private static string Hmac(byte[] key, string value)
        {
            using (HMACSHA256 algorithm = new HMACSHA256(key))
            {
                return Hex(algorithm.ComputeHash(Encoding.UTF8.GetBytes(value)));
            }
        }

        private static string Hex(byte[] bytes)
        {
            StringBuilder value = new StringBuilder(bytes.Length * 2);
            foreach (byte item in bytes) { value.Append(item.ToString("x2", CultureInfo.InvariantCulture)); }
            return value.ToString();
        }

        public static bool FixedEquals(byte[] left, byte[] right)
        {
            if (left == null || right == null || left.Length != right.Length) { return false; }
            int difference = 0;
            for (int index = 0; index < left.Length; index++) { difference |= left[index] ^ right[index]; }
            return difference == 0;
        }

        private static bool FixedEqualsHex(string left, string right)
        {
            if (left == null || right == null) { return false; }
            return FixedEquals(Encoding.ASCII.GetBytes(left.ToLowerInvariant()),
                Encoding.ASCII.GetBytes(right.ToLowerInvariant()));
        }
    }

    internal static class LifecycleJson
    {
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer
        {
            MaxJsonLength = 64 * 1024,
            RecursionLimit = 12
        };

        internal const string UnsupportedProtocolMessage =
            "The lifecycle protocol version is unsupported.";

        internal static bool IsUnsupportedProtocolDowngradeResponse(string response,
            string expectedInstanceId, int expectedSupervisorPid)
        {
            try
            {
                return IsUnsupportedProtocolDowngradeFields(
                    Parse(response), expectedInstanceId, expectedSupervisorPid);
            }
            catch { return false; }
        }

        internal static bool IsUnsupportedProtocolDowngradeFields(
            IDictionary<string, object> response, string expectedInstanceId,
            int expectedSupervisorPid)
        {
            object success;
            object owned;
            object stoppable;
            return response != null &&
                response.TryGetValue("success", out success) && success is bool && !(bool)success &&
                response.TryGetValue("owned", out owned) && owned is bool && (bool)owned &&
                response.TryGetValue("stoppable", out stoppable) && stoppable is bool && !(bool)stoppable &&
                System.String.Equals(String(response, "state"), "Ambiguous", StringComparison.Ordinal) &&
                System.String.Equals(String(response, "instanceId"), expectedInstanceId,
                    StringComparison.Ordinal) &&
                Integer(response, "processId", 0) == expectedSupervisorPid &&
                System.String.Equals(String(response, "error"), UnsupportedProtocolMessage,
                    StringComparison.Ordinal);
        }

        public static Dictionary<string, object> Parse(string value)
        {
            if (System.String.IsNullOrWhiteSpace(value) || Encoding.UTF8.GetByteCount(value) > 64 * 1024)
            {
                throw new InvalidOperationException("The lifecycle JSON message is empty or too large.");
            }
            try
            {
                Dictionary<string, object> result =
                    Json.Deserialize<Dictionary<string, object>>(value);
                if (result == null)
                {
                    throw new InvalidOperationException("The lifecycle JSON message is invalid.");
                }
                return result;
            }
            catch (InvalidOperationException exception)
            {
                if (System.String.Equals(exception.Message, "The lifecycle JSON message is invalid.",
                    StringComparison.Ordinal)) { throw; }
                throw new InvalidOperationException("The lifecycle JSON message is invalid.");
            }
            catch
            {
                throw new InvalidOperationException("The lifecycle JSON message is invalid.");
            }
        }

        public static string String(IDictionary<string, object> value, string name)
        {
            object item;
            return value != null && value.TryGetValue(name, out item) && item != null
                ? Convert.ToString(item, CultureInfo.InvariantCulture) : null;
        }

        public static int Integer(IDictionary<string, object> value, string name, int fallback)
        {
            object item;
            int result;
            return value != null && value.TryGetValue(name, out item) && item != null &&
                Int32.TryParse(Convert.ToString(item, CultureInfo.InvariantCulture),
                    NumberStyles.Integer, CultureInfo.InvariantCulture, out result) ? result : fallback;
        }

        public static long Long(IDictionary<string, object> value, string name, long fallback)
        {
            object item;
            long result;
            return value != null && value.TryGetValue(name, out item) && item != null &&
                Int64.TryParse(Convert.ToString(item, CultureInfo.InvariantCulture),
                    NumberStyles.Integer, CultureInfo.InvariantCulture, out result) ? result : fallback;
        }

        public static bool Boolean(IDictionary<string, object> value, string name)
        {
            object item;
            bool result;
            return value != null && value.TryGetValue(name, out item) && item != null &&
                System.Boolean.TryParse(Convert.ToString(item, CultureInfo.InvariantCulture), out result) && result;
        }

        public static string Result(bool success, string state, bool owned, bool stoppable,
            int processId, int rootProcessId, string instanceId, string receiptPath,
            string error, bool jobEmpty, bool healthOffline)
        {
            return ResultWithEvidence(success, state, owned, stoppable, processId, rootProcessId,
                instanceId, receiptPath, error, jobEmpty, healthOffline, "not-observed", false);
        }

        public static string ResultWithEvidence(bool success, string state, bool owned, bool stoppable,
            int processId, int rootProcessId, string instanceId, string receiptPath,
            string error, bool jobEmpty, bool healthOffline, string jobObservation,
            bool recoveryInference)
        {
            return ResultWithRecoveredResponse(success, state, owned, stoppable, processId,
                rootProcessId, instanceId, receiptPath, error, jobEmpty, healthOffline,
                jobObservation, recoveryInference, false);
        }

        public static string ResultWithRecoveredResponse(bool success, string state,
            bool owned, bool stoppable, int processId, int rootProcessId, string instanceId,
            string receiptPath, string error, bool jobEmpty, bool healthOffline,
            string jobObservation, bool recoveryInference, bool recoveredResponse)
        {
            Dictionary<string, object> result = new Dictionary<string, object>();
            result["protocolVersion"] = 2;
            result["success"] = success;
            result["state"] = state;
            result["owned"] = owned;
            result["stoppable"] = stoppable;
            result["processId"] = processId == 0 ? null : (object)processId;
            result["rootProcessId"] = rootProcessId == 0 ? null : (object)rootProcessId;
            result["instanceId"] = instanceId;
            result["receiptPath"] = receiptPath;
            result["error"] = error;
            result["jobEmpty"] = jobEmpty;
            result["healthOffline"] = healthOffline;
            result["jobObservation"] = jobObservation;
            result["recoveryInference"] = recoveryInference;
            result["recoveredResponse"] = recoveredResponse;
            return Json.Serialize(result);
        }

        public static void WriteMessage(Stream stream, IDictionary<string, object> value, int maximumBytes)
        {
            WriteRawMessage(stream, Json.Serialize(value), maximumBytes);
        }

        public static void WriteRawMessage(Stream stream, string value, int maximumBytes)
        {
            byte[] payload = Encoding.UTF8.GetBytes(value);
            if (payload.Length > maximumBytes) { throw new InvalidOperationException("Lifecycle message is too large."); }
            byte[] length = BitConverter.GetBytes(payload.Length);
            stream.Write(length, 0, length.Length);
            stream.Write(payload, 0, payload.Length);
            stream.Flush();
        }

        public static string ReadMessage(Stream stream, int maximumBytes, int timeoutMilliseconds)
        {
            Stopwatch watch = Stopwatch.StartNew();
            byte[] lengthBytes = ReadExact(stream, 4, timeoutMilliseconds, watch);
            int length = BitConverter.ToInt32(lengthBytes, 0);
            if (length <= 0 || length > maximumBytes) { throw new InvalidOperationException("Lifecycle message size is invalid."); }
            return Encoding.UTF8.GetString(ReadExact(stream, length, timeoutMilliseconds, watch));
        }

        private static byte[] ReadExact(Stream stream, int count, int timeoutMilliseconds,
            Stopwatch watch)
        {
            byte[] value = new byte[count];
            int offset = 0;
            while (offset < count)
            {
                int remaining = timeoutMilliseconds - unchecked((int)watch.ElapsedMilliseconds);
                if (remaining <= 0) { throw new TimeoutException("Lifecycle pipe read timed out."); }
                IAsyncResult pending = stream.BeginRead(value, offset, count - offset, null, null);
                if (!pending.AsyncWaitHandle.WaitOne(remaining))
                {
                    throw new TimeoutException("Lifecycle pipe read timed out.");
                }
                int read = stream.EndRead(pending);
                if (read <= 0) { throw new EndOfStreamException("Lifecycle pipe closed before the message completed."); }
                offset += read;
            }
            return value;
        }
    }

    internal sealed class NativeProcess : IDisposable
    {
        public IntPtr ProcessHandle;
        public IntPtr ThreadHandle;
        public int ProcessId;
        public void CloseThreadHandle()
        {
            if (ThreadHandle != IntPtr.Zero) { NativeMethods.CloseHandle(ThreadHandle); ThreadHandle = IntPtr.Zero; }
        }
        public void Dispose()
        {
            CloseThreadHandle();
            if (ProcessHandle != IntPtr.Zero) { NativeMethods.CloseHandle(ProcessHandle); ProcessHandle = IntPtr.Zero; }
        }
    }

    internal sealed class NativeHelperProcess : IDisposable
    {
        public NativeProcess Process;
        public FileStream StandardOutput;
        public FileStream StandardError;
        public void Dispose()
        {
            if (StandardOutput != null) { StandardOutput.Dispose(); StandardOutput = null; }
            if (StandardError != null) { StandardError.Dispose(); StandardError = null; }
            if (Process != null) { Process.Dispose(); Process = null; }
        }
    }

    internal static class NativeMethods
    {
        public const uint CtrlBreakEvent = 1;
        public const uint ProcessQueryLimitedInformation = 0x1000;
        public const uint Synchronize = 0x00100000;
        private const uint CreateSuspended = 0x00000004;
        private const uint CreateNewProcessGroup = 0x00000200;
        private const uint CreateUnicodeEnvironment = 0x00000400;
        private const uint StartfUseShowWindow = 0x00000001;
        private const uint StartfUseStdHandles = 0x00000100;
        private const uint HandleFlagInherit = 0x00000001;
        private const uint GenericRead = 0x80000000;
        private const uint FileShareRead = 0x00000001;
        private const uint FileShareWrite = 0x00000002;
        private const uint OpenExisting = 3;
        private const short SwHide = 0;
        private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);
        private const int JobObjectExtendedLimitInformation = 9;
        private const int JobObjectBasicProcessIdList = 3;
        private const uint JobObjectLimitKillOnJobClose = 0x00002000;
        private const int TcpTableOwnerPidListener = 3;
        private const int AfInet = 2;
        private const int AfInet6 = 23;
        private const uint ErrorInsufficientBuffer = 122;
        private const int MaximumTcpTableBytes = 16 * 1024 * 1024;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
            public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
            public int dwX; public int dwY; public int dwXSize; public int dwYSize;
            public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
            public uint dwFlags; public short wShowWindow; public short cbReserved2;
            public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            public int nLength;
            public IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
            public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit; public long Affinity; public uint PriorityClass; public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS
        {
            public ulong ReadOperationCount; public ulong WriteOperationCount; public ulong OtherOperationCount;
            public ulong ReadTransferCount; public ulong WriteTransferCount; public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            public IO_COUNTERS IoInfo;
            public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit; public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcess(string applicationName, StringBuilder commandLine,
            IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
            IntPtr environment, string currentDirectory, ref STARTUPINFO startupInfo,
            out PROCESS_INFORMATION processInformation);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe,
            ref SECURITY_ATTRIBUTES attributes, uint size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFile(string path, uint desiredAccess, uint shareMode,
            ref SECURITY_ATTRIBUTES attributes, uint creationDisposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool TerminateJobObject(IntPtr job, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool WaitNamedPipe(string name, uint timeoutMilliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool CloseHandle(IntPtr handle);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit,
            out long kernel, out long user);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool QueryFullProcessImageName(IntPtr process, int flags,
            StringBuilder path, ref int size);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr job, int infoClass,
            IntPtr info, uint length, out uint returnLength);
        [DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool GenerateConsoleCtrlEvent(uint ctrlEvent, uint processGroupId);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AllocConsole();
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetConsoleCtrlHandler(IntPtr handler, bool add);
        [DllImport("kernel32.dll")]
        private static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetNamedPipeServerProcessId(IntPtr pipe, out uint serverProcessId);
        [DllImport("iphlpapi.dll", SetLastError = true)]
        private static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order,
            int addressFamily, int tableClass, uint reserved);

        public static IntPtr CreateManagedJob()
        {
            IntPtr job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) { throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
            info.BasicLimitInformation.LimitFlags = JobObjectLimitKillOnJobClose;
            int size = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
            IntPtr memory = Marshal.AllocHGlobal(size);
            try
            {
                Marshal.StructureToPtr(info, memory, false);
                if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, memory, (uint)size))
                {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                return job;
            }
            catch { CloseHandle(job); throw; }
            finally { Marshal.FreeHGlobal(memory); }
        }

        public static void PrepareHiddenConsole()
        {
            if (GetConsoleWindow() != IntPtr.Zero)
            {
                throw new InvalidOperationException("The lifecycle supervisor refused to use an inherited console.");
            }
            if (!AllocConsole())
            {
                throw new InvalidOperationException("A private lifecycle console could not be allocated.",
                    new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
            }
            IntPtr window = GetConsoleWindow();
            if (window == IntPtr.Zero)
            {
                throw new InvalidOperationException("The private lifecycle console could not be verified.");
            }
            ShowWindow(window, SwHide);
            if (!SetConsoleCtrlHandler(IntPtr.Zero, true))
            {
                throw new InvalidOperationException("The lifecycle supervisor control handler could not be isolated.",
                    new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()));
            }
        }

        public static void AbortSuspendedProcess(IntPtr process)
        {
            if (process == IntPtr.Zero) { return; }
            TerminateProcess(process, 1);
            WaitForSingleObject(process, 5000);
        }

        public static bool IsExactProcessAbsentOrTerminated(int processId,
            long expectedCreationTime)
        {
            if (processId <= 0 || expectedCreationTime <= 0) { return false; }
            IntPtr process = OpenProcess(ProcessQueryLimitedInformation | Synchronize,
                false, processId);
            if (process == IntPtr.Zero)
            {
                int error = Marshal.GetLastWin32Error();
                return error == 87 || error == 1168;
            }
            try
            {
                if (WaitForSingleObject(process, 0) == 0) { return true; }
                return GetCreationFileTime(process) != expectedCreationTime;
            }
            catch { return false; }
            finally { CloseHandle(process); }
        }

        public static bool IsNamedPipeAbsent(string pipeName, int timeoutMilliseconds)
        {
            if (String.IsNullOrEmpty(pipeName)) { return false; }
            bool available = WaitNamedPipe("\\\\.\\pipe\\" + pipeName,
                unchecked((uint)Math.Max(0, timeoutMilliseconds)));
            if (available) { return false; }
            return Marshal.GetLastWin32Error() == 2;
        }

        public static NativeProcess CreateSuspendedProcess(string executable, string arguments,
            string workingDirectory, string pathValue, string gracefulAckPath,
            string gracefulAckToken)
        {
            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
            startup.dwFlags = StartfUseShowWindow;
            startup.wShowWindow = SwHide;
            PROCESS_INFORMATION process;
            string application = executable;
            string extension = Path.GetExtension(executable);
            string commandText;
            if (String.Equals(extension, ".cmd", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(extension, ".bat", StringComparison.OrdinalIgnoreCase))
            {
                application = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                    "cmd.exe");
                commandText = Quote(application) + " /d /s /c \"\"" + executable + "\"" +
                    (String.IsNullOrWhiteSpace(arguments) ? String.Empty : " " + arguments) + "\"";
            }
            else
            {
                commandText = Quote(executable) +
                    (String.IsNullOrWhiteSpace(arguments) ? String.Empty : " " + arguments);
            }
            StringBuilder command = new StringBuilder(commandText);
            IntPtr environment = BuildEnvironment(pathValue, gracefulAckPath, gracefulAckToken);
            try
            {
                bool created = CreateProcess(application, command, IntPtr.Zero, IntPtr.Zero, false,
                    CreateSuspended | CreateNewProcessGroup | CreateUnicodeEnvironment,
                    environment, workingDirectory, ref startup, out process);
                if (!created) { throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()); }
                return new NativeProcess
                {
                    ProcessHandle = process.hProcess,
                    ThreadHandle = process.hThread,
                    ProcessId = unchecked((int)process.dwProcessId)
                };
            }
            finally { if (environment != IntPtr.Zero) { Marshal.FreeHGlobal(environment); } }
        }

        public static NativeHelperProcess CreateSuspendedHelper(string executable, string arguments,
            string workingDirectory, string instanceId, string itemId, string contractDigest)
        {
            SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.bInheritHandle = true;
            IntPtr standardInput = IntPtr.Zero;
            IntPtr outputRead = IntPtr.Zero;
            IntPtr outputWrite = IntPtr.Zero;
            IntPtr errorRead = IntPtr.Zero;
            IntPtr errorWrite = IntPtr.Zero;
            IntPtr environment = IntPtr.Zero;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            bool created = false;
            NativeHelperProcess helper = null;
            try
            {
                standardInput = CreateFile("NUL", GenericRead, FileShareRead | FileShareWrite,
                    ref attributes, OpenExisting, 0, IntPtr.Zero);
                if (standardInput == InvalidHandleValue)
                {
                    standardInput = IntPtr.Zero;
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                if (!CreatePipe(out outputRead, out outputWrite, ref attributes, 4096) ||
                    !SetHandleInformation(outputRead, HandleFlagInherit, 0) ||
                    !CreatePipe(out errorRead, out errorWrite, ref attributes, 4096) ||
                    !SetHandleInformation(errorRead, HandleFlagInherit, 0))
                {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                STARTUPINFO startup = new STARTUPINFO();
                startup.cb = Marshal.SizeOf(typeof(STARTUPINFO));
                startup.dwFlags = StartfUseShowWindow | StartfUseStdHandles;
                startup.wShowWindow = SwHide;
                startup.hStdInput = standardInput;
                startup.hStdOutput = outputWrite;
                startup.hStdError = errorWrite;
                environment = BuildRestrictedHelperEnvironment(instanceId, itemId, contractDigest);
                StringBuilder command = new StringBuilder(Quote(executable) +
                    (String.IsNullOrWhiteSpace(arguments) ? String.Empty : " " + arguments));
                created = CreateProcess(executable, command, IntPtr.Zero, IntPtr.Zero, true,
                    CreateSuspended | CreateUnicodeEnvironment, environment, workingDirectory,
                    ref startup, out process);
                if (!created)
                {
                    throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                }
                CloseHandle(standardInput); standardInput = IntPtr.Zero;
                CloseHandle(outputWrite); outputWrite = IntPtr.Zero;
                CloseHandle(errorWrite); errorWrite = IntPtr.Zero;
                helper = new NativeHelperProcess();
                helper.Process = new NativeProcess
                {
                    ProcessHandle = process.hProcess,
                    ThreadHandle = process.hThread,
                    ProcessId = unchecked((int)process.dwProcessId)
                };
                process.hProcess = IntPtr.Zero;
                process.hThread = IntPtr.Zero;
                helper.StandardOutput = new FileStream(new SafeFileHandle(outputRead, true),
                    FileAccess.Read, 4096, false);
                outputRead = IntPtr.Zero;
                helper.StandardError = new FileStream(new SafeFileHandle(errorRead, true),
                    FileAccess.Read, 4096, false);
                errorRead = IntPtr.Zero;
                return helper;
            }
            catch
            {
                if (helper != null)
                {
                    if (helper.Process != null && helper.Process.ProcessHandle != IntPtr.Zero)
                    {
                        AbortSuspendedProcess(helper.Process.ProcessHandle);
                    }
                    helper.Dispose();
                }
                else if (created && process.hProcess != IntPtr.Zero)
                {
                    AbortSuspendedProcess(process.hProcess);
                }
                throw;
            }
            finally
            {
                if (standardInput != IntPtr.Zero) { CloseHandle(standardInput); }
                if (outputRead != IntPtr.Zero) { CloseHandle(outputRead); }
                if (outputWrite != IntPtr.Zero) { CloseHandle(outputWrite); }
                if (errorRead != IntPtr.Zero) { CloseHandle(errorRead); }
                if (errorWrite != IntPtr.Zero) { CloseHandle(errorWrite); }
                if (process.hThread != IntPtr.Zero) { CloseHandle(process.hThread); }
                if (process.hProcess != IntPtr.Zero) { CloseHandle(process.hProcess); }
                if (environment != IntPtr.Zero) { Marshal.FreeHGlobal(environment); }
            }
        }

        public static bool WaitForProcessExit(IntPtr process, int timeoutMilliseconds)
        {
            return WaitForSingleObject(process, unchecked((uint)Math.Max(0, timeoutMilliseconds))) == 0;
        }

        public static bool TryGetProcessExitCode(IntPtr process, out int exitCode)
        {
            uint value;
            if (!GetExitCodeProcess(process, out value))
            {
                exitCode = 0;
                return false;
            }
            exitCode = unchecked((int)value);
            return true;
        }

        private static IntPtr BuildEnvironment(string pathValue, string gracefulAckPath,
            string gracefulAckToken)
        {
            System.Collections.IDictionary environment = Environment.GetEnvironmentVariables();
            SortedDictionary<string, string> values = new SortedDictionary<string, string>(
                StringComparer.OrdinalIgnoreCase);
            foreach (System.Collections.DictionaryEntry entry in environment)
            {
                values[Convert.ToString(entry.Key, CultureInfo.InvariantCulture)] =
                    Convert.ToString(entry.Value, CultureInfo.InvariantCulture);
            }
            if (!String.IsNullOrEmpty(pathValue)) { values["PATH"] = pathValue; }
            values["WORKSPACE_WIDGET_GRACEFUL_ACK_PATH"] = gracefulAckPath;
            values["WORKSPACE_WIDGET_GRACEFUL_ACK_TOKEN"] = gracefulAckToken;
            StringBuilder block = new StringBuilder();
            foreach (KeyValuePair<string, string> entry in values)
            {
                block.Append(entry.Key).Append('=').Append(entry.Value).Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }

        private static IntPtr BuildRestrictedHelperEnvironment(string instanceId, string itemId,
            string contractDigest)
        {
            string systemRoot = Environment.GetEnvironmentVariable("SystemRoot") ??
                Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            SortedDictionary<string, string> values = new SortedDictionary<string, string>(
                StringComparer.OrdinalIgnoreCase);
            values["SystemRoot"] = systemRoot;
            values["WINDIR"] = systemRoot;
            values["ComSpec"] = Path.Combine(systemRoot, "System32", "cmd.exe");
            values["WORKSPACE_WIDGET_INSTANCE_ID"] = instanceId;
            values["WORKSPACE_WIDGET_ITEM_ID"] = itemId;
            values["WORKSPACE_WIDGET_CONTRACT_DIGEST"] = contractDigest;
            StringBuilder block = new StringBuilder();
            foreach (KeyValuePair<string, string> value in values)
            {
                block.Append(value.Key).Append('=').Append(value.Value).Append('\0');
            }
            block.Append('\0');
            return Marshal.StringToHGlobalUni(block.ToString());
        }

        private static string Quote(string value)
        {
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        public static long GetCreationFileTime(IntPtr process)
        {
            long creation, exit, kernel, user;
            if (!GetProcessTimes(process, out creation, out exit, out kernel, out user))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return creation;
        }

        public static string GetProcessImagePath(IntPtr process)
        {
            int size = 32768;
            StringBuilder path = new StringBuilder(size);
            if (!QueryFullProcessImageName(process, 0, path, ref size))
            {
                throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
            }
            return Path.GetFullPath(path.ToString());
        }

        public static IList<int> GetJobProcessIds(IntPtr job)
        {
            int capacity = 64;
            while (capacity <= 4096)
            {
                int header = 8;
                int size = header + capacity * IntPtr.Size;
                IntPtr memory = Marshal.AllocHGlobal(size);
                try
                {
                    for (int index = 0; index < size; index++) { Marshal.WriteByte(memory, index, 0); }
                    uint returned;
                    if (QueryInformationJobObject(job, JobObjectBasicProcessIdList,
                        memory, (uint)size, out returned))
                    {
                        int count = Marshal.ReadInt32(memory, 4);
                        List<int> result = new List<int>();
                        for (int index = 0; index < count && index < capacity; index++)
                        {
                            long pid = IntPtr.Size == 8
                                ? Marshal.ReadInt64(memory, header + index * IntPtr.Size)
                                : Marshal.ReadInt32(memory, header + index * IntPtr.Size);
                            if (pid > 0 && pid <= Int32.MaxValue) { result.Add((int)pid); }
                        }
                        return result;
                    }
                    int error = Marshal.GetLastWin32Error();
                    if (error != 122) { throw new System.ComponentModel.Win32Exception(error); }
                }
                finally { Marshal.FreeHGlobal(memory); }
                capacity *= 2;
            }
            throw new InvalidOperationException("The lifecycle job contains too many processes.");
        }

        public static bool WaitForJobEmpty(IntPtr job, int timeoutMilliseconds)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                if (GetJobProcessIds(job).Count == 0) { return true; }
                Thread.Sleep(100);
            }
            return GetJobProcessIds(job).Count == 0;
        }

        public static IList<int> GetListeningProcessIds(int port)
        {
            List<int> owners = new List<int>();
            AddListeningProcessIds(owners, port, AfInet, 24, 8, 20);
            // MIB_TCP6ROW_OWNER_PID: 16-byte local address, DWORD scope ID,
            // then the local port at byte offset 20; owning PID is at 52.
            AddListeningProcessIds(owners, port, AfInet6, 56, 20, 52);
            return owners;
        }

        private static void AddListeningProcessIds(List<int> owners, int port,
            int addressFamily, int rowSize, int portOffset, int processOffset)
        {
            int size = 0;
            uint probeResult = GetExtendedTcpTable(IntPtr.Zero, ref size, true, addressFamily,
                TcpTableOwnerPidListener, 0);
            if (!IsTcpTableSizeProbeValid(probeResult, size))
            {
                throw new InvalidOperationException("The TCP listener table size could not be verified.",
                    new System.ComponentModel.Win32Exception(unchecked((int)probeResult)));
            }
            IntPtr memory = Marshal.AllocHGlobal(size);
            try
            {
                uint result = GetExtendedTcpTable(memory, ref size, true, addressFamily,
                    TcpTableOwnerPidListener, 0);
                int count = Marshal.ReadInt32(memory);
                if (!IsTcpTablePayloadValid(result, size, count, rowSize))
                {
                    throw new InvalidOperationException("The TCP listener table payload could not be verified.",
                        new System.ComponentModel.Win32Exception(unchecked((int)result)));
                }
                for (int index = 0; index < count; index++)
                {
                    IntPtr row = IntPtr.Add(memory, 4 + index * rowSize);
                    int encodedPort = Marshal.ReadInt32(row, portOffset);
                    int localPort = IPAddress.NetworkToHostOrder((short)(encodedPort & 0xffff));
                    if (localPort < 0) { localPort += 65536; }
                    if (localPort == port)
                    {
                        int pid = Marshal.ReadInt32(row, processOffset);
                        if (pid > 0 && !owners.Contains(pid)) { owners.Add(pid); }
                    }
                }
            }
            finally { Marshal.FreeHGlobal(memory); }
        }

        internal static bool IsTcpTableSizeProbeValid(uint result, int size)
        {
            return result == ErrorInsufficientBuffer && size >= 4 && size <= MaximumTcpTableBytes;
        }

        internal static bool IsTcpTablePayloadValid(uint result, int size, int count, int rowSize)
        {
            if (result != 0 || size < 4 || size > MaximumTcpTableBytes ||
                count < 0 || rowSize <= 0)
            {
                return false;
            }
            return 4L + ((long)count * rowSize) <= size;
        }

        public static bool WaitForPortOffline(int port, int timeoutMilliseconds)
        {
            Stopwatch watch = Stopwatch.StartNew();
            while (watch.ElapsedMilliseconds < timeoutMilliseconds)
            {
                if (GetListeningProcessIds(port).Count == 0) { return true; }
                Thread.Sleep(100);
            }
            return GetListeningProcessIds(port).Count == 0;
        }

        public static bool TryGetNamedPipeServerPid(NamedPipeClientStream pipe, out int processId)
        {
            uint value;
            bool success = GetNamedPipeServerProcessId(pipe.SafePipeHandle.DangerousGetHandle(), out value);
            processId = success ? unchecked((int)value) : 0;
            return success;
        }
    }
}
