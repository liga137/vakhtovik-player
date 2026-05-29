// VPN plugin for sing-box on Windows.
// Loads libbox.dll and manages Hysteria2/TUN connections.

#include "vpn_plugin.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <memory>
#include <string>
#include <thread>
#include <atomic>

namespace {

// ── libbox.dll function signatures (from sing-box experimental/libbox) ──
// These match the Go → C-shared exports:
//   Go: func StartInstance(configJson string, workingDir string) *C.char
//   Go: func StopInstance()

typedef char* (*StartFunc)(const char* configJson, const char* workingDir);
typedef void (*StopFunc)();

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

  ~VpnPlugin() override { Shutdown(); }

  void HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result
  ) {
    if (call.method_name() == "isAvailable") {
      // libbox.dll must be next to the executable
      HMODULE test = LoadLibraryW(L"libbox.dll");
      if (test) {
        FreeLibrary(test);
        result->Success(flutter::EncodableValue(true));
      } else {
        result->Success(flutter::EncodableValue(false));
      }
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
      if (ok) {
        result->Success(flutter::EncodableValue(true));
      } else {
        result->Error("START_FAILED", "Could not start VPN. Is libbox.dll present?");
      }
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
  bool StartVpn(const std::string& config) {
    Shutdown();

    hLibbox_ = LoadLibraryW(L"libbox.dll");
    if (!hLibbox_) {
      return false;
    }

    auto startFn = reinterpret_cast<StartFunc>(
      GetProcAddress(hLibbox_, "StartInstance")
    );

    if (!startFn) {
      FreeLibrary(hLibbox_);
      hLibbox_ = nullptr;
      return false;
    }

    running_.store(true);

    // Copy config for thread safety
    std::string cfg = config;

    vpnThread_ = std::thread([this, startFn, cfg]() {
      // sing-box StartInstance blocks until stopped
      char* errMsg = startFn(cfg.c_str(), nullptr);

      running_.store(false);

      if (errMsg) {
        // Report error back to Dart via method channel
        auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar_->messenger(), "vakhtovik/singbox",
          &flutter::StandardMethodCodec::GetInstance()
        );
        flutter::EncodableMap args;
        args[flutter::EncodableValue("error")] = flutter::EncodableValue(std::string(errMsg));
        channel->InvokeMethod("onStatusChanged",
          std::make_unique<flutter::EncodableValue>("Error")
        );
      }
    });

    return true;
  }

  void StopVpn() {
    if (running_.load() && hLibbox_) {
      auto stopFn = reinterpret_cast<StopFunc>(
        GetProcAddress(hLibbox_, "StopInstance")
      );
      if (stopFn) {
        stopFn();
      }
    }
    Shutdown();
  }

  void Shutdown() {
    running_.store(false);
    if (vpnThread_.joinable()) {
      // Don't block forever — sing-box may not respond
      auto nativeHandle = vpnThread_.native_handle();
      vpnThread_.detach();
      // Give it 2 seconds, then force
      if (nativeHandle) {
        WaitForSingleObject(nativeHandle, 2000);
        TerminateThread(nativeHandle, 0);
      }
    }
    if (hLibbox_) {
      FreeLibrary(hLibbox_);
      hLibbox_ = nullptr;
    }
  }

  flutter::PluginRegistrarWindows* registrar_;
  HMODULE hLibbox_ = nullptr;
  std::thread vpnThread_;
  std::atomic<bool> running_{false};
};

} // namespace

void VpnPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  VpnPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarManager::GetInstance()
      ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar)
  );
}
