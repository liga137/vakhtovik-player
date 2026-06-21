import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../services/api_service.dart';
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
      if (mounted)
        setState(() => _showLoginButton = !ApiService.isYouTubeLoggedIn);
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
              child:
                  const Text('Войти', style: TextStyle(color: Colors.orange)),
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
              // JS: прячем плеер, пауза, пропускаем рекламу
              _webCtrl?.evaluateJavascript(source: '''
(function(){
var s=document.createElement('style');
s.textContent='video{visibility:hidden!important}#movie_player{opacity:0!important}';
document.head.appendChild(s);

var _done={};
setInterval(function(){
  var m=location.href.match(/[?&]v=([a-zA-Z0-9_-]{11})/);
  if(!m||_done[m[1]])return;
  // Пропускаем рекламу
  var isAd=document.querySelector('.ad-showing,.ytp-ad-player-overlay,.ytp-ad-skip-button');
  if(isAd){
    var skipBtn=document.querySelector('.ytp-ad-skip-button,.ytp-skip-ad-button');
    if(skipBtn){skipBtn.click();}
    return;
  }
  _done[m[1]]=1;
  var v=document.querySelector('video');
  if(v){v.pause();v.muted=true;v.src='';try{v.load()}catch(e){}}
  var btns=document.querySelectorAll('.ytp-play-button');
  for(var i=0;i<btns.length;i++){
    var a=btns[i].getAttribute('aria-label')||'';
    if(a.toLowerCase().indexOf('pause')>=0){btns[i].click();break;}
  }
  window.flutter_inappwebview.callHandler('onYouTubeVideo',m[1]);
},200);
})();
''');
            },
          ),
          if (_loading)
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LinearProgressIndicator(color: Colors.orange),
            ),
        ],
      ),
    );
  }

  void _playVideo(String url) async {
    // Показываем индикатор загрузки
    setState(() => _loading = true);
    String? pendingSessionId;
    try {
      final result = await ApiService.transcode(url: url, quality: '240p');
      pendingSessionId = result.sessionId;
      if (!mounted) {
        ApiService.stopSession(result.sessionId).catchError((_) {});
        return;
      }
      setState(() => _loading = false);
      pendingSessionId = null;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            hlsUrl: ApiService.hlsUrl(result.playlistUrl),
            sessionId: result.sessionId,
            sourceUrl: url,
            quality: '240p',
            duration: result.duration,
          ),
        ),
      );
    } catch (e) {
      if (pendingSessionId != null) {
        ApiService.stopSession(pendingSessionId).catchError((_) {});
      }
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
