#ifndef AppVersion
  #define AppVersion "0.2.0"
#endif
#ifndef ProjectRoot
  #define ProjectRoot ".."
#endif
#ifndef StageRoot
  #define StageRoot "..\artifacts\staging\WorkspaceWidget"
#endif
#ifndef OutputRoot
  #define OutputRoot "..\artifacts"
#endif

#define AppName "Workspace Widget"
#define AppPublisher "Workspace Widget Contributors"
#define AppExeName "WorkspaceWidget.exe"
#define AppId "{{A8930564-508B-49AC-A5B6-43E81B02A7F6}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
DefaultDirName={localappdata}\Programs\WorkspaceWidget
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir={#OutputRoot}
OutputBaseFilename=WorkspaceWidget-Setup-{#AppVersion}
SetupIconFile={#ProjectRoot}\assets\workspace-widget.ico
UninstallDisplayIcon={app}\{#AppExeName}
LicenseFile={#ProjectRoot}\LICENSE
InfoAfterFile={#ProjectRoot}\docs\INSTALLATION.md
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
ChangesEnvironment=no
ChangesAssociations=no
AllowNoIcons=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=Workspace Widget installer
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
VersionInfoCopyright=Copyright (c) 2026 Workspace Widget Contributors

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "korean"; MessagesFile: "compiler:Languages\Korean.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce
Name: "autostart"; Description: "Start Workspace Widget when I sign in"; GroupDescription: "Startup:"; Flags: checkedonce; Check: ShouldOfferAutostartTask

[Files]
Source: "{#StageRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Workspace Widget"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\assets\workspace-widget.ico"
Name: "{group}\Workspace Widget Documentation"; Filename: "{app}\README.md"
Name: "{autodesktop}\Workspace Widget"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\assets\workspace-widget.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Parameters: "--autostart Repair --silent"; WorkingDir: "{app}"; StatusMsg: "Repairing startup registration..."; Flags: runhidden waituntilterminated; Check: ShouldRepairAutostart
Filename: "{app}\{#AppExeName}"; Parameters: "--autostart Enable --silent"; WorkingDir: "{app}"; StatusMsg: "Configuring startup..."; Flags: runhidden waituntilterminated; Check: ShouldConfigureAutostart
Filename: "{app}\{#AppExeName}"; Description: "Launch Workspace Widget"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\{#AppExeName}"; Parameters: "--autostart Unregister --silent"; WorkingDir: "{app}"; Flags: runhidden waituntilterminated skipifdoesntexist

[Code]
var
  ExistingAutostartStateKnown: Boolean;
  ExistingAutostartTaskFound: Boolean;
  ExistingAutostartTaskEnabled: Boolean;

procedure ReadExistingAutostartState();
var
  TaskService, TaskFolder, RegisteredTask: Variant;
begin
  ExistingAutostartStateKnown := False;
  ExistingAutostartTaskFound := False;
  ExistingAutostartTaskEnabled := False;

  try
    TaskService := CreateOleObject('Schedule.Service');
    TaskService.Connect();
    TaskFolder := TaskService.GetFolder('\');
    ExistingAutostartStateKnown := True;

    try
      RegisteredTask := TaskFolder.GetTask('Workspace Service Widget');
      ExistingAutostartTaskFound := True;
      ExistingAutostartTaskEnabled := RegisteredTask.Enabled;
      if ExistingAutostartTaskEnabled then
        Log('Existing Workspace Widget autostart task found and enabled.')
      else
        Log('Existing Workspace Widget autostart task found and disabled.');
    except
      Log('No existing Workspace Widget autostart task was found.');
    end;
  except
    Log(
      'Could not inspect the existing Workspace Widget autostart task: ' +
      GetExceptionMessage);
  end;
end;

function InitializeSetup(): Boolean;
begin
  Result := True;
  if not IsWin64 then
  begin
    MsgBox(
      'Workspace Widget currently supports 64-bit Windows 11 only.',
      mbError,
      MB_OK);
    Result := False;
  end;

  if Result then
    ReadExistingAutostartState();
end;

function ShouldOfferAutostartTask(): Boolean;
begin
  Result := not ExistingAutostartTaskFound;
end;

function ShouldRepairAutostart(): Boolean;
begin
  Result := ExistingAutostartStateKnown and ExistingAutostartTaskFound;
end;

function ShouldConfigureAutostart(): Boolean;
begin
  Result :=
    (not ExistingAutostartTaskFound) and
    WizardIsTaskSelected('autostart');
end;
