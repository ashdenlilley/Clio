; Per-user installer for the unsigned Clio Windows build. Built by scripts/windows-release.ps1.
#ifndef AppVersion
  #error AppVersion is required (/DAppVersion=1.2.3)
#endif
#ifndef FileVersion
  #define FileVersion AppVersion + ".0"
#endif
#ifndef SourceDir
  #error SourceDir is required (/DSourceDir=...)
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Fixed GUID: identifies the app for upgrade and uninstall. Never change it.
AppId={{6F1D7C0E-3B52-4C0B-9D9E-5A2C41F0A7B3}
AppName=Clio
AppVersion={#AppVersion}
VersionInfoVersion={#FileVersion}
AppPublisher=Clio
DefaultDirName={autopf}\Clio
DefaultGroupName=Clio
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
OutputDir={#OutputDir}
OutputBaseFilename=Clio-{#AppVersion}-win-x64-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\Clio.exe
CloseApplications=yes
RestartApplications=no
WizardStyle=modern

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\Clio"; Filename: "{app}\Clio.exe"

[Run]
Filename: "{app}\Clio.exe"; Description: "Launch Clio"; Flags: nowait postinstall skipifsilent

[Code]
// Remove what the app's opt-in Markdown association writes (HKCU, see FileAssociation.cs).
// User data in %LOCALAPPDATA%\Clio (settings, recovery copies, search index) and the user's
// documents are never touched.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    RegDeleteValue(HKCU, 'Software\Classes\.md\OpenWithProgids', 'Clio.Markdown');
    RegDeleteValue(HKCU, 'Software\Classes\.markdown\OpenWithProgids', 'Clio.Markdown');
    RegDeleteKeyIncludingSubkeys(HKCU, 'Software\Classes\Clio.Markdown');
  end;
end;
