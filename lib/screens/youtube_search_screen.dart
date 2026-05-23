import 'package:flutter/material.dart';
import '../models/youtube_video.dart';
import '../services/api_service.dart';
import 'player_screen.dart';

class YouTubeSearchScreen extends StatefulWidget {
  const YouTubeSearchScreen({super.key});

  @override
  State<YouTubeSearchScreen> createState() => _YouTubeSearchScreenState();
}

class _YouTubeSearchScreenState extends State<YouTubeSearchScreen> {
  final _searchController = TextEditingController();
  final _subController = TextEditingController();
  List<YouTubeVideo> _searchResults = const [];
  List<YouTubeVideo> _feed = const [];
  List<Map<String, dynamic>> _subs = const [];
  bool _loading = false;
  bool _starting = false;
  String _quality = '240p';

  static const _quickSearches = [
    'Лавкрафт аудиокнига Булдаков',
    'документальные фильмы космос',
    'музыка в дорогу',
    'ремонт авто диагностика',
    'интересные факты',
    'аудиокнига фантастика',
  ];

  @override
  void dispose() {
    _searchController.dispose();
    _subController.dispose();
    super.dispose();
  }

  Future<void> _search([String? query]) async {
    if (query != null) _searchController.text = query;
    final q = _searchController.text.trim();
    if (q.isEmpty || _loading) return;
    setState(() => _loading = true);
    try {
      final items = await ApiService.searchYouTube(q, limit: 12);
      if (mounted) setState(() => _searchResults = items);
    } catch (e) {
      if (mounted) _snack('Ошибка поиска: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadFeed() async {
    if (!await _ensureLogin()) return;
    setState(() => _loading = true);
    try {
      final items = await ApiService.youtubeFeed(limit: 40);
      if (mounted) setState(() => _feed = items);
    } catch (e) {
      if (mounted) _snack('Ошибка ленты: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _loadSubs() async {
    if (!await _ensureLogin()) return;
    setState(() => _loading = true);
    try {
      final items = await ApiService.youtubeSubscriptions();
      if (mounted) setState(() => _subs = items);
    } catch (e) {
      if (mounted) _snack('Ошибка подписок: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _addSub() async {
    if (!await _ensureLogin()) return;
    final text = _subController.text.trim();
    if (text.isEmpty) return;
    try {
      await ApiService.youtubeAddSubscription(text);
      _subController.clear();
      await _loadSubs();
      _snack('Подписка добавлена');
    } catch (e) {
      _snack('Ошибка: $e');
    }
  }

  Future<bool> _ensureLogin() async {
    if (ApiService.isYouTubeLoggedIn) return true;
    final ok = await _showLoginDialog();
    return ok == true;
  }

  Future<bool?> _showLoginDialog() async {
    final user = TextEditingController();
    final pass = TextEditingController();
    var register = false;
    var busy = false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Аккаунт YouTube-раздела'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: user,
                  decoration: const InputDecoration(labelText: 'Логин')),
              TextField(
                  controller: pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль')),
              CheckboxListTile(
                value: register,
                onChanged: (v) => setDialogState(() => register = v ?? false),
                title: const Text('Зарегистрировать новый'),
                contentPadding: EdgeInsets.zero,
              ),
              if (busy) const LinearProgressIndicator(color: Colors.orange),
            ],
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context, false),
                child: const Text('Отмена')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      setDialogState(() => busy = true);
                      try {
                        if (register) {
                          await ApiService.youtubeRegister(
                              user.text, pass.text);
                        } else {
                          await ApiService.youtubeLogin(user.text, pass.text);
                        }
                        if (context.mounted) Navigator.pop(context, true);
                      } catch (e) {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Ошибка: $e')));
                        }
                      } finally {
                        setDialogState(() => busy = false);
                      }
                    },
              child: Text(register ? 'Создать' : 'Войти'),
            ),
          ],
        ),
      ),
    );
    user.dispose();
    pass.dispose();
    if (mounted) setState(() {});
    return result;
  }

  Future<void> _play(YouTubeVideo video) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final targetUrl = video.url.isNotEmpty
          ? video.url
          : 'https://www.youtube.com/watch?v=${video.id}';
      final result = await ApiService.transcode(
          url: targetUrl,
          quality: _quality,
          referer: 'https://www.youtube.com/');
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => PlayerScreen(
              hlsUrl: ApiService.hlsUrl(result.playlistUrl),
              sessionId: result.sessionId)));
    } catch (e) {
      if (mounted) _snack('Ошибка запуска: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 4)));
  }

  String _formatDuration(int seconds) {
    if (seconds <= 0) return '';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = seconds % 60;
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  Widget _qualityButton() {
    return PopupMenuButton<String>(
      tooltip: 'Качество',
      initialValue: _quality,
      onSelected: (v) => setState(() => _quality = v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: '144p', child: Text('144p')),
        PopupMenuItem(value: '240p', child: Text('240p')),
        PopupMenuItem(value: '360p', child: Text('360p')),
        PopupMenuItem(value: '480p', child: Text('480p')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          const Icon(Icons.settings, color: Colors.orange),
          const SizedBox(width: 4),
          Text(_quality)
        ]),
      ),
    );
  }

  Widget _loginButton() {
    if (ApiService.isYouTubeLoggedIn) {
      return TextButton.icon(
        onPressed: () => setState(ApiService.youtubeLogout),
        icon: const Icon(Icons.logout, color: Colors.orange),
        label: Text(ApiService.youtubeUsername ?? 'Выйти',
            style: const TextStyle(color: Colors.white)),
      );
    }
    return TextButton.icon(
      onPressed: _showLoginDialog,
      icon: const Icon(Icons.person, color: Colors.orange),
      label: const Text('Войти', style: TextStyle(color: Colors.white)),
    );
  }

  Widget _emptySearch() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(
              'Выбери подборку или введи запрос. Видео пойдёт через сервер в $_quality.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: _quickSearches
                .map((q) => ActionChip(
                    label: Text(q),
                    onPressed: () => _search(q),
                    backgroundColor: const Color(0xFF242424),
                    labelStyle: const TextStyle(color: Colors.white),
                    side: const BorderSide(color: Colors.white24)))
                .toList(),
          ),
        ]),
      ),
    );
  }

  Widget _videoGrid(List<YouTubeVideo> items, {Widget? empty}) {
    if (_loading) {
      return const Center(
          child: CircularProgressIndicator(color: Colors.orange));
    }
    if (items.isEmpty) {
      return empty ??
          const Center(
              child: Text('Пусто', style: TextStyle(color: Colors.white70)));
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          childAspectRatio: 1.55,
          crossAxisSpacing: 8,
          mainAxisSpacing: 8),
      itemCount: items.length,
      itemBuilder: (_, i) => _videoCard(items[i]),
    );
  }

  Widget _videoCard(YouTubeVideo v) {
    final dur = _formatDuration(v.duration);
    return InkWell(
      onTap: () => _play(v),
      child: Container(
        decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white12)),
        clipBehavior: Clip.antiAlias,
        child: Row(children: [
          AspectRatio(
              aspectRatio: 16 / 9,
              child: v.thumbnail.isEmpty
                  ? Container(
                      color: Colors.black26,
                      child:
                          const Icon(Icons.play_circle, color: Colors.orange))
                  : Image.network(v.thumbnail,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) =>
                          Container(color: Colors.black26))),
          Expanded(
              child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(v.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style:
                                const TextStyle(fontWeight: FontWeight.bold)),
                        const Spacer(),
                        Text(
                            [v.channel, dur]
                                .where((e) => e.isNotEmpty)
                                .join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white60, fontSize: 12)),
                      ]))),
        ]),
      ),
    );
  }

  Widget _feedTab() {
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
                child: Text(
                    ApiService.isYouTubeLoggedIn
                        ? 'Лента подписок'
                        : 'Войди, чтобы видеть свою ленту',
                    style: const TextStyle(color: Colors.white70))),
            FilledButton.icon(
                onPressed: _loadFeed,
                icon: const Icon(Icons.refresh),
                label: const Text('Обновить')),
          ])),
      Expanded(
          child: _videoGrid(_feed,
              empty: Center(
                  child: Text(
                      ApiService.isYouTubeLoggedIn
                          ? 'Нет видео. Добавь подписки.'
                          : 'Нужен вход.',
                      style: const TextStyle(color: Colors.white70))))),
    ]);
  }

  Widget _searchTab() {
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _searchController,
            autofocus: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
                hintText: 'Поиск YouTube...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                    onPressed: _search, icon: const Icon(Icons.arrow_forward)),
                filled: true,
                fillColor: const Color(0xFF1E1E1E),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12))),
          )),
      Expanded(child: _videoGrid(_searchResults, empty: _emptySearch())),
    ]);
  }

  Widget _subsTab() {
    return Column(children: [
      Padding(
          padding: const EdgeInsets.all(8),
          child: Row(children: [
            Expanded(
                child: TextField(
                    controller: _subController,
                    decoration: const InputDecoration(
                        hintText: 'channel_id или ссылка /channel/UC...',
                        border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            IconButton(
                onPressed: _addSub,
                icon: const Icon(Icons.add, color: Colors.orange)),
            IconButton(
                onPressed: _loadSubs,
                icon: const Icon(Icons.refresh, color: Colors.white)),
          ])),
      Expanded(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.orange))
              : _subs.isEmpty
                  ? Center(
                      child: Text(
                          ApiService.isYouTubeLoggedIn
                              ? 'Подписок нет. Добавь channel_id.'
                              : 'Нужен вход.',
                          style: const TextStyle(color: Colors.white70)))
                  : ListView.builder(
                      itemCount: _subs.length,
                      itemBuilder: (_, i) {
                        final s = _subs[i];
                        return ListTile(
                            leading: const Icon(Icons.subscriptions,
                                color: Colors.orange),
                            title: Text((s['channel_name'] ?? s['channel_id'])
                                .toString()),
                            subtitle: Text((s['channel_id'] ?? '').toString()),
                            onTap: _loadFeed);
                      })),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        backgroundColor: const Color(0xFF111111),
        appBar: AppBar(
          title: const Text('YouTube без рекламы'),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          actions: [_qualityButton(), _loginButton()],
          bottom: const TabBar(tabs: [
            Tab(icon: Icon(Icons.home), text: 'Лента'),
            Tab(icon: Icon(Icons.search), text: 'Поиск'),
            Tab(icon: Icon(Icons.subscriptions), text: 'Подписки')
          ]),
        ),
        body: Stack(children: [
          TabBarView(children: [_feedTab(), _searchTab(), _subsTab()]),
          if (_starting)
            Container(
                color: Colors.black54,
                child: Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const CircularProgressIndicator(color: Colors.orange),
                  const SizedBox(height: 12),
                  Text('Запускаю $_quality...',
                      style: const TextStyle(color: Colors.white))
                ]))),
        ]),
      ),
    );
  }
}
