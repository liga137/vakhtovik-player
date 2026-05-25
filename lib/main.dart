import 'package:flutter/material.dart';
import 'package:video_player_win/video_player_win.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io' show Platform;
import 'screens/browser_screen.dart';
import 'services/api_service.dart';
import 'services/hysteria_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ApiService.initLocalState();
  if (Platform.isWindows) {
    WindowsVideoPlayer.registerWith();
    await windowManager.ensureInitialized();
    windowManager.setMinimumSize(const Size(400, 300));
    windowManager.addListener(_HysteriaCleanup());
  }
  runApp(const VakhtovikApp());
}

class _HysteriaCleanup extends WindowListener {
  @override
  void onWindowClose() {
    HysteriaService.stop();
  }
}

class VakhtovikApp extends StatelessWidget {
  const VakhtovikApp({super.key});

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
