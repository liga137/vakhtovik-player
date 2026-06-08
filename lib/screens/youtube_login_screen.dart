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
          userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
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
    
    if (urlString.startsWith('https://www.youtube.com') && 
        !urlString.contains('ServiceLogin') && 
        !urlString.contains('signin')) {
          
      _cookieTimer?.cancel();
      _cookieTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
        if (!mounted) {
          timer.cancel();
          return;
        }

        final cookieManager = CookieManager.instance();
        final cookies1 = await cookieManager.getCookies(url: WebUri('https://www.youtube.com'));
        final cookies2 = await cookieManager.getCookies(url: WebUri('https://youtube.com'));
        
        final Map<String, String> uniqueCookies = {};
        for (var c in cookies1) uniqueCookies[c.name] = c.value.toString();
        for (var c in cookies2) uniqueCookies[c.name] = c.value.toString();
        
        String cookieString = uniqueCookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
        
        bool hasSapisid = uniqueCookies.containsKey('SAPISID');
        bool hasLoginInfo = uniqueCookies.containsKey('LOGIN_INFO');
        
        // YouTube API считает запрос анонимным без LOGIN_INFO, даже если есть SAPISID
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
