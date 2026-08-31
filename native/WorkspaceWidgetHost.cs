using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.PowerShell;
using Windows.ApplicationModel;

[assembly: AssemblyTitle("Workspace Widget")]
[assembly: AssemblyDescription("Windows-native customizable shortcut widget")]
[assembly: AssemblyCompany("Workspace Widget Contributors")]
[assembly: AssemblyProduct("Workspace Widget")]
[assembly: AssemblyCopyright("Copyright (c) 2026 Workspace Widget Contributors")]
[assembly: AssemblyVersion("0.1.1.0")]
[assembly: AssemblyFileVersion("0.1.1.0")]
[assembly: AssemblyInformationalVersion("0.1.1")]

namespace WorkspaceWidget.Native
{
    internal static class Program
    {
        private const string ProductAppId = "WorkspaceWidget.Desktop";
        private const string PackagedStartupTaskId = "WorkspaceWidgetStartup";
        private const string HostLogDirectory = "WorkspaceServiceWidget";
        private const string HostLogFile = "host.log";
        private const int ErrorInsufficientBuffer = 122;
        private const int AppModelErrorNoPackage = 15700;

        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr value);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(
            string appId);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetCurrentPackageFullName(
            ref int packageFullNameLength,
            StringBuilder packageFullName);

        [STAThread]
        private static int Main(string[] args)
        {
            TryConfigureNativeProcess();
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            try
            {
                HostOptions options = HostOptions.Parse(args);
                string projectRoot = ResolveProjectRoot(options.ProjectRoot);
                string processWorkingDirectory = projectRoot;
                if (HasPackageIdentity())
                {
                    processWorkingDirectory = Path.Combine(
                        Environment.GetFolderPath(
                            Environment.SpecialFolder.LocalApplicationData),
                        HostLogDirectory);
                    Directory.CreateDirectory(processWorkingDirectory);
                }
                Directory.SetCurrentDirectory(processWorkingDirectory);

                string executablePath = Assembly.GetExecutingAssembly().Location;
                Environment.SetEnvironmentVariable(
                    "WORKSPACE_WIDGET_HOST_PATH",
                    executablePath,
                    EnvironmentVariableTarget.Process);

                if (!String.IsNullOrWhiteSpace(options.AutostartAction))
                {
                    return RunAutostartAction(
                        projectRoot,
                        options.AutostartAction,
                        options.Silent);
                }

                return RunWidget(projectRoot, options);
            }
            catch (Exception exception)
            {
                WriteHostLog("Fatal host error. " + exception);
                if (!args.Any(
                    item => String.Equals(
                        item,
                        "--silent",
                        StringComparison.OrdinalIgnoreCase)))
                {
                    MessageBox.Show(
                        "Workspace Widget could not start.\r\n\r\n" +
                        exception.Message +
                        "\r\n\r\nSee %LOCALAPPDATA%\\WorkspaceServiceWidget\\" +
                        HostLogFile + " for details.",
                        "Workspace Widget",
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Error);
                }
                return 1;
            }
        }

        private static void TryConfigureNativeProcess()
        {
            try
            {
                // PER_MONITOR_AWARE_V2. Older Windows versions safely reject it.
                SetProcessDpiAwarenessContext(new IntPtr(-4));
            }
            catch
            {
            }

            if (!HasPackageIdentity())
            {
                try
                {
                    SetCurrentProcessExplicitAppUserModelID(ProductAppId);
                }
                catch
                {
                }
            }
        }

        private static bool HasPackageIdentity()
        {
            try
            {
                int packageFullNameLength = 0;
                int result = GetCurrentPackageFullName(
                    ref packageFullNameLength,
                    null);
                if (result == AppModelErrorNoPackage)
                {
                    return false;
                }
                return result == ErrorInsufficientBuffer || result == 0;
            }
            catch
            {
                return false;
            }
        }

        private static string ResolveProjectRoot(string requestedRoot)
        {
            string executableDirectory = Path.GetDirectoryName(
                Assembly.GetExecutingAssembly().Location);
            if (String.IsNullOrWhiteSpace(executableDirectory))
            {
                throw new InvalidOperationException(
                    "The executable directory could not be resolved.");
            }

            string[] candidates =
            {
                executableDirectory,
                Directory.GetParent(executableDirectory) == null
                    ? null
                    : Directory.GetParent(executableDirectory).FullName
            };
            foreach (string candidate in candidates)
            {
                if (
                    !String.IsNullOrWhiteSpace(candidate) &&
                    File.Exists(
                        Path.Combine(
                            candidate,
                            "app",
                            "WorkspaceWidget.ps1")))
                {
                    string trustedRoot = Path.GetFullPath(candidate);
                    if (!String.IsNullOrWhiteSpace(requestedRoot))
                    {
                        string requested = ValidateProjectRoot(requestedRoot);
                        if (!String.Equals(
                            trustedRoot.TrimEnd(
                                Path.DirectorySeparatorChar,
                                Path.AltDirectorySeparatorChar),
                            requested.TrimEnd(
                                Path.DirectorySeparatorChar,
                                Path.AltDirectorySeparatorChar),
                            StringComparison.OrdinalIgnoreCase))
                        {
                            throw new UnauthorizedAccessException(
                                "The requested project root does not match " +
                                "the executable-owned application root.");
                        }
                    }
                    return trustedRoot;
                }
            }

            throw new FileNotFoundException(
                "WorkspaceWidget.ps1 was not found next to WorkspaceWidget.exe.");
        }

