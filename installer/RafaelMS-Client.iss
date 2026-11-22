; RafaelMS client installer (original Nexon v83 client + MapleEzorsia v2)
; Build:  "%LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe" RafaelMS-Client.iss
; Output: Output\RafaelMS-Client-Setup.exe
;
; Players can also install silently and preset the server address:
;   RafaelMS-Client-Setup.exe /SILENT /SERVER=1.2.3.4
;
; No third-party localhost is shipped. MapleStory.exe is the unmodified,
; Nexon-signed v83 executable (taken from ManagerMsv83.exe); Ezorsia v2's
; dinput8.dll (built from C:\Nexon\CustomClient\MapleEzorsia-v2) is the
; standalone localhost that patches it in memory and connects to
; ServerIP_Address from config.ini.

#define AppName        "RafaelMS"
#define AppVersion     "1.4.0"
#define AppPublisher   "RafaelMS"
#define ClientSrc      "C:\Nexon\RafaelMS-Client"
#define ClientExe      "MapleStory.exe"
; Pre-filled on the "Server address" page. Change to your public IP before
; building a release so players can just click Next.
#define DefaultServer  "127.0.0.1"
; Bundled VC++ 2015-2022 x86 runtime version (needed by Ezorsia's dinput8.dll).
#define VCMajor 14
#define VCMinor 44
#define VCBld   35211

[Setup]
AppId={{7B1E6C2A-5F3D-4C8E-9A61-2D4F8B0E3A57}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} Client {#AppVersion}
AppPublisher={#AppPublisher}
; Per-user install: no UAC prompt, and the game folder stays writable
; (config.ini, screenshots, logs). UAC is only requested if the VC++ runtime
; has to be installed.
PrivilegesRequired=lowest
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
DefaultGroupName={#AppName}
UninstallDisplayIcon={app}\{#ClientExe}
UninstallDisplayName={#AppName} Client
SetupIconFile={#ClientSrc}\Icon.ico
OutputDir=Output
OutputBaseFilename={#AppName}-Client-Setup
Compression=lzma2/max
SolidCompression=yes
LZMAUseSeparateProcess=yes
LZMANumBlockThreads=4
ExtraDiskSpaceRequired=104857600
WizardStyle=modern
; The client is 32-bit and runs on both x86 and x64 Windows.
MinVersion=6.1sp1

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Remove the old third-party localhost from 1.0.0 installs (it was flagged by antivirus)
Type: files; Name: "{app}\HeavenMS-localhost-WINDOW.exe"

[UninstallDelete]
; Left behind by the 1.2.x/1.3.x client
Type: files; Name: "{app}\connection.log"

[Files]
; Original Nexon v83 client + Ezorsia v2 HD/standalone localhost (loaded automatically as dinput8.dll)
Source: "{#ClientSrc}\{#ClientExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#ClientSrc}\dinput8.dll"; DestDir: "{app}"; Flags: ignoreversion
; Keep the player's resolution/window settings on reinstall; the server IP is rewritten below anyway.
Source: "{#ClientSrc}\config.ini"; DestDir: "{app}"; Flags: onlyifdoesntexist
; Stock v83 runtime libraries. The excluded DLLs belong to the separate NX client or are test leftovers.
Source: "{#ClientSrc}\*.dll"; DestDir: "{app}"; Excludes: "dinput8.dll,dinput8.register-test-loaded.dll,bass.dll,freetype.dll,liblz4.dll"; Flags: ignoreversion
Source: "{#ClientSrc}\l3codeca.acm"; DestDir: "{app}"; Flags: ignoreversion
; Game data (.wz only; the .nx files are for the NX client and are not shipped)
Source: "{#ClientSrc}\*.wz"; DestDir: "{app}"; Flags: ignoreversion
; VC++ runtime, extracted only when it is missing or older than the bundled one
Source: "redist\vc_redist.x86.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: VCRedistNeeded

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#ClientExe}"; WorkingDir: "{app}"
Name: "{group}\Client settings (config.ini)"; Filename: "{app}\config.ini"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#ClientExe}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{tmp}\vc_redist.x86.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "Installing Microsoft Visual C++ runtime..."; Verb: "runas"; Flags: shellexec waituntilterminated; Check: VCRedistNeeded
; MapleStory.exe's manifest requires administrator rights, so start it through the shell (UAC prompt)
Filename: "{app}\{#ClientExe}"; WorkingDir: "{app}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: shellexec nowait postinstall skipifsilent

[Code]
var
  ServerPage: TInputQueryWizardPage;

function VCRedistNeeded: Boolean;
var
  Installed, Major, Minor, Bld: Cardinal;
  Key: String;
begin
  Key := 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x86';
  Result := True;
  if RegQueryDWordValue(HKLM32, Key, 'Installed', Installed) and (Installed = 1) and
     RegQueryDWordValue(HKLM32, Key, 'Major', Major) and
     RegQueryDWordValue(HKLM32, Key, 'Minor', Minor) and
     RegQueryDWordValue(HKLM32, Key, 'Bld', Bld) then
  begin
    if Major <> {#VCMajor} then
      Result := Major < {#VCMajor}
    else if Minor <> {#VCMinor} then
      Result := Minor < {#VCMinor}
    else
      Result := Bld < {#VCBld};
  end;
end;

function IsValidIPv4(const S: String): Boolean;
var
  Rest, Part: String;
  P, I, Count, N: Integer;
begin
  Result := False;
  Rest := S + '.';
  Count := 0;
  while Rest <> '' do
  begin
    P := Pos('.', Rest);
    Part := Copy(Rest, 1, P - 1);
    Delete(Rest, 1, P);
    if (Length(Part) = 0) or (Length(Part) > 3) then Exit;
    for I := 1 to Length(Part) do
      if (Part[I] < '0') or (Part[I] > '9') then Exit;
    N := StrToInt(Part);
    if N > 255 then Exit;
    Count := Count + 1;
  end;
  Result := (Count = 4);
end;

procedure InitializeWizard;
var
  Default: String;
begin
  ServerPage := CreateInputQueryPage(wpSelectDir,
    'Server address',
    'Which RafaelMS server should the client connect to?',
    'Enter the server''s IPv4 address. If you are not sure, keep the pre-filled value. ' +
    'You can change it later in config.ini (ServerIP_Address).');
  ServerPage.Add('Server IP address:', False);

  { Priority: /SERVER= command line, then the value from a previous install, then the default }
  Default := ExpandConstant('{param:SERVER|}');
  if Default = '' then
    Default := GetPreviousData('ServerIP', '{#DefaultServer}');
  { 1.2.x/1.3.x allowed an address list ("a, b"); the original Ezorsia takes one IP }
  if Pos(',', Default) > 0 then
    Default := Trim(Copy(Default, 1, Pos(',', Default) - 1));
  ServerPage.Values[0] := Default;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = ServerPage.ID then
  begin
    ServerPage.Values[0] := Trim(ServerPage.Values[0]);
    if not IsValidIPv4(ServerPage.Values[0]) then
    begin
      MsgBox('Please enter a valid IPv4 address, for example 203.0.113.10.', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

procedure RegisterPreviousData(PreviousDataKey: Integer);
begin
  SetPreviousData(PreviousDataKey, 'ServerIP', ServerPage.Values[0]);
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
            'Server address:' + NewLine + Space + ServerPage.Values[0];
  if MemoTasksInfo <> '' then
    Result := Result + NewLine + NewLine + MemoTasksInfo;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Ini: String;
begin
  if CurStep = ssPostInstall then
  begin
    Ini := ExpandConstant('{app}\config.ini');
    if not SetIniString('general', 'ServerIP_Address', ServerPage.Values[0], Ini) then
      MsgBox('Could not write the server address to ' + Ini + '.' + #13#10 +
             'Set ServerIP_Address manually in that file.', mbError, MB_OK);
    { Undo the 1.2.x/1.3.x display settings: back to the original Ezorsia 1280x720 window }
    if GetIniString('general', 'width', '', Ini) = 'auto' then
    begin
      SetIniString('general', 'width', '1280', Ini);
      SetIniString('general', 'height', '720', Ini);
    end;
    SetIniString('general', 'WindowedMode', 'true', Ini);
    DeleteIniEntry('general', 'Borderless', Ini);
  end;
end;
