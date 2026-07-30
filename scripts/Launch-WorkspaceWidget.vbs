Option Explicit

Dim shell
Dim fileSystem
Dim scriptsRoot
Dim projectRoot
Dim startScript
Dim statePath
Dim windowsPowerShell
Dim command
Dim exitCode

Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")

scriptsRoot = fileSystem.GetParentFolderName(WScript.ScriptFullName)
projectRoot = fileSystem.GetParentFolderName(scriptsRoot)
startScript = fileSystem.BuildPath(scriptsRoot, "Start-WorkspaceWidget.ps1")
statePath = fileSystem.BuildPath(shell.ExpandEnvironmentStrings("%LOCALAPPDATA%"), "WorkspaceServiceWidget\state.json")
windowsPowerShell = fileSystem.BuildPath( _
  shell.ExpandEnvironmentStrings("%SystemRoot%"), _
  "System32\WindowsPowerShell\v1.0\powershell.exe" _
)

If Not fileSystem.FileExists(windowsPowerShell) Then
  WScript.Quit 2
End If

command = Quote(windowsPowerShell) & _
  " -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File " & _
  Quote(startScript) & " -ProjectRoot " & Quote(projectRoot) & " -StatePath " & Quote(statePath)

exitCode = shell.Run(command, 0, True)
WScript.Quit exitCode

Function Quote(value)
  Quote = Chr(34) & value & Chr(34)
End Function
