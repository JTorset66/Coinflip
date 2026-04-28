#define AppName "Coinflip"
#define AppVersion "1.10"
#define AppExeName "Coinflip_V1.10.exe"
#define AppSetupName "Coinflip_V1.10_Setup.exe"
#define AppPublisher "John Torset"
#define AppURL "https://github.com/JTorset66/Coinflip"
#define AppIconName "Noto_Emoji_Coin.ico"
#define AppId "{{C2D08634-6D8A-4864-AAB0-BE31C925CA33}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
AppVerName={#AppName} {#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
OutputDir=build
OutputBaseFilename=Coinflip_V1.10_Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
CloseApplicationsFilter={#AppExeName}
#ifdef HasAppIcon
SetupIconFile={#AppIconName}
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "build\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#AppIconName}"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppIconName}"; Check: IconFileExists
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Check: not IconFileExists
Name: "{commondesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppIconName}"; Tasks: desktopicon; Check: IconFileExists
Name: "{commondesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon; Check: not IconFileExists

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(AppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\{#AppSetupName}"

[Code]
const
  UninstallRegSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{C2D08634-6D8A-4864-AAB0-BE31C925CA33}_is1';

function QuoteValue(const Value: string): string;
begin
  Result := '"' + Value + '"';
end;

function IconFileExists: Boolean;
begin
  Result := FileExists(ExpandConstant('{app}\{#AppIconName}'));
end;

function MaintenanceMode: Boolean;
begin
  Result := ExpandConstant('{param:maintenance|0}') = '1';
end;

function QueryUninstallValue(const ValueName: string; var Value: string): Boolean;
begin
  Result :=
    RegQueryStringValue(HKLM64, UninstallRegSubkey, ValueName, Value) or
    RegQueryStringValue(HKLM, UninstallRegSubkey, ValueName, Value);
end;

function InstalledUninstallerPath: string;
var
  InstallLocation: string;
begin
  Result := '';
  if QueryUninstallValue('InstallLocation', InstallLocation) then
    Result := AddBackslash(RemoveBackslashUnlessRoot(InstallLocation)) + 'unins000.exe';
end;

procedure WriteMaintenanceRegistry;
var
  MaintenanceCommand: string;
  QuietCommand: string;
begin
  MaintenanceCommand := QuoteValue(ExpandConstant('{app}\{#AppSetupName}')) + ' /maintenance=1';
  QuietCommand := QuoteValue(ExpandConstant('{app}\unins000.exe')) + ' /SILENT';

  RegWriteStringValue(HKLM64, UninstallRegSubkey, 'ModifyPath', MaintenanceCommand);
  RegWriteStringValue(HKLM64, UninstallRegSubkey, 'UninstallString', MaintenanceCommand);
  RegWriteStringValue(HKLM64, UninstallRegSubkey, 'QuietUninstallString', QuietCommand);
  RegWriteDWordValue(HKLM64, UninstallRegSubkey, 'NoModify', 0);
  RegWriteDWordValue(HKLM64, UninstallRegSubkey, 'NoRepair', 0);
end;

procedure EnsureInstalledMaintenanceSetup;
var
  SourcePath: string;
  TargetPath: string;
begin
  SourcePath := ExpandConstant('{srcexe}');
  TargetPath := ExpandConstant('{app}\{#AppSetupName}');

  if CompareText(SourcePath, TargetPath) = 0 then
  begin
    Log('Setup already running from the installed maintenance path.');
    Exit;
  end;

  if CopyFile(SourcePath, TargetPath, False) then
    Log(Format('Copied maintenance setup: %s -> %s', [SourcePath, TargetPath]))
  else
    Log(Format('Failed to copy maintenance setup: %s -> %s', [SourcePath, TargetPath]));
end;

function LaunchInstalledUninstaller: Boolean;
var
  UninstallerPath: string;
  ResultCode: Integer;
begin
  Result := False;
  UninstallerPath := InstalledUninstallerPath();
  if (UninstallerPath = '') or (not FileExists(UninstallerPath)) then
  begin
    MsgBox('Coinflip is not currently installed, so there is nothing to uninstall.', mbInformation, MB_OK);
    Exit;
  end;

  if Exec(UninstallerPath, '', '', SW_SHOWNORMAL, ewNoWait, ResultCode) then
    Result := True
  else
    MsgBox('Coinflip could not start its uninstaller.', mbError, MB_OK);
end;

function InitializeSetup(): Boolean;
var
  Choice: Integer;
begin
  Result := True;

  if not MaintenanceMode() then
    Exit;

  Choice :=
    MsgBox(
      'Coinflip maintenance:'#13#13 +
      'Yes = Repair install'#13 +
      'No = Uninstall'#13 +
      'Cancel = Exit without changes',
      mbConfirmation,
      MB_YESNOCANCEL
    );

  case Choice of
    IDYES:
      Result := True;
    IDNO:
      begin
        LaunchInstalledUninstaller();
        Result := False;
      end;
  else
    Result := False;
  end;
end;

function RunHiddenAndWait(const FileName, Params: string): Integer;
var
  ResultCode: Integer;
begin
  if Exec(FileName, Params, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
  begin
    Log(Format('Executed: %s %s -> %d', [FileName, Params, ResultCode]));
    Result := ResultCode;
  end
  else
  begin
    Log(Format('Failed to execute: %s %s', [FileName, Params]));
    Result := -1;
  end;
end;

procedure StopRunningCoinflip;
begin
  RunHiddenAndWait(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExeName} /F /T');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  case CurStep of
    ssInstall:
      StopRunningCoinflip();

    ssPostInstall:
      begin
        EnsureInstalledMaintenanceSetup();
        WriteMaintenanceRegistry();
      end;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    StopRunningCoinflip();
end;
