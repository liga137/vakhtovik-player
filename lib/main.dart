import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'screens/browser_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Инициализируем C++ движок плеера (только для нативных платформ)
  if (!kIsWeb) {
    MediaKit.ensureInitialized();
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
