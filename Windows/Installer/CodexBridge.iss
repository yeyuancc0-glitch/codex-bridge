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

#if Architecture == "x64"
  #define SetupArchitecture "x64"
  #define AllowedArchitecture "x64os"
#elif Architecture == "arm64"
  #define SetupArchitecture "x86"
  #define AllowedArchitecture "arm64"
#else
  #error Architecture must be x64 or arm64
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
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no
SetupArchitecture={#SetupArchitecture}
ArchitecturesAllowed={#AllowedArchitecture}
ArchitecturesInstallIn64BitMode={#AllowedArchitecture}
UninstallDisplayIcon={app}\codex-bridge-windows-app.exe
VersionInfoVersion={#AppVersion}
VersionInfoDescription=Codex Bridge Installer
VersionInfoProductName=Codex Bridge
LicenseFile={#PayloadDir}\LICENSE.txt

[Files]
Source: "{#PayloadDir}\SHA256SUMS.txt"; Flags: dontcopy
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "CodexBridgeControl.v1"; DestDir: "{app}"; Flags: ignoreversion

[InstallDelete]
Type: files; Name: "{app}\CodexBridge.App.exe"
Type: files; Name: "{app}\CodexBridge.App.dll"
Type: files; Name: "{app}\CodexBridge.App.deps.json"
Type: files; Name: "{app}\CodexBridge.App.runtimeconfig.json"
Type: files; Name: "{app}\CodexBridge.App.pri"
Type: files; Name: "{app}\payload-manifest.json"

[Icons]
Name: "{group}\Codex Bridge"; Filename: "{app}\codex-bridge-windows-app.exe"; WorkingDir: "{app}"

[Run]
Filename: "{app}\codex-bridge-windows-app.exe"; Description: "启动 Codex Bridge"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent

#include "CodexBridgeLifecycle.iss"