        private static string ValidateProjectRoot(string root)
        {
            string resolved = Path.GetFullPath(root.Trim());
            string appScript = Path.Combine(
                resolved,
                "app",
                "WorkspaceWidget.ps1");
            if (!File.Exists(appScript))
            {
                throw new FileNotFoundException(
                    "Workspace Widget application script was not found.",
                    appScript);
            }
            return resolved;
        }

        private static int RunWidget(
            string projectRoot,
            HostOptions options)
        {
            string statePath = options.StatePath;
            if (String.IsNullOrWhiteSpace(statePath))
            {
                statePath = Path.Combine(
                    Environment.GetFolderPath(
                        Environment.SpecialFolder.LocalApplicationData),
                    "WorkspaceServiceWidget",
                    "state.json");
            }

            Dictionary<string, object> parameters =
                new Dictionary<string, object>(
                    StringComparer.OrdinalIgnoreCase);
            parameters["ProjectRoot"] = projectRoot;
            parameters["StatePath"] = statePath;
            if (options.NoDesktopAttach)
            {
                parameters["NoDesktopAttach"] = true;
            }

            string appScript = Path.Combine(
                projectRoot,
                "app",
                "WorkspaceWidget.ps1");
            InvokePowerShellScript(appScript, parameters);
            return 0;
        }

