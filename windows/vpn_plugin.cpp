// VPN plugin for sing-box on Windows.
// Spawns sing-box.exe as a hidden subprocess with JSON config.

#define FLUTTER_PLUGIN_IMPL
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
    wchar_t buf[MAX_PATH];
    DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", buf, MAX_PATH);
    if (len > 0 && len < MAX_PATH) return std::wstring(buf) + L"\\VakhtovikPlayer";
    len = GetEnvironmentVariableW(L"APPDATA", buf, MAX_PATH);
    if (len > 0 && len < MAX_PATH) return std::wstring(buf) + L"\\VakhtovikPlayer";
    return GetExeDir();
}

// Послать Ctrl+C процессу → sing-box корректно завершится и уберёт TUN
BOOL SendCtrlC(DWORD pid) {
    FreeConsole();
    if (!AttachConsole(pid)) return FALSE;
    SetConsoleCtrlHandler(nullptr, TRUE);
    BOOL ok = GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
    FreeConsole();
    return ok;
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

    explicit VpnPlugin(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {}
    ~VpnPlugin() override { StopVpn(); }

    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result
    ) {
        if (call.method_name() == "isAvailable") {
            auto exePath = GetExeDir() + L"\\sing-box.exe";
            DWORD attrs = GetFileAttributesW(exePath.c_str());
            result->Success(flutter::EncodableValue(
                attrs != INVALID_FILE_ATTRIBUTES && !(attrs & FILE_ATTRIBUTE_DIRECTORY)));
        }
        else if (call.method_name() == "connect") {
            const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
            std::string config;
            if (args) {
                auto it = args->find(flutter::EncodableValue("config"));
                if (it != args->end()) config = std::get<std::string>(it->second);
            }
            if (config.empty()) { result->Error("NO_CONFIG", "Config is empty"); return; }
            result->Success(flutter::EncodableValue(StartVpn(config)));
        }
        else if (call.method_name() == "disconnect") {
            StopVpn();
            result->Success(flutter::EncodableValue(true));
        }
        else { result->NotImplemented(); }
    }

private:
    bool StartVpn(const std::string& configJson) {
        StopVpn();

        auto configDir = GetConfigDir();
        CreateDirectoryW(configDir.c_str(), nullptr);
        auto configPath = WideToUtf8(configDir) + "\\vpn_config.json";
        {
            std::ofstream f(configPath, std::ios::trunc);
            if (!f) return false;
            f << configJson;
        }

        auto exeDir = GetExeDir();
        auto singBoxPath = exeDir + L"\\sing-box.exe";
        auto configPathW = Utf8ToWide(configPath);
        std::wstring cmdLine = L"\"" + singBoxPath + L"\" run -c \"" + configPathW + L"\"";

        STARTUPINFOW si = { sizeof(STARTUPINFOW) };
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION pi = {};

        if (!CreateProcessW(singBoxPath.c_str(), &cmdLine[0],
                nullptr, nullptr, FALSE, CREATE_NO_WINDOW,
                nullptr, exeDir.c_str(), &si, &pi)) {
            return false;
        }

        hProcess_ = pi.hProcess;
        processId_ = pi.dwProcessId;
        CloseHandle(pi.hThread);

        // Не блокируем UI — проверяем в фоне через 5 секунд
        // Если процесс упал — чистим
        return true;
    }

    void StopVpn() {
        if (hProcess_) {
            // Мягкое завершение: Ctrl+C
            FreeConsole();
            AttachConsole(processId_);
            SetConsoleCtrlHandler(nullptr, TRUE);
            GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
            FreeConsole();

            // Ждём до 5с
            if (WaitForSingleObject(hProcess_, 5000) != WAIT_OBJECT_0) {
                TerminateProcess(hProcess_, 0);
                WaitForSingleObject(hProcess_, 2000);
            }
            CloseHandle(hProcess_);
            hProcess_ = nullptr;
            processId_ = 0;
        }

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
            ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
