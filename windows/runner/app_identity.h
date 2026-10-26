#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

#include <string>

// Which build of the app this copy is: MoonCode's own, or MoonCode Lab, built
// beside it under another name (tool/build_windows_lab.dart).
//
// The two run at the same time, for the same user, so everything Windows
// tells them apart by has to differ: the single-instance mutex, the window
// it hands the paths it was started with to, the registry key it keeps its
// window frames and log folder in, and the folder the shell finds its logs
// in. What they share is what the user asked them to (the data folder's
// settings and keys: lib/platform/app_identity.dart, DataDirectory.shared).
//
// Told by the executable's own name, which the Lab build renames after
// building (baocodelab.exe): `flutter run` and the app's own build keep
// baocode.exe, and are the app's own.
namespace app_identity {

// Whether this is the build kept beside an installed MoonCode.
bool IsLab();

// The app's name, as Windows shows it: "MoonCode" or "MoonCode Lab".
const wchar_t* Name();

// The key under HKEY_CURRENT_USER the app keeps its own settings in, under
// Software\: "MoonCode" or "MoonCode Lab".
const wchar_t* SettingsKey();

// The window property by which a copy of this build finds the one already
// running, to hand it the paths it was started with.
const wchar_t* OpenRequestProperty();

// The name of the mutex the copy that runs for the user holds.
const wchar_t* SingleInstanceMutex();

// The folder under the user's temporary folder the login window keeps
// what it downloads in.
const wchar_t* LoginFolder();

// The folder under %APPDATA% the app keeps its data in: "baocode" or
// "baocodelab".
const wchar_t* DataFolder();

}  // namespace app_identity

#endif  // RUNNER_APP_IDENTITY_H_
