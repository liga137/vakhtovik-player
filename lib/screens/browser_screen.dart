import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/api_service.dart';
import 'player_screen.dart';

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  late final WebViewController _controller;
  final TextEditingController _urlController = TextEditingController(text: 'https://seasonvar.ru');
  
  bool _isLoading = false;
  String _currentVideoUrl = '';

  @override
  void initState() {
    super.initState();
    _initWebView();
  }

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'VakhtovikChannel',
        onMessageReceived: (JavaScriptMessage message) {
          // JS прислал ссылку на видео!
          final videoUrl = message.message;
          if (videoUrl.isNotEmpty) {
            _onVideoIntercepted(videoUrl);
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
              _urlController.text = url;
            });
          },
          onPageFinished: (String url) {
            setState(() { _isLoading = false; });
            _injectVideoInterceptor();
          },
        ),
      )
      ..loadRequest(Uri.parse(_urlController.text));
  }

  void _injectVideoInterceptor() {
    // Внедряем скрипт, который ищет теги <video> и перехватывает клик по ним, 
    // отправляя URL в Flutter через VakhtovikChannel
    final jsCode = '''
      (function() {
        // Проверяем каждую секунду появление <video>
        setInterval(() => {
          const videoTags = document.querySelectorAll('video');
          videoTags.forEach(v => {
            if (!v.dataset.vakhtovikBound) {
              v.dataset.vakhtovikBound = "true";
              
              // Перехватываем воспроизведение
              v.addEventListener('play', (e) => {
                e.preventDefault();
                v.pause(); // Останавливаем родной плеер
                if (v.src) {
                  VakhtovikChannel.postMessage(v.src);
                } else {
                  const source = v.querySelector('source');
                  if (source && source.src) {
                    VakhtovikChannel.postMessage(source.src);
                  }
                }
              });
              
              // Добавляем красную рамку для наглядности на этапе дебага
              v.style.border = "5px solid red";
            }
          });
        }, 1000);
      })();
    ''';
    _controller.runJavaScript(jsCode);
  }

  void _onVideoIntercepted(String videoUrl) {
    if (_currentVideoUrl == videoUrl) return; // Защита от спама
    _currentVideoUrl = videoUrl;
    
    // Показываем всплывающее меню (Bottom Sheet)
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        String selectedQ = '240p';
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '✨ Видеопоток перехвачен!',
                    style: TextStyle(color: Colors.orange, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text('Выберите качество сжатия:', style: TextStyle(color: Colors.grey)),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: ['144p', '240p', '360p', '480p'].map((q) {
                      final isActive = selectedQ == q;
                      return GestureDetector(
                        onTap: () => setSheetState(() => selectedQ = q),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
                          decoration: BoxDecoration(
                            color: isActive ? Colors.orange.withOpacity(0.2) : const Color(0xFF2A2A2A),
                            border: Border.all(color: isActive ? Colors.orange : Colors.grey.shade800, width: 2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(q, style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _currentVideoUrl = ''; // Сброс
                          },
                          style: OutlinedButton.styleFrom(foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 15)),
                          child: const Text('Отмена'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _startMagic(videoUrl, selectedQ);
                          },
                          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(vertical: 15)),
                          child: const Text('Сжать и смотреть ▶', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
        );
      }
    ).whenComplete(() => _currentVideoUrl = '');
  }

  void _startMagic(String url, String quality) async {
    // Показываем лоадер
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.orange)),
    );

    try {
      final result = await ApiService.transcode(url: url, quality: quality);
      final hlsUrl = ApiService.hlsUrl(result.playlistUrl);
      
      if (!mounted) return;
      Navigator.pop(context); // закрываем лоадер
      
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            hlsUrl: hlsUrl,
            sessionId: result.sessionId,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // закрываем лоадер
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ошибка: $e'), backgroundColor: Colors.red));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        titleSpacing: 0,
        title: Container(
          height: 40,
          margin: const EdgeInsets.only(right: 15),
          padding: const EdgeInsets.symmetric(horizontal: 15),
          decoration: BoxDecoration(
            color: const Color(0xFF333333),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              const Icon(Icons.lock, size: 16, color: Colors.grey),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _urlController,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isDense: true,
                  ),
                  onSubmitted: (val) {
                    var finalUrl = val;
                    if (!finalUrl.startsWith('http')) finalUrl = 'https://$finalUrl';
                    _controller.loadRequest(Uri.parse(finalUrl));
                  },
                ),
              ),
            ],
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.home, color: Colors.white),
          onPressed: () => _controller.loadRequest(Uri.parse('https://seasonvar.ru')),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.person, color: Colors.orange),
            onPressed: () {},
          )
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_isLoading)
            const LinearProgressIndicator(color: Colors.orange, backgroundColor: Colors.transparent),
        ],
      ),
    );
  }
}
