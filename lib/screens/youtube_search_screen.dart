import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../models/youtube_video.dart';
import '../services/api_service.dart';
import '../services/log_service.dart';
import 'player_screen.dart';
import 'youtube_login_screen.dart';

class YouTubeSearchScreen extends StatefulWidget {
  const YouTubeSearchScreen({super.key});

  @override
  State<YouTubeSearchScreen> createState() => _YouTubeSearchScreenState();
}

class _YouTubeSearchScreenState extends State<YouTubeSearchScreen> {
  InAppWebViewController? _webCtrl;
  bool _loading = true;
  bool _showLoginButton = true;

  @override
  void initState() {
    super.initState();
    ApiService.initLocalState().then((_) {
      if (mounted) setState(() => _showLoginButton = !ApiService.isYouTubeLoggedIn);
    });
  }

  Future<void> _login() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const YouTubeLoginScreen()),
    );
    if (ok == true && mounted) {
      setState(() => _showLoginButton = false);
      _webCtrl?.reload();
    }
  }

  void _logout() {
    ApiService.youtubeLogout();
    setState(() => _showLoginButton = true);
    _webCtrl?.loadUrl(
      urlRequest: URLRequest(url: WebUri('https://www.youtube.com/')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('YouTube'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          if (_showLoginButton)
            TextButton(
              onPressed: _login,
              child: const Text('Войти', style: TextStyle(color: Colors.orange)),
            )
          else
            PopupMenuButton<String>(
              icon: const Icon(Icons.account_circle, color: Colors.white),
              onSelected: (v) {
                if (v == 'logout') _logout();
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'logout',
                  child: Text(
                    ApiService.youtubeUsername ?? 'Аккаунт',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
        ],
      ),
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('https://www.youtube.com/'),
            ),
            initialSettings: InAppWebViewSettings(
              userAgent:
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
              javaScriptEnabled: true,
              domStorageEnabled: true,
            ),
            onWebViewCreated: (c) {
              _webCtrl = c;
              // JS: перехват видео — стопим плеер, шлём videoId в Flutter
              c.addJavaScriptHandler(
                handlerName: 'onYouTubeVideo',
                callback: (args) {
                  final videoId = args.isNotEmpty ? args[0].toString() : '';
                  if (videoId.isNotEmpty) {
                    _playVideo('https://www.youtube.com/watch?v=$videoId');
                  }
                },
              );
            },
            onLoadStart: (_, __) => setState(() => _loading = true),
            onLoadStop: (_, __) {
              setState(() => _loading = false);
              // JS: пауза через клавишу k + остановка video.src
              _webCtrl?.evaluateJavascript(source: '''
(function(){
var _done={};
setInterval(function(){
  var m=location.href.match(/[?&]v=([a-zA-Z0-9_-]{11})/);
  if(!m||_done[m[1]])return;
  _done[m[1]]=1;
  // Способ 1: эмуляция нажатия k (YouTube hotkey паузы)
  var v=document.querySelector('video');
  if(v){
    v.dispatchEvent(new KeyboardEvent('keydown',{key:'k',code:'KeyK',keyCode:75,bubbles:true}));
    setTimeout(function(){v.pause();v.src='';v.load();},200);
  }
  // Способ 2: клик по кнопке паузы
  var btns=document.querySelectorAll('.ytp-play-button');
  for(var i=0;i<btns.length;i++){
    var b=btns[i];
    var ar=(b.getAttribute('aria-label')||'').toLowerCase();
    var ti=(b.getAttribute('title')||'').toLowerCase();
    if(ar.indexOf('pause')>=0||ti.indexOf('pause')>=0){b.click();break;}
  }
  window.flutter_inappwebview.callHandler('onYouTubeVideo',m[1]);
},300);
})();
''');
            },
          ),
          if (_loading)
            const Positioned(
              top: 0, left: 0, right: 0,
              child: LinearProgressIndicator(color: Colors.orange),
            ),
        ],
      ),
    );
  }

  void _playVideo(String url) async {
    // Показываем индикатор загрузки
    setState(() => _loading = true);
    try {
      final result = await ApiService.transcode(url: url, quality: '240p');
      if (!mounted) return;
      setState(() => _loading = false);
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            hlsUrl: result.playlistUrl,
            sessionId: result.sessionId,
            sourceUrl: url,
            quality: '240p',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
