#ifndef PayloadDir
  #error PayloadDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef Architecture
  #error Architecture is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef OutputBaseFilename
  #error OutputBaseFilename is required
#endif
#ifndef Compression
  #define Compression "lzma2/max"
#endif

[Setup]
AppId={{6F51B5A4-4C25-4E72-A8E5-93447D72D031}
AppName=Codex Bridge
AppVersion={#AppVersion}
AppPublisher=Codex Bridge
AppPublisherURL=https://github.com/yeyuancc0-glitch/codex-bridge
AppSupportURL=https://github.com/yeyuancc0-glitch/codex-bridge/issues
DefaultDirName={localappdata}\Programs\CodexBridge
DefaultGroupName=Codex Bridge
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression={#Compression}
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={app}\CodexBridge.App.exe
VersionInfoVersion={#AppVersion}
VersionInfoDescription=Codex Bridge Installer
VersionInfoProductName=Codex Bridge
#if Architecture == "ARM64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible and not arm64
ArchitecturesInstallIn64BitMode=x64compatible and not arm64
#endif

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Codex Bridge"; Filename: "{app}\CodexBridge.App.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\CodexBridge.App.exe"; Description: "启动 Codex Bridge"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExpectedDirectory: String;
begin
  ExpectedDirectory := ExpandConstant('{localappdata}\Programs\CodexBridge');
  if CompareText(ExpandConstant('{app}'), ExpectedDirectory) <> 0 then
    Result := 'Codex Bridge must be installed in the fixed per-user application directory.';
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ConfiguredCommand: String;
  InstalledCommand: String;
begin
  if CurUninstallStep <> usUninstall then
    Exit;
  InstalledCommand := '"' + ExpandConstant('{app}\codex-bridge-service.exe') + '"';
  if RegQueryStringValue(
       HKCU,
       'Software\Microsoft\Windows\CurrentVersion\Run',
       'CodexBridgeService',
       ConfiguredCommand) and
     (CompareText(ConfiguredCommand, InstalledCommand) = 0) then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'CodexBridgeService');
end;
