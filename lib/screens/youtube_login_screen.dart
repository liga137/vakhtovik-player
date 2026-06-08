import 'dart:async';
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
  Timer? _cookieTimer;

  @override
  void dispose() {
    _cookieTimer?.cancel();
    super.dispose();
  }

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
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.orange),
                ),
              ),
            ),
        ],
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(
          url: WebUri(
              'https://accounts.google.com/ServiceLogin?service=youtube&continue=https://www.youtube.com/'),
        ),
        initialSettings: InAppWebViewSettings(
          userAgent:
              "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
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

    // После успешного входа Google редиректит на youtube.com
    if (urlString.startsWith('https://www.youtube.com') &&
        !urlString.contains('ServiceLogin') &&
        !urlString.contains('signin')) {
      _cookieTimer?.cancel();
      // Ждём появления LOGIN_INFO (может прийти с задержкой после SAPISID)
      _cookieTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }

        final cookieManager = CookieManager.instance();
        final cookies = await cookieManager
            .getCookies(url: WebUri('https://www.youtube.com'));

        String cookieString = '';
        bool hasSapisid = false;
        bool hasLoginInfo = false;

        for (var cookie in cookies) {
          // НЕ декодируем значение! LOGIN_INFO содержит спецсимволы
          // которые ломаются при URL-декодировании
          cookieString += '${cookie.name}=${cookie.value}; ';
          if (cookie.name == 'SAPISID') {
            hasSapisid = true;
          }
          if (cookie.name == 'LOGIN_INFO') {
            hasLoginInfo = true;
          }
        }

        // YouTube API требует обе куки для персонализированной ленты
        if (hasSapisid && hasLoginInfo) {
          timer.cancel();
          await ApiService.saveYoutubeAuth(cookieString, 'Мой YouTube');
          if (mounted) {
            Navigator.of(context).pop(true);
          }
        }
      });
    }
  }
}
