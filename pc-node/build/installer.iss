; Instalador da Fala para Windows (Inno Setup). Sem admin: instala no perfil da pessoa e abre com o Windows.
#define Version GetEnv("FALA_VERSION")
[Setup]
AppId={{6F1A2C4E-FA1A-4B6E-9C3D-0F5A1A7E2B10}
AppName=Fala
AppVersion={#Version}
AppPublisher=Fala
DefaultDirName={localappdata}\Programs\Fala
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
OutputDir=out
OutputBaseFilename=FalaSetup
SetupIconFile=..\fala.ico
UninstallDisplayIcon={app}\Fala.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=force

[Languages]
Name: "pt"; MessagesFile: "compiler:Languages\Portuguese.isl"

[Files]
Source: "dist\Fala\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{userprograms}\Fala"; Filename: "{app}\Fala.exe"
Name: "{userdesktop}\Fala"; Filename: "{app}\Fala.exe"

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Fala"; ValueData: """{app}\Fala.exe"" --hidden"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\Fala.exe"; Description: "Abrir a Fala"; Flags: nowait postinstall

[UninstallRun]
Filename: "taskkill"; Parameters: "/f /im Fala.exe"; Flags: runhidden; RunOnceId: "KillFala"