        private static int RunAutostartAction(
            string projectRoot,
            string action,
            bool silent)
        {
            if (HasPackageIdentity())
            {
                return RunPackagedAutostartAction(action, silent);
            }

            string scriptPath = Path.Combine(
                projectRoot,
                "scripts",
                "Set-WorkspaceWidgetAutostart.ps1");
            if (!File.Exists(scriptPath))
            {
                throw new FileNotFoundException(
                    "The autostart helper was not found.",
                    scriptPath);
            }

            Dictionary<string, object> parameters =
                new Dictionary<string, object>(
                    StringComparer.OrdinalIgnoreCase);
            parameters["Action"] = action;
            parameters["ProjectRoot"] = projectRoot;
            Collection<PSObject> output = InvokePowerShellScript(
                scriptPath,
                parameters);

            string payload = String.Join(
                Environment.NewLine,
                output.Select(item => item == null ? String.Empty : item.ToString()));
            if (!String.IsNullOrWhiteSpace(payload))
            {
                WriteHostLog(
                    "Autostart action '" + action + "' completed. " + payload);
                Console.Out.WriteLine(payload);
            }
            if (
                String.IsNullOrWhiteSpace(payload) ||
                Regex.IsMatch(
                    payload,
                    "\"success\"\\s*:\\s*false",
                    RegexOptions.IgnoreCase))
            {
                throw new InvalidOperationException(
                    "The startup configuration action did not succeed.\r\n" +
                    payload);
            }
            if (!silent && String.Equals(
                action,
                "Get",
                StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(
                    payload,
                    "Workspace Widget startup status",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            return 0;
        }

        private static int RunPackagedAutostartAction(
            string action,
            bool silent)
        {
            StartupTask startupTask = StartupTask
                .GetAsync(PackagedStartupTaskId)
                .AsTask()
                .GetAwaiter()
                .GetResult();
            StartupTaskState before = startupTask.State;
            StartupTaskState after = before;

            if (
                String.Equals(action, "Enable", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(action, "Ensure", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(action, "Repair", StringComparison.OrdinalIgnoreCase))
            {
                if (before == StartupTaskState.Disabled)
                {
                    after = startupTask
                        .RequestEnableAsync()
                        .AsTask()
                        .GetAwaiter()
                        .GetResult();
                }
            }
            else if (
                String.Equals(action, "Disable", StringComparison.OrdinalIgnoreCase) ||
                String.Equals(action, "Unregister", StringComparison.OrdinalIgnoreCase))
            {
                if (before == StartupTaskState.Enabled)
                {
                    startupTask.Disable();
                    after = startupTask.State;
                }
            }
            else if (!String.Equals(
                action,
                "Get",
                StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "Unsupported packaged startup action: " + action);
            }

            string state = GetPortableStartupState(after);
            bool userCanControl =
                after != StartupTaskState.DisabledByPolicy &&
                after != StartupTaskState.EnabledByPolicy;
            string payload = BuildPackagedAutostartPayload(
                action,
                before != after,
                state,
                after.ToString(),
                userCanControl);

            WriteHostLog(
                "Packaged startup action '" + action + "' completed. " +
                payload);
            Console.Out.WriteLine(payload);

            if (!silent && String.Equals(
                action,
                "Get",
                StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(
                    payload,
                    "Workspace Widget startup status",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information);
            }
            return 0;
        }

        private static string GetPortableStartupState(StartupTaskState state)
        {
            switch (state)
            {
                case StartupTaskState.Enabled:
                case StartupTaskState.EnabledByPolicy:
                    return "Enabled";
                case StartupTaskState.Disabled:
                    return "Disabled";
                case StartupTaskState.DisabledByUser:
                    return "DisabledByUser";
                case StartupTaskState.DisabledByPolicy:
                    return "DisabledByPolicy";
                default:
                    return "Unavailable";
            }
        }

        private static string BuildPackagedAutostartPayload(
            string action,
            bool changed,
            string state,
            string nativeState,
            bool userCanControl)
        {
            return "{" +
                "\"success\":true," +
                "\"action\":" + QuoteJson(action) + "," +
                "\"changed\":" + changed.ToString().ToLowerInvariant() + "," +
                "\"state\":" + QuoteJson(state) + "," +
                "\"nativeState\":" + QuoteJson(nativeState) + "," +
                "\"exists\":true," +
                "\"enabled\":" +
                    (state == "Enabled" ? "true" : "false") + "," +
                "\"configured\":true," +
                "\"owned\":true," +
                "\"userCanControl\":" +
                    userCanControl.ToString().ToLowerInvariant() + "," +
                "\"runtime\":\"PackageStartupTask\"," +
                "\"delaySeconds\":0," +
                "\"error\":null" +
                "}";
        }

        private static string QuoteJson(string value)
        {
            if (value == null)
            {
                return "null";
            }
            return "\"" +
                value
                    .Replace("\\", "\\\\")
                    .Replace("\"", "\\\"")
                    .Replace("\r", "\\r")
                    .Replace("\n", "\\n")
                    .Replace("\t", "\\t") +
                "\"";
        }

        private static Collection<PSObject> InvokePowerShellScript(
            string scriptPath,
            IDictionary<string, object> parameters)
        {
            InitialSessionState sessionState =
                InitialSessionState.CreateDefault();
            sessionState.ExecutionPolicy = ExecutionPolicy.Bypass;

            using (Runspace runspace = RunspaceFactory.CreateRunspace(
                sessionState))
            {
                runspace.ApartmentState = System.Threading.ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();

                using (PowerShell powerShell = PowerShell.Create())
                {
                    powerShell.Runspace = runspace;
                    powerShell.AddCommand(scriptPath);
                    foreach (KeyValuePair<string, object> parameter in parameters)
                    {
                        powerShell.AddParameter(
                            parameter.Key,
                            parameter.Value);
                    }

                    Collection<PSObject> output = powerShell.Invoke();
                    if (powerShell.HadErrors)
                    {
                        string errorText = String.Join(
                            Environment.NewLine,
                            powerShell.Streams.Error.Select(
                                error => error == null
                                    ? String.Empty
                                    : error.ToString()));
                        throw new InvalidOperationException(
                            "PowerShell runtime reported an error.\r\n" +
                            errorText);
                    }
                    return output;
                }
            }
        }

        private static void WriteHostLog(string message)
        {
            try
            {
                string root = Path.Combine(
                    Environment.GetFolderPath(
                        Environment.SpecialFolder.LocalApplicationData),
                    HostLogDirectory);
                Directory.CreateDirectory(root);
                string line = DateTimeOffset.Now.ToString("o") +
                    " " + message + Environment.NewLine;
                File.AppendAllText(
                    Path.Combine(root, HostLogFile),
                    line,
                    new UTF8Encoding(false));
            }
            catch
            {
            }
        }

        private sealed class HostOptions
        {
            public string ProjectRoot { get; private set; }
            public string StatePath { get; private set; }
            public string AutostartAction { get; private set; }
            public bool NoDesktopAttach { get; private set; }
            public bool Silent { get; private set; }

            private HostOptions()
            {
            }

            public static HostOptions Parse(string[] args)
            {
                HostOptions result = new HostOptions();
                for (int index = 0; index < args.Length; index++)
                {
                    string argument = args[index];
                    if (String.Equals(
                        argument,
                        "--project-root",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        result.ProjectRoot = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(
                        argument,
                        "--state-path",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        result.StatePath = ReadValue(args, ref index, argument);
                    }
                    else if (String.Equals(
                        argument,
                        "--autostart",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        result.AutostartAction = ReadValue(
                            args,
                            ref index,
                            argument);
                    }
                    else if (String.Equals(
                        argument,
                        "--no-desktop-attach",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        result.NoDesktopAttach = true;
                    }
                    else if (String.Equals(
                        argument,
                        "--silent",
                        StringComparison.OrdinalIgnoreCase))
                    {
                        result.Silent = true;
                    }
                    else
                    {
                        throw new ArgumentException(
                            "Unknown Workspace Widget option: " + argument);
                    }
                }
                return result;
            }

            private static string ReadValue(
                string[] args,
                ref int index,
                string option)
            {
                if (index + 1 >= args.Length)
                {
                    throw new ArgumentException(
                        "Missing value for " + option + ".");
                }
                index++;
                return args[index];
            }
        }
    }
}
