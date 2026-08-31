[Code]
const
  InvalidFileAttributes = $FFFFFFFF;
  FileAttributeReparsePoint = $00000400;

function WindowsGetFileAttributes(FileName: String): DWORD;
  external 'GetFileAttributesW@kernel32.dll stdcall';

function ManifestPath(const Line: String): String;
begin
  Result := '';
  if (Length(Line) < 67) or (Copy(Line, 65, 2) <> '  ') then
    Exit;
  Result := Copy(Line, 67, MaxInt);
  StringChangeEx(Result, '/', '\', True);
end;

function IsSafeRelativePath(const Value: String): Boolean;
var
  Bounded: String;
begin
  Result := False;
  if (Value = '') or (Value[1] = '\') or (Pos(':', Value) > 0) then
    Exit;
  Bounded := '\' + Value + '\';
  if (Pos('\..\', Bounded) > 0) or (Pos('\.\', Bounded) > 0) then
    Exit;
  Result := True;
end;

function ManifestContains(const Lines: TArrayOfString; const RelativePath: String): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to GetArrayLength(Lines) - 1 do
    if CompareText(ManifestPath(Lines[I]), RelativePath) = 0 then
    begin
      Result := True;
      Exit;
    end;
end;

function HasReparseDirectory(const FilePath: String): Boolean;
var
  AppDirectory: String;
  Attributes: DWORD;
  Directory: String;
  Parent: String;
begin
  Result := True;
  AppDirectory := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));
  Directory := ExtractFileDir(FilePath);
  while Length(Directory) >= Length(AppDirectory) do
  begin
    Attributes := WindowsGetFileAttributes(Directory);
    if (Attributes = InvalidFileAttributes) or
       ((Attributes and FileAttributeReparsePoint) <> 0) then
      Exit;
    if CompareText(Directory, AppDirectory) = 0 then
    begin
      Result := False;
      Exit;
    end;
    Parent := ExtractFileDir(Directory);
    if CompareText(Parent, Directory) = 0 then
      Exit;
    Directory := Parent;
  end;
end;

procedure RemoveEmptyParents(const FilePath: String);
var
  AppDirectory: String;
  Directory: String;
begin
  AppDirectory := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));
  Directory := ExtractFileDir(FilePath);
  while (Length(Directory) > Length(AppDirectory)) and
        (CompareText(Directory, AppDirectory) <> 0) do
  begin
    if not RemoveDir(Directory) then
      Exit;
    Directory := ExtractFileDir(Directory);
  end;
end;

#include "CodexBridgeLegacyMigration.iss"

function RemoveStalePayloadFiles: String;
var
  I: Integer;
  InstalledManifest: String;
  NewManifest: String;
  OldLines: TArrayOfString;
  NewLines: TArrayOfString;
  RelativePath: String;
  InstalledPath: String;
begin
  Result := '';
  InstalledManifest := ExpandConstant('{app}\SHA256SUMS.txt');
  ExtractTemporaryFile('SHA256SUMS.txt');
  NewManifest := ExpandConstant('{tmp}\SHA256SUMS.txt');
  if not FileExists(InstalledManifest) then
  begin
    Result := RemoveLegacyPayloadFiles(NewManifest);
    Exit;
  end;
  if not LoadStringsFromFile(InstalledManifest, OldLines) or
     not LoadStringsFromFile(NewManifest, NewLines) then
  begin
    Result := 'Codex Bridge could not read its payload manifest.';
    Exit;
  end;

  for I := 0 to GetArrayLength(OldLines) - 1 do
  begin
    RelativePath := ManifestPath(OldLines[I]);
    if not IsSafeRelativePath(RelativePath) then
      Continue;
    if ManifestContains(NewLines, RelativePath) then
      Continue;
    InstalledPath := AddBackslash(ExpandConstant('{app}')) + RelativePath;
    if FileExists(InstalledPath) and HasReparseDirectory(InstalledPath) then
    begin
      Result := 'Codex Bridge found an unsafe application directory.';
      Exit;
    end;
    if FileExists(InstalledPath) and not DeleteFile(InstalledPath) then
    begin
      Result := 'Codex Bridge could not remove an obsolete application file.';
      Exit;
    end;
    RemoveEmptyParents(InstalledPath);
  end;
end;

function StopInstalledService(var ErrorMessage: String): Boolean;
var
  ExitCode: Integer;
  ServicePath: String;
begin
  Result := True;
  ErrorMessage := '';
  ServicePath := ExpandConstant('{app}\codex-bridge-service.exe');
  if not FileExists(ServicePath) then
    Exit;
  if not Exec(ServicePath, '--shutdown', ExpandConstant('{app}'), SW_HIDE,
              ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
  begin
    ErrorMessage := 'Codex Bridge could not stop its background service. Close the app and try again.';
    Result := False;
  end;
end;

function StopInstalledApplication(var ErrorMessage: String): Boolean;
var
  AppPath: String;
  ExitCode: Integer;
begin
  Result := True;
  ErrorMessage := '';
  AppPath := ExpandConstant('{app}\codex-bridge-windows-app.exe');
  if not FileExists(AppPath) then
    Exit;
  if not Exec(AppPath, '--shutdown', ExpandConstant('{app}'), SW_HIDE,
              ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
  begin
    ErrorMessage := 'Codex Bridge could not stop its desktop application. Close the app and try again.';
    Result := False;
  end;
end;

function StopInstalledProcesses(var ErrorMessage: String): Boolean;
begin
  ErrorMessage := '';
  if not FileExists(ExpandConstant('{app}\CodexBridgeControl.v1')) then
  begin
    Result := True;
    Exit;
  end;
  Result := StopInstalledApplication(ErrorMessage);
  if Result then
    Result := StopInstalledService(ErrorMessage);
end;

procedure RemoveMatchingLegacyRunEntry;
var
  ConfiguredCommand: String;
  InstalledCommand: String;
begin
  InstalledCommand := '"' + ExpandConstant('{app}\codex-bridge-service.exe') + '"';
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
       'CodexBridgeService', ConfiguredCommand) and
     (CompareText(ConfiguredCommand, InstalledCommand) = 0) then
    RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run',
      'CodexBridgeService');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExpectedDirectory: String;
begin
  Result := '';
  ExpectedDirectory := ExpandConstant('{localappdata}\Programs\CodexBridge');
  if CompareText(RemoveBackslashUnlessRoot(ExpandConstant('{app}')),
       RemoveBackslashUnlessRoot(ExpectedDirectory)) <> 0 then
  begin
    Result := 'Codex Bridge must be installed in its fixed per-user application directory.';
    Exit;
  end;
  if DirExists(ExpandConstant('{app}')) and
     HasReparseDirectory(ExpandConstant('{app}\payload-check')) then
  begin
    Result := 'Codex Bridge found an unsafe application directory.';
    Exit;
  end;
  if not StopInstalledProcesses(Result) then
    Exit;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ErrorMessage: String;
begin
  if CurStep = ssInstall then
  begin
    ErrorMessage := RemoveStalePayloadFiles;
    if ErrorMessage <> '' then
      RaiseException(ErrorMessage);
  end;
  if CurStep = ssPostInstall then
    RemoveMatchingLegacyRunEntry;
end;

function InitializeUninstall: Boolean;
var
  ErrorMessage: String;
begin
  Result := StopInstalledProcesses(ErrorMessage);
  if not Result then
    SuppressibleMsgBox(ErrorMessage, mbError, MB_OK, IDOK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveMatchingLegacyRunEntry;
end;
