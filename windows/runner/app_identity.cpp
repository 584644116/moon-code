#include "app_identity.h"

#include <windows.h>

#include <algorithm>
#include <cwctype>

namespace app_identity {
namespace {

// The executable's own name, without its folder or extension, in lower
// case (as the file system's comparison is on Windows).
const std::wstring& ExecutableName() {
  static const std::wstring name = [] {
    wchar_t path[MAX_PATH];
    const DWORD length =
        ::GetModuleFileNameW(nullptr, path, static_cast<DWORD>(MAX_PATH));
    if (length == 0 || length >= MAX_PATH) {
      return std::wstring();
    }
    std::wstring file(path, length);
    const size_t slash = file.find_last_of(L"\\/");
    if (slash != std::wstring::npos) file = file.substr(slash + 1);
    const size_t dot = file.find_last_of(L'.');
    if (dot != std::wstring::npos) file = file.substr(0, dot);
    std::transform(file.begin(), file.end(), file.begin(),
                   [](wchar_t c) { return static_cast<wchar_t>(std::towlower(c)); });
    return file;
  }();
  return name;
}

}  // namespace

bool IsLab() {
  // The Lab build's executable is renamed after it is built (see
  // tool/build_windows_lab.dart), as the NSIS-style name it runs under: it
  // is the only name that differs from the app's own.
  return ExecutableName() == L"baocodelab";
}

const wchar_t* Name() { return IsLab() ? L"MoonCode Lab" : L"MoonCode"; }

const wchar_t* SettingsKey() {
  return IsLab() ? L"Software\\MoonCode Lab" : L"Software\\MoonCode";
}

const wchar_t* OpenRequestProperty() {
  return IsLab() ? L"MoonCodeLab.OpenRequests" : L"MoonCode.OpenRequests";
}

const wchar_t* SingleInstanceMutex() {
  return IsLab() ? L"Local\\MoonCodeLab.SingleInstance"
                 : L"Local\\MoonCode.SingleInstance";
}

const wchar_t* LoginFolder() {
  return IsLab() ? L"MoonCodeLab-Login" : L"MoonCode-Login";
}

const wchar_t* DataFolder() {
  return IsLab() ? L"mooncodelab" : L"mooncode";
}

}  // namespace app_identity
