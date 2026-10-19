; Inno Setup script for KaTrain Neo on Windows. Built in CI:
;   ISCC /DAppVersion=0.1.0 /DSourceDir=<flutter release folder with katrain-neo.exe added> /O<out> katrain_neo.iss

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\app\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{6B4C9E1A-3F27-4C55-9A0E-5D2B7F1C8E40}
AppName=KaTrain Neo
AppVersion={#AppVersion}
AppPublisher=KaTrain Neo contributors
AppPublisherURL=https://github.com/playeriv65/katrain-neo
DefaultDirName={autopf}\KaTrain Neo
DefaultGroupName=KaTrain Neo
UninstallDisplayIcon={app}\katrain_neo.exe
OutputBaseFilename=KaTrainNeo-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequiredOverridesAllowed=dialog
ChangesEnvironment=yes
LicenseFile=..\..\LICENSE

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "addtopath"; Description: "Add the katrain-neo command to PATH (for AI agents and scripts)"; GroupDescription: "Command line:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\KaTrain Neo"; Filename: "{app}\katrain_neo.exe"
Name: "{group}\{cm:UninstallProgram,KaTrain Neo}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\KaTrain Neo"; Filename: "{app}\katrain_neo.exe"; Tasks: desktopicon

[Registry]
Root: HKA; Subkey: "{code:EnvironmentKey}"; ValueType: expandsz; ValueName: "Path"; ValueData: "{olddata};{app}"; \
  Tasks: addtopath; Check: NotInPath(ExpandConstant('{app}'))

[Run]
Filename: "{app}\katrain_neo.exe"; Description: "{cm:LaunchProgram,KaTrain Neo}"; Flags: nowait postinstall skipifsilent

[Code]
function EnvironmentKey(Param: String): String;
begin
  if IsAdminInstallMode then
    Result := 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'
  else
    Result := 'Environment';
end;

function NotInPath(Dir: String): Boolean;
var
  Path: String;
begin
  if not RegQueryStringValue(HKA, EnvironmentKey(''), 'Path', Path) then
    Result := True
  else
    Result := Pos(';' + Uppercase(Dir) + ';', ';' + Uppercase(Path) + ';') = 0;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Path, Dir: String;
  P: Integer;
begin
  if CurUninstallStep <> usPostUninstall then
    exit;
  if not RegQueryStringValue(HKA, EnvironmentKey(''), 'Path', Path) then
    exit;
  Dir := ';' + ExpandConstant('{app}');
  P := Pos(Uppercase(Dir), Uppercase(Path));
  if P > 0 then
  begin
    Delete(Path, P, Length(Dir));
    RegWriteExpandStringValue(HKA, EnvironmentKey(''), 'Path', Path);
  end;
end;
