#define AppName "Coinflip"
#define AppVersion "1.10.2605.01368"
#define AppExeName "Coinflip_V1.10.exe"
#define AppSetupName "Coinflip_V1.10_Setup.exe"
#define AppPublisher "John Torset"
#define AppURL "https://github.com/JTorset66/Coinflip"
#define AppIconName "Noto_Emoji_Coin.ico"
#define AppWizardImageName "installer-wizard-image.bmp"
#define AppWizardSmallImageName "installer-wizard-small.bmp"
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
DisableProgramGroupPage=yes
OutputDir=build
OutputBaseFilename=Coinflip_V1.10_Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
WizardImageFile={#AppWizardImageName}
WizardSmallImageFile={#AppWizardSmallImageName}
WizardImageBackColor=#155baa
WizardSmallImageBackColor=#155baa
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
UninstallDisplayIcon={app}\{#AppExeName}
CloseApplications=yes
CloseApplicationsFilter={#AppExeName}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription=Coinflip Setup
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
#ifdef HasAppIcon
SetupIconFile={#AppIconName}
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
SetupAppTitle=Coinflip Setup
SetupWindowTitle=Coinflip Setup
UninstallAppTitle=Coinflip Uninstall
UninstallAppFullTitle=Coinflip Uninstall
WelcomeLabel1=Welcome to Coinflip
WelcomeLabel2=This wizard installs [name/ver].%n%nCoinflip is a Windows x64 simulator for large fair-coin experiments. It measures absolute deviation from the expected 50/50 result, supports bit-exact and binomial sampling modes, and plots live or loaded data against a bell curve.%n%nThe installer creates a desktop shortcut automatically.
ExitSetupMessage=Setup is not complete. If you exit now, Coinflip will not be installed.%n%nExit Setup?
SelectDirDesc=Choose the installation folder.
SelectDirLabel3=Setup will install Coinflip into the following folder.
SelectDirBrowseLabel=Click Next to continue, or Browse to choose a different folder.
ReadyLabel1=Setup is ready to install Coinflip.
ReadyLabel2a=Coinflip is a Windows x64 fair-coin simulation and deviation analysis tool. It runs high-volume coin-flip experiments, measures how far each sample deviates from the expected 50/50 result, and plots live or loaded data against a bell curve.%n%nSetup will install Coinflip, create a desktop shortcut, and include the user README, license, and third-party notices.%n%nClick Install to continue, or Back to review or change any settings.
ReadyLabel2b=Coinflip is a Windows x64 fair-coin simulation and deviation analysis tool. It runs high-volume coin-flip experiments, measures how far each sample deviates from the expected 50/50 result, and plots live or loaded data against a bell curve.%n%nSetup will install Coinflip, create a desktop shortcut, and include the user README, license, and third-party notices.%n%nClick Install to continue.
InstallingLabel=Please wait while Setup installs Coinflip and creates the desktop shortcut.
FinishedHeadingLabel=Completing Coinflip Setup
FinishedLabelNoIcons=Coinflip has been installed.
FinishedLabel=Coinflip has been installed. You can launch it from the desktop shortcut.
ConfirmUninstall=Remove %1 from this computer?
UninstallStatusLabel=Please wait while %1 is removed.
UninstalledAll=%1 was successfully removed.
UninstalledMost=%1 uninstall complete.%n%nSome files could not be removed and may be deleted manually.

[Files]
Source: "build\{#AppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#AppIconName}"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
Source: "INSTALLER_README.md"; DestDir: "{app}"; DestName: "README.md"; Flags: ignoreversion
Source: "THIRD_PARTY_NOTICES.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "INSTALLER_README.md"; DestName: "Coinflip_README.md"; Flags: dontcopy
Source: "THIRD_PARTY_NOTICES.md"; DestName: "Coinflip_THIRD_PARTY_NOTICES.md"; Flags: dontcopy
Source: "LICENSE"; DestName: "Coinflip_LICENSE.txt"; Flags: dontcopy

[Icons]
Name: "{commondesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; IconFilename: "{app}\{#AppIconName}"; Check: IconFileExists
Name: "{commondesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Check: not IconFileExists

[Run]
Filename: "{app}\{#AppExeName}"; Description: "Launch Coinflip"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: files; Name: "{app}\{#AppSetupName}"

[Code]
const
  UninstallRegSubkey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{C2D08634-6D8A-4864-AAB0-BE31C925CA33}_is1';

var
  IncludedFilesPage: TWizardPage;

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

procedure OpenIncludedTextFile(const FileName: string);
var
  ResultCode: Integer;
  TempPath: string;
begin
  ExtractTemporaryFile(FileName);
  TempPath := ExpandConstant('{tmp}\' + FileName);

  if not Exec(ExpandConstant('{sys}\notepad.exe'), QuoteValue(TempPath), '', SW_SHOWNORMAL, ewNoWait, ResultCode) then
    MsgBox('Coinflip Setup could not open ' + FileName + '.', mbError, MB_OK);
end;

procedure ReadmeButtonClick(Sender: TObject);
begin
  OpenIncludedTextFile('Coinflip_README.md');
end;

procedure LicenseButtonClick(Sender: TObject);
begin
  OpenIncludedTextFile('Coinflip_LICENSE.txt');
end;

procedure ThirdPartyButtonClick(Sender: TObject);
begin
  OpenIncludedTextFile('Coinflip_THIRD_PARTY_NOTICES.md');
end;

procedure CreateIncludedFileButton(const Caption: string; Top: Integer; OnClick: TNotifyEvent);
var
  Button: TNewButton;
begin
  Button := TNewButton.Create(IncludedFilesPage);
  Button.Parent := IncludedFilesPage.Surface;
  Button.Caption := Caption;
  Button.Left := 0;
  Button.Top := Top;
  Button.Width := ScaleX(190);
  Button.Height := WizardForm.NextButton.Height;
  Button.OnClick := OnClick;
end;

procedure CreateIncludedFilesPage;
var
  BodyText: TNewStaticText;
  ButtonTop: Integer;
begin
  IncludedFilesPage :=
    CreateCustomPage(
      wpSelectDir,
      'Read Included Files',
      'Open the documents bundled with Coinflip before installing.'
    );

  BodyText := TNewStaticText.Create(IncludedFilesPage);
  BodyText.Parent := IncludedFilesPage.Surface;
  BodyText.Left := 0;
  BodyText.Top := 0;
  BodyText.Width := IncludedFilesPage.SurfaceWidth;
  BodyText.Height := ScaleY(60);
  BodyText.WordWrap := True;
  BodyText.Caption :=
    'Coinflip Setup includes a user README, license, and third-party notices. ' +
    'Use these buttons to read them now; the same files will also be installed with Coinflip.';

  ButtonTop := BodyText.Top + BodyText.Height + ScaleY(18);
  CreateIncludedFileButton('Read README', ButtonTop, @ReadmeButtonClick);
  CreateIncludedFileButton('Read License', ButtonTop + ScaleY(36), @LicenseButtonClick);
  CreateIncludedFileButton('Read Third-Party Notices', ButtonTop + ScaleY(72), @ThirdPartyButtonClick);
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
      'Coinflip is already installed.'#13#13 +
      'Choose Yes to repair or update Coinflip.'#13 +
      'Choose No to uninstall Coinflip.'#13 +
      'Choose Cancel to exit without making changes.',
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

procedure InitializeWizard;
begin
  CreateIncludedFilesPage();
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
var
  I: Integer;
begin
  for I := 0 to 1 do
  begin
    RunHiddenAndWait(ExpandConstant('{sys}\taskkill.exe'), '/IM {#AppExeName} /F /T');
    Sleep(300);
  end;
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
