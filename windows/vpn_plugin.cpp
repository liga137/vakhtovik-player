// VPN plugin for sing-box on Windows.
// Spawns sing-box.exe as a hidden subprocess with JSON config.

#include "vpn_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <tlhelp32.h>
#include <memory>
#include <string>
#include <fstream>
#include <cstdio>

namespace {

std::string WideToUtf8(const std::wstring& wstr) {
    if (wstr.empty()) return {};
    int len = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return {};
    std::string result(len - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), -1, &result[0], len, nullptr, nullptr);
    return result;
}

std::wstring Utf8ToWide(const std::string& str) {
    if (str.empty()) return {};
    int len = MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, nullptr, 0);
    if (len <= 0) return {};
    std::wstring result(len - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, str.c_str(), -1, &result[0], len);
    return result;
}

std::wstring GetExeDir() {
    wchar_t path[MAX_PATH];
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring full(path);
    auto pos = full.find_last_of(L"\\/");
    if (pos != std::wstring::npos) full = full.substr(0, pos);
    return full;
}

std::wstring GetConfigDir() {
    wchar_t localAppData[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, localAppData))) {
        return std::wstring(localAppData) + L"\\VakhtovikPlayer";
    }
    return GetExeDir();
}

void KillProcessTree(DWORD pid) {
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return;

    PROCESSENTRY32W pe = { sizeof(PROCESSENTRY32W) };
    if (Process32FirstW(snapshot, &pe)) {
        do {
            if (pe.th32ParentProcessID == pid) {
                KillProcessTree(pe.th32ProcessID);
            }
        } while (Process32NextW(snapshot, &pe));
    }
    CloseHandle(snapshot);

    HANDLE proc = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    if (proc) {
        TerminateProcess(proc, 0);
        CloseHandle(proc);
    }
}

class VpnPlugin : public flutter::Plugin {
public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
        auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            registrar->messenger(), "vakhtovik/singbox",
            &flutter::StandardMethodCodec::GetInstance()
        );

        auto plugin = std::make_unique<VpnPlugin>(registrar);
        channel->SetMethodCallHandler(
            [plugin_weak = plugin.get()](const auto& call, auto result) {
                plugin_weak->HandleMethodCall(call, std::move(result));
            }
        );

        registrar->AddPlugin(std::move(plugin));
    }

    explicit VpnPlugin(flutter::PluginRegistrarWindows* registrar)
        : registrar_(registrar) {}

    ~VpnPlugin() override { StopVpn(); }

    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result
    ) {
        if (call.method_name() == "isAvailable") {
            // Проверяем, есть ли sing-box.exe рядом с приложением
            auto exePath = GetExeDir() + L"\\sing-box.exe";
            DWORD attrs = GetFileAttributesW(exePath.c_str());
            bool exists = (attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY));
            result->Success(flutter::EncodableValue(exists));
        }
        else if (call.method_name() == "connect") {
            const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
            std::string config;
            if (args) {
                auto it = args->find(flutter::EncodableValue("config"));
                if (it != args->end()) {
                    config = std::get<std::string>(it->second);
                }
            }
            if (config.empty()) {
                result->Error("NO_CONFIG", "Config is empty");
                return;
            }
            bool ok = StartVpn(config);
            result->Success(flutter::EncodableValue(ok));
        }
        else if (call.method_name() == "disconnect") {
            StopVpn();
            result->Success(flutter::EncodableValue(true));
        }
        else {
            result->NotImplemented();
        }
    }

private:
    bool StartVpn(const std::string& configJson) {
        StopVpn();

        // 1. Пишем конфиг во временный файл
        auto configDir = GetConfigDir();
        CreateDirectoryW(configDir.c_str(), nullptr);
        auto configPath = WideToUtf8(configDir) + "\\vpn_config.json";
        {
            std::ofstream f(configPath, std::ios::trunc);
            if (!f) return false;
            f << configJson;
            f.close();
        }

        // 2. Запускаем sing-box.exe run -c <config>
        auto exeDir = GetExeDir();
        auto singBoxPath = exeDir + L"\\sing-box.exe";
        auto configPathW = Utf8ToWide(configPath);

        std::wstring cmdLine = L"\"" + singBoxPath + L"\" run -c \"" + configPathW + L"\"";

        STARTUPINFOW si = { sizeof(STARTUPINFOW) };
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;

        PROCESS_INFORMATION pi = {};

        BOOL created = CreateProcessW(
            singBoxPath.c_str(),  // lpApplicationName
            &cmdLine[0],          // lpCommandLine (writable buffer)
            nullptr,              // lpProcessAttributes
            nullptr,              // lpThreadAttributes
            FALSE,                // bInheritHandles
            CREATE_NO_WINDOW,     // dwCreationFlags
            nullptr,              // lpEnvironment
            exeDir.c_str(),       // lpCurrentDirectory
            &si,                  // lpStartupInfo
            &pi                   // lpProcessInformation
        );

        if (!created) {
            return false;
        }

        // 3. Сохраняем хендл процесса
        hProcess_ = pi.hProcess;
        processId_ = pi.dwProcessId;
        CloseHandle(pi.hThread);

        // Ждём немного и проверяем, не упал ли сразу
        DWORD waitResult = WaitForSingleObject(hProcess_, 3000);
        if (waitResult == WAIT_OBJECT_0) {
            // Процесс завершился — ошибка в конфиге
            DWORD exitCode = 0;
            GetExitCodeProcess(hProcess_, &exitCode);
            CloseHandle(hProcess_);
            hProcess_ = nullptr;
            processId_ = 0;
            DeleteFileW(configPathW.c_str());
            return false;
        }

        return true;
    }

    void StopVpn() {
        if (processId_ != 0) {
            KillProcessTree(processId_);
            if (hProcess_) {
                WaitForSingleObject(hProcess_, 5000);
                CloseHandle(hProcess_);
                hProcess_ = nullptr;
            }
            processId_ = 0;
        }

        // Чистим конфиг
        auto configPath = GetConfigDir() + L"\\vpn_config.json";
        DeleteFileW(configPath.c_str());
    }

    flutter::PluginRegistrarWindows* registrar_;
    HANDLE hProcess_ = nullptr;
    DWORD processId_ = 0;
};

} // namespace

void VpnPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
    VpnPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar)
    );
}
