import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/api_service.dart';

class YouTubeLoginScreen extends StatefulWidget {
  const YouTubeLoginScreen({super.key});

  @override
  State<YouTubeLoginScreen> createState() => _YouTubeLoginScreenState();
}

class _YouTubeLoginScreenState extends State<YouTubeLoginScreen> {
  late InAppWebViewController _webViewController;
  bool _isLoading = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Вход в YouTube (Google)'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_isLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(right: 16.0),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.orange),
                ),
              ),
            ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri('https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/'),
        ),
        initialSettings: InAppWebViewSettings(
          userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/115.0.0.0 Safari/537.36",
          clearCache: false,
          javaScriptEnabled: true,
          domStorageEnabled: true,
        ),
        onWebViewCreated: (controller) {
          _webViewController = controller;
        },
        onLoadStart: (controller, url) {
          setState(() {
            _isLoading = true;
          });
          _checkUrl(url);
        },
        onLoadStop: (controller, url) async {
          setState(() {
            _isLoading = false;
          });
          await _checkUrl(url);
        },
      ),
    );
  }

  Future<void> _checkUrl(WebUri? url) async {
    if (url == null) return;
    final urlString = url.toString();
    // Если после входа нас редиректит на сам YouTube
    if (urlString.startsWith('https://www.youtube.com') && 
        !urlString.contains('ServiceLogin') && 
        !urlString.contains('signin')) {
          
      // Извлекаем куки
      final cookieManager = CookieManager.instance();
      final cookies = await cookieManager.getCookies(url: WebUri('https://www.youtube.com'));
      
      String cookieString = '';
      bool hasSapisid = false;
      
      for (var cookie in cookies) {
        final String rawValue = Uri.decodeComponent(cookie.value.toString());
        cookieString += '${cookie.name}=$rawValue; ';
        if (cookie.name == 'SAPISID') {
          hasSapisid = true;
        }
      }
      
      if (hasSapisid) {
        // Успешно вошли!
        // Сохраняем куки как токен (у нас в API Service токен это просто строка)
        await ApiService.saveYoutubeAuth(cookieString, 'Мой YouTube');
        if (mounted) {
          Navigator.of(context).pop(true); // Возвращаемся с успехом
        }
      }
    }
  }
}
