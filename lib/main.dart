import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io' show Platform, exit;
import 'screens/browser_screen.dart';
import 'services/api_service.dart';
import 'services/vpn_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  await ApiService.initLocalState();
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    windowManager.setMinimumSize(const Size(400, 300));
  }
  runApp(const VakhtovikApp());
}

class VakhtovikApp extends StatefulWidget {
  const VakhtovikApp({super.key});

  @override
  State<VakhtovikApp> createState() => _VakhtovikAppState();
}

class _VakhtovikAppState extends State<VakhtovikApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowClose() async {
    // Останавливаем VPN перед закрытием, чтобы не было зомби
    try {
      await VpnService.instance.disconnect().timeout(const Duration(seconds: 2));
    } catch (_) {}
    
    await windowManager.destroy();
    exit(0); // Принудительно завершаем процесс, чтобы избежать зависаний от media_kit/http
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Плеер Вахтовика',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: Colors.orange,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const BrowserScreen(),
    );
  }
}
