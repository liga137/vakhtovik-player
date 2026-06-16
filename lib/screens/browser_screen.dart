import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File, Platform;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_manager/window_manager.dart';
import '../services/api_service.dart';
import '../services/log_service.dart';
import '../services/update_service.dart';
import '../services/vpn_service.dart';
import '../services/youtube_hover.dart';
import '../models/preset.dart';
import 'iptv_screen.dart';
import 'youtube_search_screen.dart';
import 'player_screen.dart';

enum EconomyLevel { none, economy, superEconomy, text }

class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  InAppWebViewController? webViewController;
  WebViewEnvironment? _webViewEnvironment;
  bool _webViewReady = !Platform.isWindows;
  int _webViewInstance = 0;
  String? _webViewRestoreUrl;
  String url = "https://seasonvar.ru/";
  String _currentRealUrl = "https://seasonvar.ru/";
  final urlController = TextEditingController(text: "https://seasonvar.ru/");

  bool _showInterceptor = false;
  bool _showHome = true;
  bool _liteMode = false;
  EconomyLevel _economyLevel = EconomyLevel.economy;
  bool _pageLoading = false;
  String _interceptedUrl = "";
  String _currentReferer = "";
  List<Preset> _presets = [];
  String _selectedQuality = "240p";
  bool _isLoading = false;

  final bool _showPlayer = false;
  bool _waitingForNextEpisode = false; // флаг: ждём перехвата новой серии
  bool _onYouTube = false; // флаг: мы на странице YouTube
  bool _compressMode = false; // Режим «Сжатое» — кнопки на всех видео YouTube
  bool _interceptedAlready = false; // защита от повторного перехвата одного URL
  VpnState _vpnState = VpnState.disconnected;
  StreamSubscription<VpnState>? _vpnSub;
  bool _scanningSeasonvar = false;
  List<Map<String, String>> _seasonvarEpisodes = [];
  int _seasonvarIndex = 0;
  List<Map<String, String>> _seasonvarTranslations = [];
  String _seasonvarTranslationId = '';
  List<Map<String, String>> _seasonvarSeasons = [];
  List<Map<String, String>> _filmixEpisodes = [];
  int _filmixIndex = 0;
  List<Map<String, String>> _filmixTranslations = [];
  String _filmixTranslationId = '';
  List<Map<String, String>> _filmixSeasons = [];
  String _filmixSeasonId = '';
  String _lastFilmixMediaUrl = '';
  String _lastAutoMediaUrl = '';
  List<String> _recentLinks = [];
  bool _checkingUpdates = false;

  // -- Retry загрузки страниц при слабом интернете --
  int _webViewRetryCount = 0;
  static const int _webViewMaxRetries = 3;
  String? _lastFailedUrl;

  @override
  void initState() {
    super.initState();
    _loadPresets();
    _loadRecentLinks();
    _initWindowsWebViewEnvironment();
    _vpnSub = VpnService.instance.stateStream.listen((s) {
      if (mounted) setState(() => _vpnState = s);
    });
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted) _checkForUpdates(silent: true);
    });
  }

  Future<void> _initWindowsWebViewEnvironment() async {
    if (!Platform.isWindows) return;
    await _resetWindowsWebViewEnvironment(preservePage: false);
  }

  String _normalizeRestoreUrl(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == 'about:blank') return 'about:blank';
    if (t.startsWith('http://') || t.startsWith('https://')) return t;
    return _currentRealUrl;
  }

  Future<WebViewEnvironment?> _createWindowsEnvironment() async {
    if (!Platform.isWindows) return null;
    final availableVersion = await WebViewEnvironment.getAvailableVersion();
    if (availableVersion == null) return null;

    final localAppData =
        Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
    final baseDir = Directory('$localAppData/VakhtovikPlayer/webview2');
    if (!await baseDir.exists()) {
      await baseDir.create(recursive: true);
    }

    const profileDir = 'direct';
    const browserArgs =
        '--disable-quic --disable-features=UseDnsHttpsSvcb,AsyncDns';

    return WebViewEnvironment.create(
      settings: WebViewEnvironmentSettings(
        userDataFolder: '${baseDir.path}/$profileDir',
        additionalBrowserArguments: browserArgs,
      ),
    );
  }

  Future<void> _safeDisposeEnvironment(WebViewEnvironment? env) async {
    if (env == null) return;
    try {
      await env.dispose();
    } on MissingPluginException {
      // В некоторых сборках flutter_inappwebview для Windows метод dispose
      // у окружения не реализован. Игнорируем, чтобы не ломать WebView2.
    } catch (_) {}
  }

  Future<void> _resetWindowsWebViewEnvironment(
      {required bool preservePage}) async {
    if (!Platform.isWindows) return;
    if (_webViewReady && _webViewEnvironment != null && !preservePage) {
      return;
    }

    String restoreUrl = 'about:blank';
    if (preservePage) {
      try {
        final current = await webViewController?.getUrl();
        if (current != null) {
          restoreUrl = _normalizeRestoreUrl(current.toString());
        } else if (urlController.text.trim().isNotEmpty) {
          restoreUrl = _normalizeRestoreUrl(urlController.text);
        } else {
          restoreUrl = _normalizeRestoreUrl(_currentRealUrl);
        }
      } catch (_) {
        restoreUrl = _normalizeRestoreUrl(_currentRealUrl);
      }
    }

    final oldEnvironment = _webViewEnvironment;

    if (mounted) {
      setState(() {
        _pageLoading = true;
        _webViewReady = false;
      });
    }

    try {
      final environment = await _createWindowsEnvironment();
      if (!mounted) {
        await _safeDisposeEnvironment(environment);
        return;
      }
      await _safeDisposeEnvironment(oldEnvironment);
      setState(() {
        _webViewEnvironment = environment;
        _webViewRestoreUrl = preservePage ? restoreUrl : null;
        _webViewInstance++;
        webViewController = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _webViewEnvironment = oldEnvironment;
        _webViewReady = true;
        _pageLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Ошибка WebView2: $e'),
            duration: const Duration(seconds: 4)),
      );
    }
  }

  Future<void> _loadPresets() async {
    // Жёсткий фолбэк — если сервер не отвечает, качество всё равно будет
    const fallback = [
      Preset(
          id: '480p', label: '480p', width: 854, crf: 43, audioBitrate: '32k'),
      Preset(
          id: '360p', label: '360p', width: 640, crf: 40, audioBitrate: '32k'),
      Preset(
          id: '240p', label: '240p', width: 426, crf: 38, audioBitrate: '32k'),
      Preset(
          id: '144p', label: '144p', width: 256, crf: 34, audioBitrate: '32k'),
    ];
    try {
      final presets =
          await ApiService.getPresets().timeout(const Duration(seconds: 12));
      if (mounted) {
        setState(() {
          _presets = List<Preset>.from(presets.isNotEmpty ? presets : fallback);
          if (_presets.isNotEmpty) _selectedQuality = _presets.first.id;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _presets = List<Preset>.from(fallback);
          _selectedQuality = '240p';
        });
      }
    }
  }

  Future<File> _recentLinksFile() async {
    if (Platform.isWindows) {
      final localAppData =
          Platform.environment['LOCALAPPDATA'] ?? Directory.current.path;
      final appDir = Directory('$localAppData/VakhtovikPlayer');
      if (!await appDir.exists()) await appDir.create(recursive: true);
      return File('${appDir.path}/recent_links.json');
    }
    final appDir = Directory('${Directory.systemTemp.path}/vakhtovik_player');
    if (!await appDir.exists()) await appDir.create(recursive: true);
    return File('${appDir.path}/recent_links.json');
  }

  Future<void> _loadRecentLinks() async {
    try {
      final file = await _recentLinksFile();
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString()) as List<dynamic>;
      final links = data
          .map((e) => e.toString())
          .where((e) => e.startsWith('http://') || e.startsWith('https://'))
          .toList();
      if (mounted) {
        setState(() {
          _recentLinks = links.take(30).toList();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveRecentLinks() async {
    try {
      final file = await _recentLinksFile();
      await file.writeAsString(jsonEncode(_recentLinks.take(30).toList()));
    } catch (_) {}
  }

  void _rememberUrl(String rawUrl) {
    final t = rawUrl.trim();
    if (t.isEmpty || t == 'about:blank') return;
    if (!t.startsWith('http://') && !t.startsWith('https://')) return;
    if (_recentLinks.isNotEmpty && _recentLinks.first == t) return;
    setState(() {
      _recentLinks.removeWhere((x) => x == t);
      _recentLinks.insert(0, t);
      if (_recentLinks.length > 30) {
        _recentLinks = _recentLinks.take(30).toList();
      }
    });
    _saveRecentLinks();
  }

  void _clearRecentLinks() {
    setState(() => _recentLinks = []);
    _saveRecentLinks();
  }

  Future<void> _openExternalUrl(String url) async {
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  Future<void> _checkForUpdates({bool silent = false}) async {
    if (_checkingUpdates) return;
    setState(() => _checkingUpdates = true);
    try {
      final info = await UpdateService.checkLatest();
      if (!mounted) return;
      if (!info.hasUpdate) {
        if (!silent) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Обновлений нет (${info.currentVersion})')),
          );
        }
        return;
      }

      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Доступно обновление'),
          content: Text(
            'Текущая версия: ${info.currentVersion}\n'
            'Новая версия: ${info.latestVersion}\n\n'
            'Открыть страницу релиза?',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Позже')),
            if (info.windowsAssetUrl.isNotEmpty)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openExternalUrl(info.windowsAssetUrl);
                },
                child: const Text('Windows'),
              ),
            if (info.androidAssetUrl.isNotEmpty)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _openExternalUrl(info.androidAssetUrl);
                },
                child: const Text('Android APK'),
              ),
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                _openExternalUrl(info.htmlUrl);
              },
              child: const Text('Релиз'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!silent && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Не удалось проверить обновления: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdates = false);
    }
  }

  @override
  void dispose() {
    _vpnSub?.cancel();
    unawaited(_safeDisposeEnvironment(_webViewEnvironment));
    super.dispose();
  }

  // ── VPN (sing-box) ────────────────────────────────────────

  String _vpnTooltip() {
    switch (_vpnState) {
      case VpnState.connected: return 'VPN подключён';
      case VpnState.connecting: return 'VPN подключается...';
      case VpnState.disconnecting: return 'VPN отключается...';
      case VpnState.error: return 'Ошибка VPN: ${VpnService.instance.lastError}';
      case VpnState.disconnected: return 'VPN отключён';
    }
  }

  Future<void> _toggleVpn() async {
    if (_vpnState == VpnState.connecting || _vpnState == VpnState.disconnecting) return;

    if (_vpnState == VpnState.connected) {
      await VpnService.instance.disconnect();
      return;
    }

    // Загружаем конфиг и подключаемся
    final config = await VpnService.loadConfig();
    if (!mounted) return;

    // Если дефолтный конфиг (не настроен) — показываем диалог
    if (config.contains('YOUR_SERVER') || config.contains('YOUR_PASSWORD')) {
      final result = await _showVpnConfigDialog(config);
      if (result != null && mounted) {
        await VpnService.saveConfig(result);
        await VpnService.instance.connect(result);
        if (mounted && VpnService.instance.lastError.isNotEmpty) {
          _snack(VpnService.instance.lastError);
        }
      }
      return;
    }

    await VpnService.instance.connect(config);
    if (mounted && VpnService.instance.lastError.isNotEmpty) {
      _snack(VpnService.instance.lastError);
    }
  }

  Future<String?> _showVpnConfigDialog(String currentConfig) async {
    final ctrl = TextEditingController(text: currentConfig);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Конфиг sing-box'),
        content: SizedBox(
          width: 400,
          height: 300,
          child: TextField(
            controller: ctrl,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            decoration: const InputDecoration(
              hintText: '{\n  "outbounds": [...]\n}',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Подключить'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    return result;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // Скрипт для авто-переключения серии — НЕ закрывает плеер, ждёт новый перехват
  void _playNextEpisode() {
    if (webViewController == null) return;

    // Правильный режим Seasonvar: следующая серия берётся из собранного списка прямых ссылок
    if (_seasonvarEpisodes.isNotEmpty &&
        _seasonvarIndex + 1 < _seasonvarEpisodes.length) {
      _seasonvarIndex++;
      final ep = _seasonvarEpisodes[_seasonvarIndex];
      _interceptedUrl = ep['url'] ?? '';
      _currentReferer = urlController.text;
      _interceptedAlready = false;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text('Серия ${_seasonvarIndex + 1}: ${ep['title'] ?? ''}'),
            duration: const Duration(seconds: 2)),
      );
      _startMagic();
      return;
    }

    if (_filmixEpisodes.isNotEmpty) {
      final nextIndex = _nextFilmixEpisodeGlobalIndex();
      if (nextIndex >= 0) {
        _playFilmixEpisode(nextIndex);
        return;
      }
    }

    // Ставим флаг: следующие перехваченные URL обрабатываем автоматически
    _waitingForNextEpisode = true;

    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Переключаю серию...'), duration: Duration(seconds: 1)));

    // Инжектим клик по кнопке «Следующая серия»
    // Перед кликом читаем индекс текущей серии (записан трекером при загрузке страницы)
    webViewController!.evaluateJavascript(source: """
      (function() {
        var idx = (typeof window.__vakh_idx !== 'undefined') ? window.__vakh_idx : -1;
        var items = document.querySelectorAll('#htmlPlayer_playlist > *');
        
        // Если трекер знает индекс — кликаем следующий
        if (idx >= 0 && idx + 1 < items.length) {
          window.__vakh_idx = idx + 1;
          items[idx + 1].click();
          return 'tracker-next:' + (idx+1);
        }
        
        // Fallback: ищем активный элемент по жёлтой точке (span с background)
        for (var i = 0; i < items.length; i++) {
          var dot = items[i].querySelector('span[style*="background"], i[style*="background"], .dot, .active, [class*="active"]');
          var isCurrent = dot !== null || (items[i].className && (items[i].className.includes('active') || items[i].className.includes('current')));
          if (isCurrent && i + 1 < items.length) {
            window.__vakh_idx = i + 1;
            items[i + 1].click();
            return 'dot-next:' + (i+1);
          }
        }
        
        // ===== Резерв: кнопки по селектору =====
        var sel = document.querySelector('.pgs-player-next, .pgs-next-btn, .pgs_next, .player-next, .next-episode, [title*="След"], [title*="след"], .next-link, #next, .pnext, .plnext, [data-action="next"]');
        if (sel) { sel.click(); return 'button-click'; }
        
        // ===== Filmix =====
        var fx = document.querySelector('.icon-next, .next-btn, .next-video, .vnext');
        if (fx) { fx.click(); return 'filmix-click'; }
        
        // ===== Универсальный поиск по тексту =====
        var all = document.querySelectorAll('a, button, span, div');
        for (var i = 0; i < all.length; i++) {
          if (all[i].offsetParent === null) continue;
          var t = (all[i].textContent || '').toLowerCase();
          if ((t.includes('следующая') || t.includes('след.') || t.includes('next')) && t.length < 30) {
            all[i].click();
            return 'text-click';
          }
        }
        return 'not-found:idx=' + idx + ',items=' + items.length;
      })();
    """);

    // Таймаут: если за 15 секунд новая серия не перехватилась — закрываем плеер
    Future.delayed(const Duration(seconds: 15), () {
      if (_waitingForNextEpisode && mounted) {
        _waitingForNextEpisode = false;
        _stopPlayer();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Не удалось переключить серию'),
            duration: Duration(seconds: 2)));
      }
    });
  }

  void _startMagic() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final result = await ApiService.transcode(
          url: _interceptedUrl,
          quality: _selectedQuality,
          referer: _currentReferer);
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      _muteWebView();

      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
          hlsUrl: ApiService.hlsUrl(result.playlistUrl),
          sessionId: result.sessionId,
          sourceUrl: _interceptedUrl,
          quality: _selectedQuality,
          referer: _currentReferer,
          duration: result.duration,
        ),
      ));

      _unmuteWebView();

      // Seasonvar: сбор списка серий после просмотра
      final isSeasonvar = _currentReferer.contains('seasonvar') ||
          _interceptedUrl.contains('seasonvar');
      if (isSeasonvar && _seasonvarEpisodes.isEmpty && !_scanningSeasonvar) {
        _scanSeasonvarPlaylist(silent: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Ошибка: $e'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Повторить',
            onPressed: () => _startMagic(),
          ),
      ));
    }
  }

  void _muteWebView() {
    webViewController?.evaluateJavascript(source: """
      (function(){
        var vids = document.querySelectorAll('video, audio');
        for (var i = 0; i < vids.length; i++) {
          vids[i].muted = true;
          vids[i].pause();
        }
      })();
    """);
  }

  void _stopPlayer() {
    _unmuteWebView();
  }

  void _unmuteWebView() {
    webViewController?.evaluateJavascript(source: """
      (function(){
        var vids = document.querySelectorAll('video, audio');
        for (var i = 0; i < vids.length; i++) {
          vids[i].muted = false;
        }
      })();
    """);
  }

  // Сжатие YouTube: показывает шторку выбора качества (как обычный перехват)
  void _compressYouTube() {
    final ytUrl = urlController.text;
    if (!(ytUrl.contains('youtube.com/watch') ||
        ytUrl.contains('youtube.com/shorts/'))) return;

    _openCompressedUrl(ytUrl, referer: 'https://www.youtube.com/');
  }

  void _playSeasonvarEpisode(int index) {
    if (index < 0 || index >= _seasonvarEpisodes.length) return;
    _seasonvarIndex = index;
    final ep = _seasonvarEpisodes[index];
    final epUrl = ep['url'] ?? '';
    if (epUrl.isEmpty) return;
    _interceptedUrl = epUrl;
    _currentReferer = urlController.text;
    _interceptedAlready = false;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
          content: Text('Запускаю серию ${index + 1}'),
          duration: const Duration(seconds: 1)),
    );
    _startMagic();
  }

  String _jsString(String value) {
    return value
        .replaceAll('\\', '\\\\')
        .replaceAll("'", r"\'")
        .replaceAll('\n', ' ');
  }

  bool _looksLikeMediaUrl(String rawUrl) {
    final u = rawUrl.trim().toLowerCase();
    if (u.isEmpty) return false;
    if (u.startsWith('blob:')) return false;
    if (u.contains('trailer') ||
        u.contains('preview') ||
        u.contains('poster') ||
        u.contains('thumb') ||
        u.contains('banner') ||
        u.contains('ad.mp4') ||
        u.contains('promo')) {
      return false;
    }
    if (u.contains('.mp4') ||
        u.contains('.m3u8') ||
        u.contains('.mkv') ||
        u.contains('.webm') ||
        u.contains('.mpd') ||
        u.contains('/hls/') ||
        u.contains('master.m3u8') ||
        u.contains('playlist.m3u8') ||
        u.contains('manifest') ||
        u.contains('/stream/') ||
        u.contains('/vod/') ||
        u.contains('/video/')) {
      return true;
    }
    return false;
  }

  bool _isFilmixContext(String rawUrl) {
    final u = rawUrl.toLowerCase();
    return u.contains('filmix') ||
        u.contains('kodik') ||
        u.contains('videocdn') ||
        u.contains('werkecdn') ||
        u.contains('cdnsqu');
  }

  Map<String, String>? _filmixHintFromMediaUrl(String mediaUrl) {
    final uri = Uri.tryParse(mediaUrl);
    if (uri == null) return null;
    final parts = uri.pathSegments
        .map(Uri.decodeComponent)
        .where((s) => s.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    final file = parts.last;
    final folder = parts.length > 1 ? parts[parts.length - 2] : '';
    final match = RegExp(r's(\d{1,2})e(\d{1,3})', caseSensitive: false)
            .firstMatch(file) ??
        RegExp(r's(\d{1,2})e(\d{1,3})', caseSensitive: false)
            .firstMatch(folder);
    final season = match != null ? '${int.tryParse(match.group(1)!) ?? 0}' : '';
    final episode =
        match != null ? '${int.tryParse(match.group(2)!) ?? 0}' : '';
    if (season.isEmpty && episode.isEmpty) return null;

    final normalizedFolder = folder
        .replaceAll(RegExp(r'[_\.]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final chunks =
        normalizedFolder.split('-').where((c) => c.trim().isNotEmpty).toList();
    const banned = {
      '1080p',
      '720p',
      '480p',
      '360p',
      '240p',
      '144p',
      '2160p',
      'uhd',
      'hdr',
      'sdr',
      'webrip',
      'webdl',
      'dvdrip',
      'bdrip',
      'x264',
      'h264',
      'h265',
      'hevc',
      'aac',
      'ac3',
      'rus',
      'eng',
      'ukr',
      'usa',
      'multi',
    };
    String translation = '';
    for (final raw in chunks.reversed) {
      final c = raw.trim();
      final low = c.toLowerCase();
      if (c.isEmpty) continue;
      if (banned.contains(low)) continue;
      if (RegExp(r'^\d{2,4}$').hasMatch(low)) continue;
      if (!RegExp(r'[a-zа-я]', caseSensitive: false).hasMatch(c)) continue;
      translation = c;
      break;
    }
    if (translation.isEmpty && chunks.isNotEmpty) {
      translation = chunks.last;
    }

    final title = normalizedFolder.replaceAll('-', ' ').trim();
    return {
      'title': title.isNotEmpty ? title : 'S$season E$episode',
      'season': season == '0' ? '' : season,
      'episode': episode == '0' ? '' : episode,
      'translation': translation,
    };
  }

  void _applyFilmixHintFromMediaUrl(String mediaUrl) {
    final hint = _filmixHintFromMediaUrl(mediaUrl);
    if (hint == null) return;
    final season = (hint['season'] ?? '').trim();
    final episode = (hint['episode'] ?? '').trim();
    final translation = (hint['translation'] ?? '').trim();
    final title = (hint['title'] ?? '').trim();
    if (season.isEmpty && episode.isEmpty) return;
    if (!mounted) return;

    setState(() {
      if (season.isNotEmpty) {
        final hasSeason = _filmixSeasons.any((s) => (s['id'] ?? '') == season);
        if (!hasSeason) {
          _filmixSeasons = [
            ..._filmixSeasons,
            {'id': season, 'name': 'Сезон $season'}
          ];
          _filmixSeasons.sort((a, b) => (int.tryParse(a['id'] ?? '') ?? 0)
              .compareTo(int.tryParse(b['id'] ?? '') ?? 0));
        }
        if (_filmixSeasonId.isEmpty) _filmixSeasonId = season;
      }
      if (translation.isNotEmpty) {
        final hasTranslation =
            _filmixTranslations.any((t) => (t['id'] ?? '') == translation);
        if (!hasTranslation) {
          _filmixTranslations = [
            ..._filmixTranslations,
            {'id': translation, 'name': translation}
          ];
          _filmixTranslations
              .sort((a, b) => (a['name'] ?? '').compareTo(b['name'] ?? ''));
        }
        if (_filmixTranslationId.isEmpty) _filmixTranslationId = translation;
      }

      final existing = _filmixEpisodes.indexWhere((e) =>
          (e['season'] ?? '') == season &&
          (e['episode'] ?? '') == episode &&
          (e['translation'] ?? '') == translation &&
          season.isNotEmpty &&
          episode.isNotEmpty);
      if (existing >= 0) {
        _filmixEpisodes[existing] = {
          ..._filmixEpisodes[existing],
          'title': title.isNotEmpty
              ? title
              : _filmixEpisodes[existing]['title'] ?? ''
        };
        _filmixIndex = existing;
      } else {
        _filmixEpisodes = [
          ..._filmixEpisodes,
          {
            'title': title.isNotEmpty ? title : 'S$season E$episode',
            'season': season,
            'episode': episode,
            'translation': translation
          }
        ];
        _filmixEpisodes.sort((a, b) {
          final sa = int.tryParse(a['season'] ?? '') ?? 0;
          final sb = int.tryParse(b['season'] ?? '') ?? 0;
          if (sa != sb) return sa.compareTo(sb);
          final ea = int.tryParse(a['episode'] ?? '') ?? 0;
          final eb = int.tryParse(b['episode'] ?? '') ?? 0;
          if (ea != eb) return ea.compareTo(eb);
          return (a['translation'] ?? '').compareTo(b['translation'] ?? '');
        });
        final added = _filmixEpisodes.indexWhere((e) =>
            (e['season'] ?? '') == season &&
            (e['episode'] ?? '') == episode &&
            (e['translation'] ?? '') == translation);
        _filmixIndex = added >= 0 ? added : _filmixIndex;
      }
    });
  }

  void _autoStartFromMediaUrl(String mediaUrl, {String? referer}) {
    final clean = mediaUrl.trim();
    if (clean.isEmpty) return;
    final lower = clean.toLowerCase();
    if (!_looksLikeMediaUrl(lower)) return;
    if (lower.contains('googlevideo.com')) return;
    if (_showPlayer || _isLoading) return;
    if (clean == _lastAutoMediaUrl) return;

    // Filmix disabled — skip filmix hint extraction
    // final isFilmixSource =
    //     _isFilmixContext(lower) || _isFilmixContext(_currentRealUrl);
    // if (isFilmixSource) {
    //   _applyFilmixHintFromMediaUrl(clean);
    // }

    final canAutostart =
        _waitingForNextEpisode || (!_showInterceptor && !_interceptedAlready);
    if (!canAutostart) return;

    _lastAutoMediaUrl = clean;
    if (_waitingForNextEpisode) _waitingForNextEpisode = false;
    _interceptedAlready = true;
    _interceptedUrl = clean;
    _currentReferer = (referer ?? urlController.text).trim();
    _selectedQuality = '240p';

    Future.microtask(() {
      if (!mounted) return;
      setState(() => _showHome = false);
      _startMagic();
    });
  }

  bool _sameFilmixEpisode(Map<String, String> a, Map<String, String> b) {
    return (a['season'] ?? '') == (b['season'] ?? '') &&
        (a['episode'] ?? '') == (b['episode'] ?? '') &&
        (a['translation'] ?? '') == (b['translation'] ?? '') &&
        (a['title'] ?? '') == (b['title'] ?? '');
  }

  List<Map<String, String>> _filteredFilmixEpisodes() {
    if (_filmixEpisodes.isEmpty) return const [];
    final filtered = _filmixEpisodes.where((e) {
      final season = (e['season'] ?? '').trim();
      final tr = (e['translation'] ?? '').trim();
      final seasonOk = _filmixSeasonId.isEmpty || _filmixSeasonId == season;
      final trOk = _filmixTranslationId.isEmpty || _filmixTranslationId == tr;
      return seasonOk && trOk;
    }).toList();
    return filtered.isEmpty ? _filmixEpisodes : filtered;
  }

  int _findFilmixGlobalIndexByEpisode(Map<String, String> target) {
    final idx =
        _filmixEpisodes.indexWhere((e) => _sameFilmixEpisode(e, target));
    if (idx >= 0) return idx;
    return _filmixEpisodes.indexWhere((e) =>
        (e['season'] ?? '') == (target['season'] ?? '') &&
        (e['episode'] ?? '') == (target['episode'] ?? ''));
  }

  int _nextFilmixEpisodeGlobalIndex() {
    final filtered = _filteredFilmixEpisodes();
    if (filtered.isEmpty) return -1;

    Map<String, String>? current;
    if (_filmixIndex >= 0 && _filmixIndex < _filmixEpisodes.length) {
      current = _filmixEpisodes[_filmixIndex];
    }

    var filteredIndex = -1;
    final cur = current;
    if (cur != null) {
      filteredIndex = filtered.indexWhere((e) => _sameFilmixEpisode(e, cur));
      if (filteredIndex < 0) {
        filteredIndex = filtered.indexWhere((e) =>
            (e['season'] ?? '') == (cur['season'] ?? '') &&
            (e['episode'] ?? '') == (cur['episode'] ?? ''));
      }
    }

    final nextFiltered = filteredIndex + 1;
    if (nextFiltered < 0 || nextFiltered >= filtered.length) return -1;
    return _findFilmixGlobalIndexByEpisode(filtered[nextFiltered]);
  }

  Future<void> _selectFilmixTranslation(String translationId) async {
    if (translationId.trim().isEmpty || webViewController == null) return;
    // Filmix disabled
    return;
  }

  Future<void> _selectFilmixSeason(String seasonId) async {
    if (seasonId.trim().isEmpty || webViewController == null) return;
    // Filmix disabled — .evaluateJavascript removed
    if (!mounted) return;
    setState(() {
      _filmixSeasonId = seasonId.trim();
      _filmixIndex = 0;
    });
    _scanFilmixEpisodes(silent: true);
  }

  void _playFilmixEpisode(int index) async {
    if (index < 0 || index >= _filmixEpisodes.length) return;
    if (webViewController == null) return;

    final ep = _filmixEpisodes[index];
    final season = ep['season'] ?? '';
    final episode = ep['episode'] ?? '';
    final title = ep['title'] ?? '';
    final translation = ep['translation'] ?? '';

    setState(() => _filmixIndex = index);
    _waitingForNextEpisode = true;
    _interceptedAlready = false;
    _lastFilmixMediaUrl = '';
    _lastAutoMediaUrl = '';

    // Filmix disabled — .evaluateJavascript removed
    final clickResult = await webViewController!.evaluateJavascript(source: """
      (function() {
        var season = '${_jsString(season)}';
        var episode = '${_jsString(episode)}';
        var title = '${_jsString(title)}';
        var translation = '${_jsString(translation)}';
        if (window.__vakhFilmixClickEpisode) {
          return window.__vakhFilmixClickEpisode(season, episode, title, translation);
        }
        return 'helper-missing';
      })();
    """);

    final resultText = (clickResult ?? '').toString();
    if (mounted &&
        (resultText.contains('not-found') ||
            resultText.contains('helper-missing'))) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Filmix: не нашёл кнопку серии в iframe ($resultText)'),
            duration: const Duration(seconds: 3)),
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Filmix: S${season.isNotEmpty ? season : "?"} E${episode.isNotEmpty ? episode : "?"}${translation.isNotEmpty ? " [$translation]" : ""}',
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _scanFilmixEpisodes({bool silent = false}) {
    return; // Отключено
  }

  void _openCompressedUrl(String url, {String? referer}) {
    if (url.trim().isEmpty) return;
    _interceptedUrl = url.trim();
    _currentReferer = referer ?? urlController.text;
    _interceptedAlready = true;
    _muteWebView();
    if (mounted) {
      setState(() {
        _showInterceptor = false;
        _showHome = false;
      });
    }
    _startMagic();
  }

  void _scanSeasonvarPlaylist({bool silent = false}) {
    if (webViewController == null) return;
    if (_scanningSeasonvar) return;
    _scanningSeasonvar = true;
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Сканирую серии Seasonvar...'),
            duration: Duration(seconds: 2)),
      );
    }
    webViewController!.evaluateJavascript(source: r'''
      (async function(){
        const wait = (ms) => new Promise(r => setTimeout(r, ms));
        const txt = (v) => (v || '').replace(/\s+/g, ' ').trim();
        const safeCall = (name, payload) => {
          try {
            if (window.flutter_inappwebview) {
              window.flutter_inappwebview.callHandler(name, payload);
            }
          } catch (_) {}
        };

        const translationNodes = Array.from(document.querySelectorAll('.pgs-trans li, [data-translate], [data-id]'))
          .filter(el => txt(el.textContent).length > 0)
          .slice(0, 20);
        const translations = translationNodes.map((el, idx) => ({
          id: String(el.getAttribute('data-translate') || el.getAttribute('data-id') || ('idx:' + idx)),
          name: txt(el.textContent),
          index: String(idx),
        }));

        const seasonLinks = Array.from(document.querySelectorAll('h2 a, .season-list a, .seasons a, a[href*="season"]'))
          .map(a => ({
            title: txt(a.textContent),
            url: (a.href || '').trim(),
          }))
          .filter(x => x.title && x.url && /сезон|season|сериал/i.test(x.title))
          .slice(0, 40);

        const activeTrNode = document.querySelector('.pgs-trans li.active, .pgs-trans li.current, .pgs-trans li[style*="active"]');
        let activeTrId = '';
        if (activeTrNode) {
          activeTrId = String(activeTrNode.getAttribute('data-translate') || activeTrNode.getAttribute('data-id') || '');
          if (!activeTrId) {
            const idx = translationNodes.indexOf(activeTrNode);
            if (idx >= 0) activeTrId = 'idx:' + idx;
          }
        }

        safeCall('seasonvarMeta', JSON.stringify({
          translations,
          seasons: seasonLinks,
          activeTranslationId: activeTrId,
        }));

        const playlistContainer = document.querySelector('#htmlPlayer_playlist');
        if (!playlistContainer) {
          safeCall('seasonvarPlaylist', JSON.stringify([]));
          return 0;
        }

        const playerContainer = document.querySelector('#oframehtmlPlayer');
        const restoreContainerStyles = playerContainer ? {
          opacity: playerContainer.style.opacity,
          pointerEvents: playerContainer.style.pointerEvents,
        } : null;
        if (playerContainer) {
          playerContainer.style.opacity = '0.02';
          playerContainer.style.pointerEvents = 'none';
        }

        const getPlaylistItems = () =>
          Array.from(document.querySelectorAll('#htmlPlayer_playlist > *, #htmlPlayer_playlist li, #htmlPlayer_playlist a'))
            .filter(el => txt(el.textContent).length > 0);

        const getActiveItem = () =>
          document.querySelector('#htmlPlayer_playlist > .current, #htmlPlayer_playlist > .active, #htmlPlayer_playlist .current, #htmlPlayer_playlist .active');

        const originalActiveItem = getActiveItem();
        const originalActiveIndex = (() => {
          const items = getPlaylistItems();
          const idx = items.indexOf(originalActiveItem);
          return idx >= 0 ? idx : 0;
        })();

        const waitForVideoSrc = (lastSrc, timeoutMs = 25000) => new Promise((resolve) => {
          const started = Date.now();
          let done = false;
          let lastFound = null;

          const pickSrc = () => {
            const video = document.querySelector('video');
            if (!video) return '';
            try { video.muted = true; } catch (_) {}
            return String(video.currentSrc || video.src || '').trim();
          };

          const finish = (value) => {
            if (done) return;
            done = true;
            try { clearInterval(pollTimer); } catch (_) {}
            try { mo.disconnect(); } catch (_) {}
            resolve(value || null);
          };

          const check = () => {
            const src = pickSrc();
            if (!src || src.length < 10 || src.indexOf('undefined') >= 0) return;
            if (!lastSrc || src !== lastSrc) {
              finish(src);
              return;
            }
            lastFound = src;
          };

          const mo = new MutationObserver(check);
          mo.observe(document.body, {
            subtree: true,
            childList: true,
            attributes: true,
            attributeFilter: ['src', 'class'],
          });

          const pollTimer = setInterval(() => {
            check();
            if (Date.now() - started >= timeoutMs) {
              finish(lastFound);
            }
          }, 260);

          check();
        });

        const switchPlaylistItem = async (index, lastSrc) => {
          const items = getPlaylistItems();
          if (index < 0 || index >= items.length) return null;
          try { items[index].click(); } catch (_) {}
          await wait(220);
          return await waitForVideoSrc(lastSrc, 25000);
        };

        const collectOneTranslation = async (translationName) => {
          const items = getPlaylistItems();
          const result = [];
          let last = '';
          for (let i = 0; i < items.length; i++) {
            const src = await switchPlaylistItem(i, last);
            const currentItems = getPlaylistItems();
            const titleNode = currentItems[i] || items[i];
            const title = txt((titleNode && (titleNode.innerText || titleNode.textContent)) || ('Серия ' + (i + 1)));
            if (src) {
              result.push({
                index: String(i),
                title: title,
                translation: translationName,
                url: src,
              });
              last = src;
            }
            await wait(850);
          }
          return result;
        };

        const all = [];
        const translationPlan = translationNodes.length > 0
          ? translationNodes.slice(0, 12).map((node, idx) => ({
              node,
              name: txt(node.textContent) || ('Озвучка ' + (idx + 1)),
            }))
          : [{ node: null, name: 'Стандартная' }];

        try {
          for (let t = 0; t < translationPlan.length; t++) {
            const tr = translationPlan[t];
            if (tr.node) {
              try { tr.node.click(); } catch (_) {}
              await wait(2300);
            } else {
              await wait(500);
            }
            const chunk = await collectOneTranslation(tr.name);
            for (let i = 0; i < chunk.length; i++) all.push(chunk[i]);
          }
        } finally {
          if (activeTrId) {
            let backNode = document.querySelector('.pgs-trans li[data-translate="' + activeTrId + '"], .pgs-trans li[data-id="' + activeTrId + '"]');
            if (!backNode && activeTrId.indexOf('idx:') === 0) {
              const idx = parseInt(activeTrId.split(':')[1] || '-1', 10);
              if (!Number.isNaN(idx) && idx >= 0 && idx < translationNodes.length) {
                backNode = translationNodes[idx];
              }
            }
            if (backNode) {
              try { backNode.click(); } catch (_) {}
              await wait(350);
            }
          }

          const finalItems = getPlaylistItems();
          if (finalItems.length > 0) {
            const backIndex = Math.min(Math.max(0, originalActiveIndex), finalItems.length - 1);
            try { finalItems[backIndex].click(); } catch (_) {}
          } else if (originalActiveItem) {
            try { originalActiveItem.click(); } catch (_) {}
          }

          if (playerContainer && restoreContainerStyles) {
            playerContainer.style.opacity = restoreContainerStyles.opacity;
            playerContainer.style.pointerEvents = restoreContainerStyles.pointerEvents;
          }
        }

        const dedup = [];
        const seen = new Set();
        for (let i = 0; i < all.length; i++) {
          const item = all[i];
          const key = (item.translation || '') + '|' + (item.index || '') + '|' + (item.url || '');
          if (seen.has(key)) continue;
          seen.add(key);
          dedup.push(item);
        }

        safeCall('seasonvarPlaylist', JSON.stringify(dedup));
        return dedup.length;
      })();
    ''');
  }

  bool get _hasEpisodeList =>
      _seasonvarEpisodes.isNotEmpty ||
      _seasonvarTranslations.isNotEmpty ||
      _seasonvarSeasons.isNotEmpty;
      // Filmix disabled — removed from condition

  List<Map<String, String>> get _activeEpisodes {
    if (_seasonvarEpisodes.isNotEmpty) return _seasonvarEpisodes;
    return _filteredFilmixEpisodes();
  }

  int get _activeEpisodeIndex {
    if (_seasonvarEpisodes.isNotEmpty) return _seasonvarIndex;
    final active = _filteredFilmixEpisodes();
    if (active.isEmpty) return 0;
    if (_filmixIndex < 0 || _filmixIndex >= _filmixEpisodes.length) return 0;
    final current = _filmixEpisodes[_filmixIndex];
    final idx = active.indexWhere((e) => _sameFilmixEpisode(e, current));
    if (idx >= 0) return idx;
    final fallback = active.indexWhere((e) =>
        (e['season'] ?? '') == (current['season'] ?? '') &&
        (e['episode'] ?? '') == (current['episode'] ?? ''));
    return fallback >= 0 ? fallback : 0;
  }

  void _playEpisodeFromActiveList(int index) {
    if (_seasonvarEpisodes.isNotEmpty) {
      _playSeasonvarEpisode(index);
      return;
    }
    if (_filmixEpisodes.isNotEmpty) {
      final active = _filteredFilmixEpisodes();
      if (index < 0 || index >= active.length) return;
      final globalIndex = _findFilmixGlobalIndexByEpisode(active[index]);
      if (globalIndex >= 0) _playFilmixEpisode(globalIndex);
    }
  }

  Future<void> _selectSeasonvarTranslation(String translationId,
      {String fallbackIndex = ''}) async {
    if (translationId.isEmpty || webViewController == null) return;
    await webViewController!.evaluateJavascript(source: """
      (function() {
        var id = '${_jsString(translationId)}';
        var fallbackIndex = '${_jsString(fallbackIndex)}';
        var node = document.querySelector('.pgs-trans li[data-translate="' + id + '"], .pgs-trans li[data-id="' + id + '"]');
        if (!node && fallbackIndex) {
          var idx = parseInt(fallbackIndex, 10);
          if (!Number.isNaN(idx)) {
            var nodes = document.querySelectorAll('.pgs-trans li, [data-translate], [data-id]');
            if (idx >= 0 && idx < nodes.length) node = nodes[idx];
          }
        }
        if (!node) return 'not-found';
        node.click();
        return 'clicked';
      })();
    """);
    if (!mounted) return;
    setState(() {
      _seasonvarTranslationId = translationId;
      _seasonvarEpisodes = [];
      _seasonvarIndex = 0;
    });
    await Future.delayed(const Duration(milliseconds: 900));
    _scanSeasonvarPlaylist(silent: true);
  }

  void _openSeasonvarSeason(String seasonUrl) {
    if (seasonUrl.trim().isEmpty) return;
    _loadAddress(seasonUrl.trim());
  }

  void _updateYouTubeState(Uri url) {
    final onYT = url.host.contains('youtube.com');
    if (onYT != _onYouTube) setState(() => _onYouTube = onYT);
  }

  void _toggleYouTubeCompressMode() {
    if (webViewController == null) return;
    final mode = _compressMode;
    webViewController!.evaluateJavascript(
        source: "window.vakhCompressMode(${mode ? "true" : "false"});");
  }

  void _openSite(String siteUrl) {
    setState(() {
      _showHome = false;
      _pageLoading = true;
      _seasonvarEpisodes = [];
      _filmixEpisodes = [];
      _filmixTranslations = [];
      _filmixSeasons = [];
      _seasonvarTranslations = [];
      _seasonvarSeasons = [];
      _seasonvarIndex = 0;
      _filmixIndex = 0;
    });
    _currentRealUrl = siteUrl;
    _rememberUrl(siteUrl);
    final loadUrl = _liteMode ? ApiService.liteUrl(siteUrl) : siteUrl;
    urlController.text = loadUrl;
    webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(loadUrl)));
  }

  String _realUrlFromAddress() {
    final text = urlController.text.trim();
    final parsed = Uri.tryParse(text);
    if (parsed != null &&
        parsed.path == '/lite' &&
        parsed.queryParameters['url'] != null) {
      return parsed.queryParameters['url']!;
    }
    if (text.isEmpty || text == 'about:blank') return _currentRealUrl;
    return text;
  }

  void _loadAddress(String value) {
    var target = value.trim();
    if (target.isEmpty) return;
    if (!Uri.parse(target).hasScheme) target = "https://$target";
    setState(() {
      _showHome = false;
      _pageLoading = true;
      _seasonvarEpisodes = [];
      _filmixEpisodes = [];
      _filmixTranslations = [];
      _filmixSeasons = [];
      _seasonvarTranslations = [];
      _seasonvarSeasons = [];
      _seasonvarIndex = 0;
      _filmixIndex = 0;
    });
    _currentRealUrl = target;
    _rememberUrl(target);
    final loadUrl = _liteMode ? ApiService.liteUrl(target) : target;
    urlController.text = loadUrl;
    webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(loadUrl)));
  }

  String _economyLabel(EconomyLevel level) {
    switch (level) {
      case EconomyLevel.none:
        return 'Обычный';
      case EconomyLevel.economy:
        return '🪶 Эконом';
      case EconomyLevel.superEconomy:
        return '⚡ Супер';
      case EconomyLevel.text:
        return '📄 Текст';
    }
  }

  Future<void> _setEconomyLevel(EconomyLevel level) async {
    final target = _realUrlFromAddress();
    final textMode = level == EconomyLevel.text;
    setState(() {
      _economyLevel = level;
      _liteMode = textMode;
    });
    if (!_showHome && target.isNotEmpty && target != 'about:blank') {
      _currentRealUrl = target;
      final loadUrl = textMode ? ApiService.liteUrl(target) : target;
      urlController.text = loadUrl;
      if (mounted) setState(() => _pageLoading = true);
      webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(loadUrl)));
    }
  }

  Future<void> _showLogDialog() async {
    final log = await LogService.readLog();
    if (!mounted) return;
    showDialog(context: context, builder: (ctx) => AlertDialog(
      title: Row(children: [const Text('Лог ошибок'), const Spacer(),
        Text('${log.split('\n').length} строк', style: const TextStyle(fontSize: 12, color: Colors.grey))]),
      content: SizedBox(width: double.maxFinite, height: 400,
        child: SingleChildScrollView(child: SelectableText(log, style: const TextStyle(fontFamily: 'monospace', fontSize: 11)))),
      actions: [
        TextButton(onPressed: () { LogService.clearLog(); Navigator.pop(ctx); }, child: const Text('Очистить')),
        TextButton(onPressed: () { Navigator.pop(ctx); }, child: const Text('Закрыть')),
    ]));
  }

  Future<void> _showCustomSiteDialog() async {
    final c = TextEditingController(text: 'https://');
    final result = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
              title: const Text('Свой сайт'),
              content: TextField(
                  controller: c,
                  autofocus: true,
                  decoration:
                      const InputDecoration(hintText: 'https://example.com'),
                  onSubmitted: (v) => Navigator.pop(context, v)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, c.text),
                    child: const Text('Открыть'))
              ],
            ));
    c.dispose();
    if (result != null && result.trim().isNotEmpty) _loadAddress(result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Browser UI
          Column(
            children: [
              // Browser Header
              Container(
                padding: const EdgeInsets.only(
                    top: 40, left: 10, right: 10, bottom: 10),
                color: const Color(0xFF1A1A1A),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      tooltip: 'Назад',
                      onPressed: () {
                        webViewController?.goBack();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh, color: Colors.white),
                      tooltip: 'Обновить',
                      onPressed: () => webViewController?.reload(),
                    ),
                    // History button removed — not needed
                    IconButton(
                      icon: const Icon(Icons.home, color: Colors.white),
                      onPressed: () {
                        setState(() => _showHome = true);
                        webViewController?.loadUrl(
                            urlRequest: URLRequest(url: WebUri("about:blank")));
                      },
                    ),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF333333),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: TextField(
                          controller: urlController,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            icon:
                                Icon(Icons.lock, color: Colors.green, size: 16),
                          ),
                          onSubmitted: _loadAddress,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.fullscreen, color: Colors.white),
                      tooltip: 'На весь экран',
                      onPressed: () async {
                        final isFs = await windowManager.isFullScreen();
                        await windowManager.setFullScreen(!isFs);
                      },
                    ),
                    IconButton(
                      icon: _checkingUpdates
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.orange),
                            )
                          : const Icon(Icons.system_update,
                              color: Colors.orange),
                      tooltip: 'Проверить обновления',
                      onPressed: _checkingUpdates
                          ? null
                          : () => _checkForUpdates(silent: false),
                    ),
                    // Debug playlist-scan button removed
                    PopupMenuButton<EconomyLevel>(
                      tooltip: 'Режим экономии',
                      initialValue: _economyLevel,
                      onSelected: _setEconomyLevel,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                            value: EconomyLevel.none, child: Text('Обычный')),
                        PopupMenuItem(
                            value: EconomyLevel.economy,
                            child: Text('🪶 Эконом: режем рекламу/шрифты')),
                        PopupMenuItem(
                            value: EconomyLevel.superEconomy,
                            child: Text('⚡ Супер: ещё без картинок')),
                        PopupMenuItem(
                            value: EconomyLevel.text,
                            child: Text('📄 Текст: серверный /lite')),
                      ],
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _economyLevel == EconomyLevel.none
                              ? const Color(0xFF333333)
                              : Colors.greenAccent.shade400,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                              color: _economyLevel == EconomyLevel.none
                                  ? Colors.grey
                                  : Colors.greenAccent),
                        ),
                        child: Text(
                          _economyLabel(_economyLevel),
                          style: TextStyle(
                              color: _economyLevel == EconomyLevel.none
                                  ? Colors.white70
                                  : Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    // ── VPN (sing-box) ──
                    IconButton(
                      icon: Icon(
                        _vpnState == VpnState.connected
                            ? Icons.shield
                            : Icons.shield_outlined,
                        color: _vpnState == VpnState.connected
                            ? Colors.greenAccent
                            : _vpnState == VpnState.connecting
                                ? Colors.orange
                                : Colors.white54,
                        size: 20,
                      ),
                      tooltip: _vpnTooltip(),
                      onPressed: _toggleVpn,
                    ),
                    // YouTube: кнопки «Сжать» + «Оригинал/Сжатое» в хедере
                    if (_onYouTube) ...[
                      // Кнопка «Сжать видео» — рядом с адресной строкой
                      GestureDetector(
                        onTap: _compressYouTube,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.red.shade700,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.compress,
                                  color: Colors.white, size: 14),
                              SizedBox(width: 4),
                              Text('Сжать',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      // Переключатель «Оригинал/Сжатое» (режим наложения кнопок на превью)
                      GestureDetector(
                        onTap: () {
                          setState(() => _compressMode = !_compressMode);
                          _toggleYouTubeCompressMode();
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: _compressMode
                                ? Colors.orange
                                : const Color(0xFF333333),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                                color:
                                    _compressMode ? Colors.orange : Colors.grey,
                                width: 1.5),
                          ),
                          child: Text(
                            _compressMode ? '🔥 Сжатое' : '🔄 Оригинал',
                            style: TextStyle(
                                color: _compressMode
                                    ? Colors.black
                                    : Colors.white70,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (_pageLoading)
                const LinearProgressIndicator(
                  minHeight: 3,
                  color: Colors.orange,
                  backgroundColor: Color(0xFF333333),
                ),

              // WebView — скрыт когда плеер сверху (экономия GPU)
              Expanded(
                child: Offstage(
                  offstage: _showPlayer,
                  child: Stack(
                    children: [
                      InAppWebView(
                        key: ValueKey('webview_${_webViewInstance}_direct'),
                        webViewEnvironment: _webViewEnvironment,
                        initialUrlRequest:
                            URLRequest(url: WebUri("about:blank")),
                        initialSettings: InAppWebViewSettings(
                          useShouldOverrideUrlLoading: true,
                          useShouldInterceptRequest: true,
                          useOnLoadResource: true,
                          mediaPlaybackRequiresUserGesture: false,
                          domStorageEnabled: true,
                          databaseEnabled: true,
                          cacheEnabled: true,
                          javaScriptEnabled: true,
                          transparentBackground: false,
                          hardwareAcceleration: false,
                          // Chrome UA — YouTube блокирует Edge/WebView2 UA
                          userAgent:
                              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
                        ),
                        onWebViewCreated: (controller) {
                          webViewController = controller;
                          final restoreUrl = _webViewRestoreUrl;
                          _webViewRestoreUrl = null;
                          if (mounted) {
                            setState(() {
                              _webViewReady = true;
                              _pageLoading = restoreUrl != null &&
                                  restoreUrl != 'about:blank';
                            });
                          }
                          if (restoreUrl != null &&
                              restoreUrl != 'about:blank') {
                            controller.loadUrl(
                                urlRequest:
                                    URLRequest(url: WebUri(restoreUrl)));
                          }
                          controller.addJavaScriptHandler(
                            handlerName: 'compressUrl',
                            callback: (args) {
                              if (args.isEmpty) return null;
                              final raw = args.first?.toString() ?? '';
                              if (raw.isEmpty) return null;
                              _openCompressedUrl(raw,
                                  referer: 'https://www.youtube.com/');
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'seasonvarMeta',
                            callback: (args) {
                              if (args.isEmpty) return null;
                              try {
                                final map = Map<String, dynamic>.from(
                                    jsonDecode(args.first.toString()) as Map);
                                final trs = (map['translations']
                                            as List<dynamic>? ??
                                        const [])
                                    .map((e) =>
                                        Map<String, dynamic>.from(e as Map))
                                    .map((m) => <String, String>{
                                          'id': m['id']?.toString() ?? '',
                                          'name': m['name']?.toString() ?? '',
                                          'index': m['index']?.toString() ?? '',
                                        })
                                    .where((m) =>
                                        (m['id'] ?? '').isNotEmpty &&
                                        (m['name'] ?? '').isNotEmpty)
                                    .toList();
                                final seasons = (map['seasons']
                                            as List<dynamic>? ??
                                        const [])
                                    .map((e) =>
                                        Map<String, dynamic>.from(e as Map))
                                    .map((m) => <String, String>{
                                          'title': m['title']?.toString() ?? '',
                                          'url': m['url']?.toString() ?? '',
                                        })
                                    .where((m) =>
                                        (m['title'] ?? '').isNotEmpty &&
                                        (m['url'] ?? '').isNotEmpty)
                                    .toList();
                                final activeTranslationId =
                                    map['activeTranslationId']?.toString() ??
                                        '';
                                if (!mounted) return null;
                                setState(() {
                                  _seasonvarTranslations = trs;
                                  _seasonvarSeasons = seasons;
                                  if (activeTranslationId.isNotEmpty) {
                                    _seasonvarTranslationId =
                                        activeTranslationId;
                                  }
                                });
                              } catch (_) {}
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'seasonvarPlaylist',
                            callback: (args) {
                              _scanningSeasonvar = false;
                              if (args.isEmpty) return null;
                              try {
                                final decoded =
                                    jsonDecode(args.first.toString())
                                        as List<dynamic>;
                                final episodes = decoded
                                    .map((e) {
                                      final m =
                                          Map<String, dynamic>.from(e as Map);
                                      return <String, String>{
                                        'index': m['index']?.toString() ?? '',
                                        'title': m['title']?.toString() ?? '',
                                        'translation':
                                            m['translation']?.toString() ?? '',
                                        'url': m['url']?.toString() ?? '',
                                      };
                                    })
                                    .where((e) => (e['url'] ?? '').isNotEmpty)
                                    .toList();

                                String selectedTranslationName = '';
                                if (_seasonvarTranslationId.isNotEmpty) {
                                  final selectedTranslation =
                                      _seasonvarTranslations.firstWhere(
                                    (t) =>
                                        (t['id'] ?? '') ==
                                        _seasonvarTranslationId,
                                    orElse: () => const <String, String>{},
                                  );
                                  selectedTranslationName =
                                      selectedTranslation['name'] ?? '';
                                }

                                var activeEpisodes = episodes;
                                if (selectedTranslationName.isNotEmpty) {
                                  final filtered = episodes
                                      .where((e) =>
                                          (e['translation'] ?? '') ==
                                          selectedTranslationName)
                                      .toList();
                                  if (filtered.isNotEmpty) {
                                    activeEpisodes = filtered;
                                  }
                                }

                                if (mounted) {
                                  var currentIndex = 0;
                                  final currentUrl = _interceptedUrl;
                                  final foundIndex = activeEpisodes.indexWhere(
                                      (e) => (e['url'] ?? '') == currentUrl);
                                  if (foundIndex >= 0) {
                                    currentIndex = foundIndex;
                                  }
                                  setState(() {
                                    _seasonvarEpisodes = activeEpisodes;
                                    _seasonvarIndex = currentIndex;
                                  });
                                  if (activeEpisodes.isNotEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              'Список серий готов: ${activeEpisodes.length}'),
                                          duration: const Duration(seconds: 2)),
                                    );
                                  }
                                }
                              } catch (e) {
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                        content:
                                            Text('Ошибка скана Seasonvar: $e'),
                                        duration: const Duration(seconds: 4)),
                                  );
                                }
                              }
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'filmixEpisodes',
                            callback: (args) {
                              if (args.isEmpty) return null;
                              try {
                                final decoded =
                                    jsonDecode(args.first.toString())
                                        as List<dynamic>;
                                final episodes = decoded
                                    .map((e) {
                                      final m =
                                          Map<String, dynamic>.from(e as Map);
                                      return <String, String>{
                                        'title': m['title']?.toString() ?? '',
                                        'season': m['season']?.toString() ?? '',
                                        'episode':
                                            m['episode']?.toString() ?? '',
                                        'translation':
                                            m['translation']?.toString() ?? '',
                                      };
                                    })
                                    .where((e) => (e['title'] ?? '').isNotEmpty)
                                    .toList();
                                if (!mounted) return null;
                                final current = (_filmixIndex >= 0 &&
                                        _filmixIndex < _filmixEpisodes.length)
                                    ? _filmixEpisodes[_filmixIndex]
                                    : null;
                                setState(() {
                                  _filmixEpisodes = episodes;
                                  if (current == null ||
                                      _filmixEpisodes.isEmpty) {
                                    _filmixIndex = 0;
                                  } else {
                                    final idx = _findFilmixGlobalIndexByEpisode(
                                        current);
                                    _filmixIndex = idx >= 0 ? idx : 0;
                                  }
                                });
                              } catch (_) {}
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'filmixMeta',
                            callback: (args) {
                              if (args.isEmpty) return null;
                              try {
                                final map = Map<String, dynamic>.from(
                                    jsonDecode(args.first.toString()) as Map);
                                final translations = (map['translations']
                                            as List<dynamic>? ??
                                        const [])
                                    .whereType<Map>()
                                    .map((raw) {
                                      final m = Map<String, dynamic>.from(raw);
                                      final id = (m['id'] ?? m['name'] ?? '')
                                          .toString()
                                          .trim();
                                      final name =
                                          (m['name'] ?? id).toString().trim();
                                      return <String, String>{
                                        'id': id,
                                        'name': name
                                      };
                                    })
                                    .where((e) => (e['id'] ?? '').isNotEmpty)
                                    .toList();
                                final seasons = (map['seasons']
                                            as List<dynamic>? ??
                                        const [])
                                    .whereType<Map>()
                                    .map((raw) {
                                      final m = Map<String, dynamic>.from(raw);
                                      final id =
                                          (m['id'] ?? '').toString().trim();
                                      final name = (m['name'] ?? ('Сезон $id'))
                                          .toString()
                                          .trim();
                                      return <String, String>{
                                        'id': id,
                                        'name': name
                                      };
                                    })
                                    .where((e) => (e['id'] ?? '').isNotEmpty)
                                    .toList();
                                final activeTranslation =
                                    (map['activeTranslation'] ?? '')
                                        .toString()
                                        .trim();
                                final activeSeason = (map['activeSeason'] ?? '')
                                    .toString()
                                    .trim();
                                if (!mounted) return null;
                                setState(() {
                                  _filmixTranslations = translations;
                                  _filmixSeasons = seasons;
                                  final hasCurrentTranslation =
                                      _filmixTranslationId.isNotEmpty &&
                                          _filmixTranslations.any((e) =>
                                              (e['id'] ?? '') ==
                                              _filmixTranslationId);
                                  if (activeTranslation.isNotEmpty &&
                                      !hasCurrentTranslation) {
                                    _filmixTranslationId = activeTranslation;
                                  }
                                  final hasCurrentSeason = _filmixSeasonId
                                          .isNotEmpty &&
                                      _filmixSeasons.any((e) =>
                                          (e['id'] ?? '') == _filmixSeasonId);
                                  if (activeSeason.isNotEmpty &&
                                      !hasCurrentSeason) {
                                    _filmixSeasonId = activeSeason;
                                  }
                                });
                              } catch (_) {}
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'filmixEpisodeHint',
                            callback: (args) {
                              if (args.isEmpty) return null;
                              try {
                                final map = Map<String, dynamic>.from(
                                    jsonDecode(args.first.toString()) as Map);
                                final title = map['title']?.toString() ?? '';
                                final season = map['season']?.toString() ?? '';
                                final episode =
                                    map['episode']?.toString() ?? '';
                                final translation =
                                    map['translation']?.toString() ?? '';
                                if (season.isEmpty &&
                                    episode.isEmpty &&
                                    title.isEmpty &&
                                    translation.isEmpty) return null;

                                final hint = <String, String>{
                                  'title': title.isNotEmpty
                                      ? title
                                      : 'S$season E$episode',
                                  'season': season,
                                  'episode': episode,
                                  'translation': translation,
                                };
                                if (!mounted) return null;
                                setState(() {
                                  final existingIndex =
                                      _filmixEpisodes.indexWhere((e) =>
                                          (e['season'] ?? '') == season &&
                                          (e['episode'] ?? '') == episode &&
                                          (e['translation'] ?? '') ==
                                              translation &&
                                          season.isNotEmpty &&
                                          episode.isNotEmpty);
                                  if (existingIndex >= 0) {
                                    _filmixIndex = existingIndex;
                                  } else {
                                    _filmixEpisodes = [
                                      ..._filmixEpisodes,
                                      hint
                                    ];
                                    _filmixIndex = _filmixEpisodes.length - 1;
                                  }
                                  if (translation.isNotEmpty &&
                                      _filmixTranslationId.isEmpty) {
                                    _filmixTranslationId = translation;
                                  }
                                  if (season.isNotEmpty &&
                                      _filmixSeasonId.isEmpty) {
                                    _filmixSeasonId = season;
                                  }
                                });
                              } catch (_) {}
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'filmixDebug',
                            callback: (args) {
                              // Только для диагностики через консольный probe-скрипт.
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'filmixMediaUrl',
                            callback: (args) {
                              if (args.isEmpty) return null;
                              final mediaUrl =
                                  args.first?.toString().trim() ?? '';
                              if (mediaUrl.isEmpty) return null;
                              if (mediaUrl == _lastFilmixMediaUrl) return null;
                              _lastFilmixMediaUrl = mediaUrl;
                              _autoStartFromMediaUrl(mediaUrl,
                                  referer: urlController.text);
                              return null;
                            },
                          );
                        },
                        onLoadStart: (controller, url) {
                          if (mounted) {
                            setState(() {
                              _pageLoading = true;
                            });
                          }
                        },
                        onLoadStop: (controller, url) async {
                          if (mounted) {
                            setState(() {
                              _pageLoading = false;
                              _webViewRetryCount = 0;
                            });
                          }
                          if (url != null) {
                            if (url.path == '/lite' &&
                                url.queryParameters['url'] != null) {
                              urlController.text = url.queryParameters['url']!;
                              _currentRealUrl = url.queryParameters['url']!;
                            } else {
                              urlController.text = url.toString();
                              if (url.toString() != 'about:blank') {
                                _currentRealUrl = url.toString();
                              }
                            }
                            if (_currentRealUrl.isNotEmpty &&
                                _currentRealUrl != 'about:blank') {
                              _rememberUrl(_currentRealUrl);
                            }
                            if (url.toString() != 'about:blank' && _showHome) {
                              setState(() => _showHome = false);
                            }

                            // Seasonvar: трекер кликов (плейлист грузится через plist.txt ~3с)
                            if (url.host.contains('seasonvar')) {
                              Future.delayed(const Duration(seconds: 4), () {
                                if (mounted) {
                                  controller.evaluateJavascript(
                                      source: "(function(){"
                                          "if(window.__vt)return 'ok';"
                                          "window.__vt=true;window.__vakh_idx=-1;"
                                          "var pl=document.querySelector('#htmlPlayer_playlist');"
                                          "if(!pl)return 'no-pl';"
                                          "var its=Array.from(pl.querySelectorAll('li,a'));"
                                          "its.forEach(function(it,i){it.addEventListener('click',function(){window.__vakh_idx=i;},true);});"
                                          "for(var i=0;i<its.length;i++){"
                                          "var d=its[i].querySelector('span[style]');"
                                          "var c=its[i].className||'';"
                                          "if(d||c.includes('active')||c.includes('current')){window.__vakh_idx=i;break;}"
                                          "}"
                                          "return 'ok:'+its.length+'/'+window.__vakh_idx;"
                                          "})();");
                                }
                              });
                            }

                            // YouTube: ховер-кнопки
                            if (url.host.contains('youtube.com')) {
                              controller.evaluateJavascript(
                                  source: YouTubeHover.getInjectionJS());
                            }

                            // YouTube /watch — fallback: если страница всё-таки открылась, глушим и сразу запускаем 240p
                            if (url.host.contains('youtube.com') &&
                                (url.path.contains('/watch') ||
                                    url.path.contains('/shorts/')) &&
                                !_showInterceptor &&
                                !_showPlayer) {
                              controller.evaluateJavascript(
                                  source:
                                      "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;e.pause();});");
                              _selectedQuality = '240p';
                              _openCompressedUrl(url.toString(),
                                  referer: 'https://www.youtube.com/');
                            }
                            _updateYouTubeState(url);
                          }
                        },
                        onReceivedError: (controller, request, error) {
                          final failedUrl = request.url?.toString() ?? '';
                          if (failedUrl.isEmpty ||
                              failedUrl == 'about:blank' ||
                              !failedUrl.startsWith('http')) return;
                          // Ретрим только главный фрейм, не саб-ресурсы
                          final isMain = request.isForMainFrame ?? true;
                          if (!isMain) return;
                          // CONNECTION_ABORTED — норма при навигации
                          if (error.type == WebResourceErrorType.CONNECTION_ABORTED) return;
                          LogService.warn(LogService.browser,
                              'WebView ошибка: $failedUrl — ${error.description}');
                          _lastFailedUrl = failedUrl;
                          if (_webViewRetryCount < _webViewMaxRetries) {
                            _webViewRetryCount++;
                            final delayMs = 1000 * (1 << (_webViewRetryCount - 1));
                            Future.delayed(Duration(milliseconds: delayMs), () {
                              if (mounted && _lastFailedUrl == failedUrl) {
                                controller.loadUrl(urlRequest:
                                    URLRequest(url: WebUri(failedUrl)));
                              }
                            });
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'Повторная загрузка (${_webViewRetryCount}/$_webViewMaxRetries)...'),
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            }
                          } else {
                            _webViewRetryCount = 0;
                            if (mounted) {
                              setState(() => _pageLoading = false);
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                      'Не удалось загрузить: ${error.description}'),
                                  duration: const Duration(seconds: 6),
                                  action: SnackBarAction(
                                    label: 'Повторить',
                                    onPressed: () {
                                      _webViewRetryCount = 0;
                                      _loadAddress(failedUrl);
                                    },
                                  ),
                                ),
                              );
                            }
                          }
                        },
                        onUpdateVisitedHistory: (controller, url, isReload) {
                          // YouTube: ловим pushState-навигацию (YouTube SPA)
                          if (url != null) {
                            if (url.path == '/lite' &&
                                url.queryParameters['url'] != null) {
                              urlController.text = url.queryParameters['url']!;
                              _currentRealUrl = url.queryParameters['url']!;
                            } else {
                              urlController.text = url.toString();
                              if (url.toString() != 'about:blank') {
                                _currentRealUrl = url.toString();
                              }
                            }
                            if (_currentRealUrl.isNotEmpty &&
                                _currentRealUrl != 'about:blank') {
                              _rememberUrl(_currentRealUrl);
                            }
                            _updateYouTubeState(url);
                            if (url.host.contains('youtube.com') &&
                                (url.path.contains('/watch') ||
                                    url.path.contains('/shorts/')) &&
                                !_showInterceptor &&
                                !_showPlayer) {
                              controller.evaluateJavascript(
                                  source:
                                      "document.querySelectorAll('video,audio').forEach(function(e){e.muted=true;e.pause();});");
                              _selectedQuality = '240p';
                              _openCompressedUrl(url.toString(),
                                  referer: 'https://www.youtube.com/');
                            }
                          }
                        },
                        onLoadResource: (controller, resource) {
                          final raw = resource.url?.toString() ?? '';
                          if (raw.isEmpty) return;
                          final low = raw.toLowerCase();
                          if (!_looksLikeMediaUrl(low)) return;
                          if (!(_isFilmixContext(low) ||
                              _isFilmixContext(_currentRealUrl))) {
                            return;
                          }
                          _autoStartFromMediaUrl(raw,
                              referer: urlController.text);
                        },
                        shouldOverrideUrlLoading:
                            (controller, navigationAction) async {
                          var url = navigationAction.request.url;
                          if (url == null) return NavigationActionPolicy.ALLOW;

                          if (url.host.contains('filmix') &&
                              (url.path.contains('profile') ||
                                  url.path.contains('user') ||
                                  url.path.contains('login'))) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text(
                                      'Профиль Filmix заблокирован в приложении'),
                                  duration: Duration(seconds: 2)),
                            );
                            return NavigationActionPolicy.CANCEL;
                          }

                          if (_economyLevel == EconomyLevel.text &&
                              url.path != '/lite' &&
                              !url.toString().startsWith('about:')) {
                            final wrapped = ApiService.liteUrl(url.toString());
                            controller.loadUrl(
                                urlRequest: URLRequest(url: WebUri(wrapped)));
                            return NavigationActionPolicy.CANCEL;
                          }

                          // YouTube: не грузим страницу — грузим about:blank и показываем шторку
                          if (url.host.contains('youtube.com') &&
                              (url.path.contains('/watch') ||
                                  url.path.contains('/shorts/')) &&
                              !_showInterceptor &&
                              !_showPlayer) {
                            Future.microtask(() {
                              if (mounted) {
                                _selectedQuality = '240p';
                                _openCompressedUrl(url.toString(),
                                    referer: 'https://www.youtube.com/');
                              }
                            });
                            // Возвращаем ALLOW но тут же редиректим на blank чтобы не грузить ютуб
                            controller.loadUrl(
                                urlRequest:
                                    URLRequest(url: WebUri("about:blank")));
                            return NavigationActionPolicy.CANCEL;
                          }
                          return NavigationActionPolicy.ALLOW;
                        },
                        shouldInterceptRequest: (controller, request) async {
                          var uri = request.url.toString().toLowerCase();
                          var method = request.method ?? "GET";

                          // 1. Исключаем мусор, скрипты, картинки и статику
                          if (uri.contains('.js') ||
                              uri.contains('.css') ||
                              uri.contains('.jpg') ||
                              uri.contains('.png') ||
                              uri.contains('.gif') ||
                              uri.contains('.webp') ||
                              uri.contains('.woff') ||
                              uri.contains('.ttf') ||
                              uri.contains('.svg')) {
                            return null;
                          }

                          // 2. Ищем признаки медиа, исключая превьюшки и рекламу
                          var isMedia = _looksLikeMediaUrl(uri);
                          if (!isMedia &&
                              (uri.contains('.3gp') ||
                                  uri.contains('.avi') ||
                                  uri.contains('.flv'))) {
                            isMedia = true;
                          }

                          final isMediaPlatformRelated =
                              uri.contains('filmix') ||
                                  uri.contains('kodik') ||
                                  uri.contains('videocdn') ||
                                  uri.contains('hdrezka') ||
                                  uri.contains('rezka') ||
                                  uri.contains('zona');
                          if (!isMedia && isMediaPlatformRelated) {
                            if (uri.contains('manifest') ||
                                uri.contains('/hls/') ||
                                uri.contains('master.m3u8') ||
                                uri.contains('playlist') ||
                                uri.contains('/stream/') ||
                                uri.contains('/vod/') ||
                                uri.contains('/cdn/') ||
                                uri.contains('/video/')) {
                              isMedia = true;
                            }
                          }

                          // Исключаем чанки YouTube — серверу нужна ссылка на страницу, не на кусочек
                          if (uri.contains('googlevideo.com')) isMedia = false;

                          // Во время фонового скана Seasonvar берём URL, но не даём сайту качать видео
                          if (_scanningSeasonvar && isMedia) {
                            return WebResourceResponse(
                              contentType: "text/plain",
                              data: Uint8List.fromList([]),
                              statusCode: 200,
                            );
                          }

                          // Перехват медиа-запросов
                          if (method.toUpperCase() == "GET" && isMedia) {
                            // Filmix hint extraction disabled
                            // Режим авто-переключения серий: сразу сжимаем без шторки
                            if (_waitingForNextEpisode) {
                              _interceptedAlready = false;
                              _autoStartFromMediaUrl(request.url.toString(),
                                  referer: urlController.text);
                              return WebResourceResponse(
                                  contentType: "text/plain",
                                  data: Uint8List.fromList([]),
                                  statusCode: 200);
                            }

                            // Обычный режим: без шторки, сразу стартуем в качестве по умолчанию (240p)
                            if (!_showInterceptor &&
                                !_showPlayer &&
                                !_interceptedAlready) {
                              _autoStartFromMediaUrl(request.url.toString(),
                                  referer: urlController.text);
                            }

                            // Пустой ответ — чужой плеер не начинает жрать трафик
                            return WebResourceResponse(
                                contentType: "text/plain",
                                data: Uint8List.fromList([]),
                                statusCode: 200);
                          }
                          return null;
                        },
                      ),
                      if (!_webViewReady)
                        Container(
                          color: Colors.black,
                          child: const Center(
                            child:
                                CircularProgressIndicator(color: Colors.orange),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),

          if (_showHome && !_showPlayer)
            Positioned.fill(
              top: 92,
              child: Container(
                color: const Color(0xFF111111),
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Text('Плеер Вахтовика', style: TextStyle(color: Colors.orange, fontSize: 24, fontWeight: FontWeight.bold)),
                      const Spacer(),
                      IconButton(icon: const Icon(Icons.bug_report, color: Colors.orange, size: 20), tooltip: 'Лог ошибок', onPressed: _showLogDialog),
                    ]),
                    const SizedBox(height: 8),
                    const Text('Выбери сайт или введи свой адрес сверху',
                        style: TextStyle(color: Colors.white70)),
                    const SizedBox(height: 20),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _HomeSiteButton(
                            label: 'Seasonvar',
                            icon: Icons.tv,
                            onTap: () => _openSite('https://seasonvar.ru/')),
                        _HomeSiteButton(
                            label: 'Filmix',
                            icon: Icons.movie,
                            onTap: () => _openSite('https://filmix.my/')),
                        _HomeSiteButton(
                            label: 'HDRezka',
                            icon: Icons.live_tv,
                            onTap: () => _openSite('https://hdrezka.ag/')),
                        _HomeSiteButton(
                            label: 'Zona',
                            icon: Icons.movie_creation_outlined,
                            onTap: () => _openSite('https://zona.plus/')),
                        _HomeSiteButton(
                            label: 'YouTube',
                            icon: Icons.play_circle,
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const YouTubeSearchScreen()))),
                        _HomeSiteButton(
                            label: 'IPTV',
                            icon: Icons.live_tv,
                            onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) => const IptvScreen()))),
                        _HomeSiteButton(
                            label: 'Свой сайт',
                            icon: Icons.add_link,
                            onTap: _showCustomSiteDialog),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Эпизоды Seasonvar/Filmix — кнопки поверх браузера
          if (_hasEpisodeList)
            Positioned(
              top: 92,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black87,
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          Text(
                            _seasonvarEpisodes.isNotEmpty ? 'Seasonvar: ' : 'Filmix: ',
                            style: const TextStyle(
                                color: Colors.orange, fontSize: 13),
                          ),
                          ...List.generate(_activeEpisodes.length, (index) {
                            final active = index == _activeEpisodeIndex;
                            final rawTitle =
                                _activeEpisodes[index]['title'] ?? '';
                            final season =
                                _activeEpisodes[index]['season'] ?? '';
                            final episode =
                                _activeEpisodes[index]['episode'] ?? '';
                            final btnLabel = _seasonvarEpisodes.isNotEmpty
                                ? '${index + 1}'
                                : (season.isNotEmpty || episode.isNotEmpty)
                                    ? 'S${season.isNotEmpty ? season : "?"} E${episode.isNotEmpty ? episode : "?"}'
                                    : rawTitle.split(' ').take(2).join(' ');
                            return Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: OutlinedButton(
                                onPressed: () =>
                                    _playEpisodeFromActiveList(index),
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: active
                                      ? Colors.orange
                                      : Colors.transparent,
                                  foregroundColor:
                                      active ? Colors.black : Colors.white,
                                  side: BorderSide(
                                      color: active
                                          ? Colors.orange
                                          : Colors.white38),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  minimumSize: Size.zero,
                                ),
                                child: Text(
                                    btnLabel.isEmpty
                                        ? '${index + 1}'
                                        : btnLabel,
                                    style: const TextStyle(fontSize: 12)),
                              ),
                            );
                          }),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // YouTube FAB убран — кнопка «Сжать» теперь в хедере

          // Interceptor Overlay
          if (_showInterceptor)
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E1E1E),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black54,
                        blurRadius: 10,
                        offset: Offset(0, -5))
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('✨ Видеопоток перехвачен!',
                        style: TextStyle(
                            color: Colors.orange,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    const Text('Выберите качество сжатия:',
                        style: TextStyle(color: Colors.grey, fontSize: 14)),
                    const SizedBox(height: 15),
                    if (_presets.isEmpty)
                      const CircularProgressIndicator()
                    else
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: _presets.map((preset) {
                            final isActive = _selectedQuality == preset.id;
                            return GestureDetector(
                              onTap: () =>
                                  setState(() => _selectedQuality = preset.id),
                              child: Container(
                                margin: const EdgeInsets.only(right: 10),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 20, vertical: 10),
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? Colors.orange.withOpacity(0.2)
                                      : const Color(0xFF2A2A2A),
                                  border: Border.all(
                                      color: isActive
                                          ? Colors.orange
                                          : const Color(0xFF555555),
                                      width: 2),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(preset.label,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold)),
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: OutlinedButton(
                            onPressed: () {
                              setState(() {
                                _showInterceptor = false;
                                _interceptedAlready = false;
                              });
                              // Возвращаем звук WebView — пользователь выбрал оригинал
                              webViewController?.evaluateJavascript(
                                  source:
                                      "document.querySelectorAll('video,audio').forEach(function(e){e.muted=false;});");
                            },
                            style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.grey)),
                            child: const Text('Оригинал'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _startMagic,
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange,
                                foregroundColor: Colors.black),
                            child: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        color: Colors.black, strokeWidth: 2))
                                : const Text('Сжать и смотреть ▶',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Загрузка плеера — оверлей пока идёт инициализация
          if (_isLoading && !_showPlayer)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                        color: const Color(0xCC1A0F08),
                        borderRadius: BorderRadius.circular(16)),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(color: Colors.orange),
                        const SizedBox(height: 14),
                        Text('Запускаю $_selectedQuality...',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 16)),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // Native Player Screen
          if (_showPlayer)
            Positioned.fill(
              child: Container(
                color: Colors.black,
                child: Stack(
                  children: [
                    // Chewie плеер
                    Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.only(
                              top: 40, left: 10, right: 10, bottom: 10),
                          color: Colors.black87,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.arrow_back,
                                        color: Colors.white),
                                    onPressed: _stopPlayer,
                                  ),
                                  Text(
                                    _hasEpisodeList
                                        ? 'Серия ${_activeEpisodeIndex + 1} / ${_activeEpisodes.length} · $_selectedQuality'
                                        : 'Стриминг: $_selectedQuality',
                                    style: const TextStyle(
                                        color: Colors.orange,
                                        fontWeight: FontWeight.bold),
                                  ),
                                  const Spacer(),
                                  PopupMenuButton<String>(
                                    tooltip: 'Качество',
                                    icon: const Icon(Icons.settings,
                                        color: Colors.orange),
                                    color: const Color(0xFF1E1E1E),
                                    initialValue: _selectedQuality,
                                    onSelected: (q) {
                                      setState(() => _selectedQuality = q);
                                      _startMagic();
                                    },
                                    itemBuilder: (context) => const [
                                      PopupMenuItem(
                                          value: '144p', child: Text('144p')),
                                      PopupMenuItem(
                                          value: '240p', child: Text('240p')),
                                      PopupMenuItem(
                                          value: '360p', child: Text('360p')),
                                      PopupMenuItem(
                                          value: '480p', child: Text('480p')),
                                    ],
                                  ),
                                  TextButton.icon(
                                    onPressed: _playNextEpisode,
                                    icon: const Icon(Icons.skip_next,
                                        color: Colors.orange),
                                    label: const Text('След. серия',
                                        style: TextStyle(color: Colors.orange)),
                                  ),
                                ],
                              ),
                              if (_hasEpisodeList)
                                SizedBox(
                                  height: 38,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: _activeEpisodes.length,
                                    itemBuilder: (context, index) {
                                      final active =
                                          index == _activeEpisodeIndex;
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: OutlinedButton(
                                          onPressed: () =>
                                              _playEpisodeFromActiveList(index),
                                          style: OutlinedButton.styleFrom(
                                            backgroundColor: active
                                                ? Colors.orange
                                                : Colors.transparent,
                                            foregroundColor: active
                                                ? Colors.black
                                                : Colors.white,
                                            side: BorderSide(
                                                color: active
                                                    ? Colors.orange
                                                    : Colors.white38),
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 12),
                                          ),
                                          child: Text(
                                              _seasonvarEpisodes.isNotEmpty
                                                  ? '${index + 1}'
                                                  : (_activeEpisodes[index]
                                                              ['title'] ??
                                                          '${index + 1}')
                                                      .split(' ')
                                                      .take(2)
                                                      .join(' ')),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const Expanded(
                          child: Center(
                            child: Text(
                              'Мини-плеер перенесён',
                              style: TextStyle(color: Colors.white54),
                            ),
                          ),
                        ),
                      ],
                    ),
                    // _MiniProgressOverlay убран — Chewie уже показывает время снизу
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HomeSiteButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;

  const _HomeSiteButton(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: 150,
        height: 92,
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.orange.withOpacity(0.45)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.orange, size: 30),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

