#ifndef AppSource
  #error AppSource is required
#endif
[Setup]
AppId={{82573EF4-10A9-4512-A8B3-9C9DFE768B00}
AppName=Murmur
AppVersion=0.1.0
AppPublisher=Murmur
DefaultDirName={localappdata}\Programs\Murmur
DefaultGroupName=Murmur
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputDir={#Output}
OutputBaseFilename=Murmur-Windows-0.1.0-x64-Setup
SetupIconFile=..\Murmur.Windows\Assets\murmur.ico
UninstallDisplayIcon={app}\Murmur.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
AppMutex=Local\Murmur.Windows
[Files]
Source: "{#AppSource}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#Redist}"; DestDir: "{tmp}"; Flags: deleteafterinstall; Check: NeedsRuntime
[Icons]
Name: "{group}\Murmur"; Filename: "{app}\Murmur.exe"
[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueName: "Murmur"; Flags: uninsdeletevalue
[Run]
Filename: "{tmp}\VC_redist.x64.exe"; Parameters: "/install /passive /norestart"; StatusMsg: "Installing Microsoft's speech runtime prerequisites…"; Flags: waituntilterminated; Check: NeedsRuntime
Filename: "{app}\Murmur.exe"; Description: "Open Murmur"; Flags: nowait postinstall skipifsilent
[Code]
function NeedsRuntime: Boolean;
var Installed: Cardinal;
begin
  Result := not RegQueryDWordValue(HKLM64, 'SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64', 'Installed', Installed);
  if not Result then Result := Installed <> 1;
end;
