import 'package:flutter/material.dart';
import 'package:video_player_win/video_player_win.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io' show Platform;
import 'screens/browser_screen.dart';
import 'services/gost_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    WindowsVideoPlayer.registerWith();
    await windowManager.ensureInitialized();
    windowManager.setMinimumSize(const Size(400, 300));
    // GOST — не блокирует запуск, ошибки молча
    GostService.start();
  }
  runApp(const VakhtovikApp());
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
