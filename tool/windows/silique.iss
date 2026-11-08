#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppBuild
  #error AppBuild is required
#endif
#ifndef BundleDir
  #error BundleDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
AppId={{1A327809-A7B2-5F2D-B263-D46B18C17B6B}
AppName=Silique
AppVersion={#AppVersion}
AppVerName=Silique {#AppVersion}
AppPublisher=Silique
VersionInfoVersion={#AppVersion}.{#AppBuild}
; A persistent CFA permission is bound to an executable path. Keep the full
; bundle in an administrator-managed directory, not user-writable AppData.
; Do not inherit the destination of a legacy per-user installation. That copy
; is left intact; vaults, keys and preferences are never migrated by Setup.
DefaultDirName={autopf}\Silique
UsePreviousAppDir=no
DefaultGroupName=Silique
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=Silique-{#AppVersion}-Setup-Windows-x64
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\silique.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupMutex=Global\Silique.Setup.1A327809-A7B2-5F2D-B263-D46B18C17B6B
AppMutex=Global\Silique.App.1A327809-A7B2-5F2D-B263-D46B18C17B6B
; Never force-terminate a notebook. In-app mode additionally waits for its
; original process to exit through the authenticated guard protocol.
CloseApplications=no
RestartApplications=no

[Languages]
Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Silique"; Filename: "{app}\silique.exe"
Name: "{autodesktop}\Silique"; Filename: "{app}\silique.exe"; Tasks: desktopicon

; Setup never launches the notebook: a post-install launch inherits Setup's
; elevated token when the user started Setup "as administrator", and Inno's
; RunasOriginalUser is not a de-elevation guarantee. The notebook must never run
; with an administrator token, so the user starts it from the shortcut.
[Code]
// Native ownership/ACL/canonical checks have pinned the registered destination
// before launch. Preserve that exact machine-wide directory, including custom
// protected installs; never fall back to the default or an HKCU destination.
var
  VerifiedUpdateDirectory: String;
  ManualUpdateGate: Integer;

function InAppUpdate: Boolean;
begin
  Result := ExpandConstant('{param:SILIQUEUPDATE|0}') = '1';
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := InAppUpdate and (PageID = wpSelectDir);
end;

procedure InitializeWizard;
begin
  if InAppUpdate then
    WizardForm.DirEdit.Text := VerifiedUpdateDirectory;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if InAppUpdate and
    (CompareText(RemoveBackslashUnlessRoot(WizardDirValue),
      VerifiedUpdateDirectory) <> 0) then
    Result := 'Aktualizacja musi zachować dotychczasowy katalog instalacji.';
end;

// Setup is elevated, so the localappdata constant is the profile of the user
// who approved UAC - the profile that owns a legacy per-user copy if any.
function LegacyPerUserInstall: Boolean;
begin
  Result := FileExists(
    ExpandConstant('{localappdata}\Programs\Silique\silique.exe'));
end;

const
  MachineKey = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{1A327809-A7B2-5F2D-B263-D46B18C17B6B}_is1';
  UpdateMutex = 'Global\Silique.Update.1A327809-A7B2-5F2D-B263-D46B18C17B6B';

function NativeCreateFile(Name: String; Access, Share: LongWord; Security: Integer;
  Creation, Flags: LongWord; Template: Integer): Integer;
  external 'CreateFileW@kernel32.dll stdcall';
function NativeWriteFile(Handle: Integer; var Buffer: Byte; Count: LongWord;
  var Written: LongWord; Overlapped: Integer): Boolean;
  external 'WriteFile@kernel32.dll stdcall';
function NativeReadFile(Handle: Integer; var Buffer: Byte; Count: LongWord;
  var Read: LongWord; Overlapped: Integer): Boolean;
  external 'ReadFile@kernel32.dll stdcall';
function NativeCloseHandle(Handle: Integer): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function NativeOpenProcess(Access: LongWord; Inherit: Boolean; ProcessId: LongWord): Integer;
  external 'OpenProcess@kernel32.dll stdcall';
function NativeCurrentProcess: Integer;
  external 'GetCurrentProcess@kernel32.dll stdcall';
function NativeDuplicateHandle(SourceProcess, Source: Integer; TargetProcess: Integer;
  var Target: LongWord; Access: LongWord; Inherit: Boolean; Options: LongWord): Boolean;
  external 'DuplicateHandle@kernel32.dll stdcall';
function NativeWriteHandle(Handle: Integer; var Buffer: LongWord; Count: LongWord;
  var Written: LongWord; Overlapped: Integer): Boolean;
  external 'WriteFile@kernel32.dll stdcall';
function NativeCreateMutex(Security: Integer; InitialOwner: Boolean; Name: String): Integer;
  external 'CreateMutexW@kernel32.dll stdcall';

function NativeAttributes(Name: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';
#ifdef NativeAcceptance
function NativeOpenEvent(Access: LongWord; Inherit: Boolean; Name: String): Integer;
  external 'OpenEventW@kernel32.dll stdcall';
function NativeWait(Handle: Integer; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function NativeSetEvent(Handle: Integer): Boolean;
  external 'SetEvent@kernel32.dll stdcall';
#endif

function RegisteredInstall: Boolean;
var
  Directory, Uninstaller: String;
  Attr: LongWord;
begin
  Result := False;
  if not RegQueryStringValue(HKLM64, MachineKey, 'InstallLocation', Directory) then Exit;
  Directory := RemoveBackslashUnlessRoot(Directory);
  if (Length(Directory) < 4) or (Copy(Directory, 2, 2) <> ':\') then Exit;
  if CompareText(Directory, RemoveBackslashUnlessRoot(ExpandConstant('{param:DIR|}'))) <> 0 then Exit;
  if not RegQueryStringValue(HKLM64, MachineKey, 'UninstallString', Uninstaller) then Exit;
  if CompareText(Uninstaller, '"' + Directory + '\unins000.exe"') <> 0 then Exit;
  Attr := NativeAttributes(Directory);
  if (Attr = $FFFFFFFF) or ((Attr and $400) <> 0) then Exit;
  Attr := NativeAttributes(Directory + '\silique.exe');
  if (Attr = $FFFFFFFF) or ((Attr and $400) <> 0) then Exit;
  Result := FileExists(Directory + '\unins000.exe');
  if Result then VerifiedUpdateDirectory := Directory;
end;

function JoinGuard: Boolean;
var
  Token: String;
  I, Pipe, Guard: Integer;
  Hello, Ack: Byte;
  Count, GuardPid, RemoteProcess: LongWord;
begin
  Result := False;
  Token := ExpandConstant('{param:SILIQUEGUARD|}');
  if Length(Token) <> 32 then Exit;
  for I := 1 to Length(Token) do
    if Pos(Token[I], '0123456789abcdef') = 0 then Exit;
  { Identification SQOS: guard may query integrity, never act as this admin. }
  Pipe := NativeCreateFile('\\.\pipe\Silique.Update.' + Token,
    $C0000000, 0, 0, 3, $00110000, 0);
  if Pipe = -1 then Exit;
  try
    Hello := $53;
    if not NativeWriteFile(Pipe, Hello, 1, Count, 0) then Exit;
    if Count <> 1 then Exit;
    GuardPid := StrToIntDef(ExpandConstant('{param:SILIQUEGUARDPID|0}'), 0);
    if GuardPid = 0 then Exit;
    Guard := NativeOpenProcess($40, False, GuardPid);
    if Guard = 0 then Exit;
    try
      { SYNCHRONIZE + QUERY_LIMITED_INFORMATION, not a privileged process
        handle. Guard checks this handle's PID against the actual pipe peer. }
      if not NativeDuplicateHandle(NativeCurrentProcess, NativeCurrentProcess,
        Guard, RemoteProcess, $101000, False, 0) then Exit;
    finally
      NativeCloseHandle(Guard);
    end;
    if not NativeWriteHandle(Pipe, RemoteProcess, 4, Count, 0) then Exit;
    if Count <> 4 then Exit;
    { ACK comes ONLY after the original notebook process exits. Guard retains
      locks until THIS elevated Inno main process exits, not this pipe closes. }
    if not NativeReadFile(Pipe, Ack, 1, Count, 0) then Exit;
    Result := (Count = 1) and (Ack = $41);
  finally
    NativeCloseHandle(Pipe);
  end;
end;

#ifdef NativeAcceptance
procedure AcceptanceBarrier;
var
  Token: String;
  Ready, ContinueEvent: Integer;
begin
  Token := ExpandConstant('{param:SILIQUEACCEPTANCE|}');
  if Token = '' then RaiseException('Missing acceptance barrier token');
  Ready := NativeOpenEvent(2, False, 'Local\Silique.Acceptance.Ready.' + Token);
  ContinueEvent := NativeOpenEvent($100000, False, 'Local\Silique.Acceptance.Continue.' + Token);
  if (Ready = 0) or (ContinueEvent = 0) then RaiseException('Acceptance barrier unavailable');
  try
    if not NativeSetEvent(Ready) then RaiseException('Acceptance ready failed');
    if NativeWait(ContinueEvent, 120000) <> 0 then RaiseException('Acceptance continue timed out');
  finally
    NativeCloseHandle(Ready);
    NativeCloseHandle(ContinueEvent);
  end;
end;
#endif

procedure DeinitializeSetup;
begin
  if ManualUpdateGate <> 0 then NativeCloseHandle(ManualUpdateGate);
end;

#ifdef NativeAcceptance
procedure CurStepChanged(CurStep: TSetupStep);
var
  DoneEvent: Integer;
begin
  if InAppUpdate and (CurStep = ssDone) then
  begin
    DoneEvent := NativeOpenEvent(2, False, 'Local\Silique.Acceptance.Done.' +
      ExpandConstant('{param:SILIQUEACCEPTANCE|}'));
    if DoneEvent = 0 then RaiseException('Acceptance completion event unavailable');
    try
      if not NativeSetEvent(DoneEvent) then RaiseException('Acceptance completion failed');
    finally
      NativeCloseHandle(DoneEvent);
    end;
  end;
end;
#endif

function InitializeSetup: Boolean;
var
  Message: String;
begin
  Result := True;
  if InAppUpdate then
  begin
    Result := RegisteredInstall;
    if Result then Result := JoinGuard;
    if not Result then Exit;
#ifdef NativeAcceptance
    AcceptanceBarrier;
#endif
  end
  else
  begin
    { Atomic gate for manual Setup as well: no notebook may start after Inno's
      AppMutex check and race replacement. Held until the real Setup exits. }
    ManualUpdateGate := NativeCreateMutex(0, False, UpdateMutex);
    if (ManualUpdateGate = 0) or (DLLGetLastError = 183) then
    begin
      Result := False;
      Exit;
    end;
  end;
  if (not WizardSilent) and LegacyPerUserInstall then
  begin
    Message := 'Wykryto starszą instalację Silique w profilu użytkownika ' +
      '(AppData). Nowa wersja zostanie zainstalowana w Program Files i nie ' +
      'przeniesie ani nie usunie notatek, kluczy i ustawień. Stara kopia ' +
      'pozostanie na dysku, a jej skrót w menu Start nadal uruchomi starą ' +
      'wersję - usuń ją w Ustawienia > Aplikacje i usuń stary skrót, ' +
      'aby uniknąć pomyłki.';
    MsgBox(Message, mbInformation, MB_OK);
  end;
end;

// Vaults and system credentials are deliberately outside the installation
// directory. No uninstall rule removes user data.
