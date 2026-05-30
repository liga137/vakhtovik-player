// VPN plugin for sing-box on Windows — минимальная версия
#define FLUTTER_PLUGIN_IMPL
#include "vpn_plugin.h"
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <string>
#include <fstream>

namespace {

std::string W2U(const std::wstring& w) {
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
    if (n <= 0) return {};
    std::string r(n - 1, 0);
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &r[0], n, nullptr, nullptr);
    return r;
}

std::wstring U2W(const std::string& s) {
    if (s.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
    if (n <= 0) return {};
    std::wstring r(n - 1, 0);
    MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &r[0], n);
    return r;
}

std::wstring ExeDir() {
    wchar_t p[MAX_PATH];
    GetModuleFileNameW(nullptr, p, MAX_PATH);
    std::wstring f(p);
    auto pos = f.find_last_of(L"\\/");
    return pos != std::wstring::npos ? f.substr(0, pos) : f;
}

std::wstring CfgDir() {
    wchar_t b[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", b, MAX_PATH);
    if (n > 0 && n < MAX_PATH) return std::wstring(b) + L"\\VakhtovikPlayer";
    n = GetEnvironmentVariableW(L"APPDATA", b, MAX_PATH);
    if (n > 0 && n < MAX_PATH) return std::wstring(b) + L"\\VakhtovikPlayer";
    return ExeDir();
}

class VpnPlugin : public flutter::Plugin {
public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* r) {
        auto ch = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
            r->messenger(), "vakhtovik/singbox", &flutter::StandardMethodCodec::GetInstance());
        auto p = std::make_unique<VpnPlugin>();
        ch->SetMethodCallHandler([wp = p.get()](const auto& call, auto result) {
            wp->Handle(call, std::move(result));
        });
        r->AddPlugin(std::move(p));
    }

    ~VpnPlugin() { Disconnect(); }

    void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
                std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "isAvailable") {
            auto exe = ExeDir() + L"\\sing-box.exe";
            DWORD a = GetFileAttributesW(exe.c_str());
            result->Success(flutter::EncodableValue(a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY)));
        } else if (call.method_name() == "connect") {
            const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
            std::string cfg;
            if (args) {
                auto it = args->find(flutter::EncodableValue("config"));
                if (it != args->end()) cfg = std::get<std::string>(it->second);
            }
            if (cfg.empty()) { result->Error("E", "empty config"); return; }
            result->Success(flutter::EncodableValue(Connect(cfg)));
        } else if (call.method_name() == "disconnect") {
            Disconnect();
            result->Success(flutter::EncodableValue(true));
        } else {
            result->NotImplemented();
        }
    }

private:
    bool Connect(const std::string& cfgJson) {
        Disconnect();

        auto dir = CfgDir();
        CreateDirectoryW(dir.c_str(), nullptr);
        auto path = W2U(dir) + "\\vpn_config.json";
        std::ofstream f(path, std::ios::trunc);
        if (!f) return false;
        f << cfgJson;
        f.close();

        auto exe = ExeDir() + L"\\sing-box.exe";
        auto cmdLine = L"\"" + exe + L"\" run -c \"" + U2W(path) + L"\"";

        STARTUPINFOW si = { sizeof(STARTUPINFOW) };
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION pi = {};

        if (!CreateProcessW(exe.c_str(), &cmdLine[0], nullptr, nullptr, FALSE,
                CREATE_NO_WINDOW, nullptr, ExeDir().c_str(), &si, &pi)) {
            return false;
        }

        hProc_ = pi.hProcess;
        pid_ = pi.dwProcessId;
        CloseHandle(pi.hThread);
        return true;
    }

    void Disconnect() {
        if (hProc_) {
            TerminateProcess(hProc_, 0);
            WaitForSingleObject(hProc_, 2000);
            CloseHandle(hProc_);
            hProc_ = nullptr;
            pid_ = 0;
        }
        DeleteFileW((CfgDir() + L"\\vpn_config.json").c_str());
    }

    HANDLE hProc_ = nullptr;
    DWORD pid_ = 0;
};

}

void VpnPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef r) {
    VpnPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(r));
}
