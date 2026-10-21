; The Windows installer for BaoCode Lab, compiled by
; tool/build_windows_lab.dart.
;
; BaoCode Lab is the same app under another name, installed beside a
; BaoCode already there and run at the same time: its own executable
; (baocodelab.exe), its own folder, its own entry in Settings → Apps. The
; two read and write the same User\settings.json, argv.json, keymaps\ and
; secrets\ (lib/platform/app_identity.dart); what each keeps for itself —
; sessions, caches, checkpoints, logs — is apart (%APPDATA%\baocodelab for
; this one).
;
; It is compiled with three /D defines, all required:
;   BundleDir  the Release bundle to pack (the folder holding baocodelab.exe)
;   AppVersion the version pubspec.yaml carries, as it writes it (1.0.0+1)
;   OutDir     where to write the installer (build/installers)
;
; Output: BaoCodeLab-<version>-setup.exe
;
; What it does not do, unlike tool/baocode.iss: no baocode: link, no
; Explorer menu, no browser host, no `code` command — each is one per
; machine (or per user) under keys the installed app already has, and this
; build is not the one to own them.

#ifndef BundleDir
  #error BundleDir is not defined: pass /DBundleDir=<release bundle folder>
#endif
#ifndef AppVersion
  #error AppVersion is not defined: pass /DAppVersion=<version from pubspec.yaml>
#endif
#ifndef OutDir
  #error OutDir is not defined: pass /DOutDir=<folder for the installer>
#endif

; The part of the version Windows records, without the build number pubspec
; adds after "+".
#define VersionNumber Copy(AppVersion, 1, Pos("+", AppVersion) - 1)
#if Pos("+", AppVersion) == 0
  #undef VersionNumber
  #define VersionNumber AppVersion
#endif

[Setup]
; Its own identity: an upgrade of this one goes over this one, and never
; over the installed BaoCode (whose AppId is another).
AppId={{8f0a7d1e-4b25-4e0a-9c1d-3a6f2c5b7e94}
AppName=BaoCode Lab
AppVersion={#VersionNumber}
AppPublisher=BaoCode
AppVerName=BaoCode Lab {#VersionNumber}
DefaultDirName={autopf}\BaoCode Lab
DefaultGroupName=BaoCode Lab
UninstallDisplayName=BaoCode Lab
UninstallDisplayIcon={app}\baocodelab.exe
OutputBaseFilename=BaoCodeLab-{#VersionNumber}-setup
OutputDir={#OutDir}
VersionInfoVersion={#VersionNumber}.0
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
DisableProgramGroupPage=yes
; The installed app and this one are told apart by their executables
; (windows/runner/app_identity.cpp): a running BaoCode Lab is closed for
; the install, a running BaoCode is not.
CloseApplications=force
CloseApplicationsFilter=baocodelab.exe
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; The whole bundle, as tool/build_windows_lab.dart left it: baocodelab.exe,
; the engine and plugin DLLs, data\ (the AOT app.so and flutter_assets),
; and remote\ and openssh\ taken from the installed app's, for remote
; projects.
Source: "{#BundleDir}\*"; DestDir: "{app}"; \
  Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\BaoCode Lab"; Filename: "{app}\baocodelab.exe"
Name: "{group}\{cm:UninstallProgram,BaoCode Lab}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\BaoCode Lab"; Filename: "{app}\baocodelab.exe"; \
  Tasks: desktopicon

[Run]
Filename: "{app}\baocodelab.exe"; Description: "{cm:LaunchProgram,BaoCode Lab}"; \
  Flags: nowait postinstall skipifsilent
