#ifndef MyAppVersion
  #define MyAppVersion "dev"
#endif

#ifndef MyAppExeSource
  #error MyAppExeSource is required
#endif

#ifndef MyAppExeName
  #define MyAppExeName "ghostinthewsl.exe"
#endif

#ifndef MyOutputDir
  #error MyOutputDir is required
#endif

#ifndef MyOutputBaseFilename
  #error MyOutputBaseFilename is required
#endif

#ifndef MyArchitecturesAllowed
  #define MyArchitecturesAllowed "x64os"
#endif

#ifndef MyArchitecturesInstallIn64BitMode
  #define MyArchitecturesInstallIn64BitMode "x64os"
#endif

[Setup]
AppId={{A353E819-702F-4642-8E6F-41A7D65D0F9D}
AppName=GhostInTheWSL
AppVersion={#MyAppVersion}
AppPublisher=Codavo
AppPublisherURL=https://github.com/Codavo/ghostinthewsl
DefaultDirName={localappdata}\Programs\GhostInTheWSL
DefaultGroupName=GhostInTheWSL
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed={#MyArchitecturesAllowed}
ArchitecturesInstallIn64BitMode={#MyArchitecturesInstallIn64BitMode}
OutputDir={#MyOutputDir}
OutputBaseFilename={#MyOutputBaseFilename}
SetupIconFile=..\dist\windows\ghostty.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#MyAppExeSource}"; DestDir: "{app}"; DestName: "{#MyAppExeName}"; Flags: ignoreversion

[Icons]
Name: "{group}\GhostInTheWSL"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\Uninstall GhostInTheWSL"; Filename: "{uninstallexe}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "Launch GhostInTheWSL"; Flags: nowait postinstall skipifsilent
