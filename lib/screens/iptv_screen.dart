import 'dart:async';
import 'package:flutter/material.dart';
import '../models/iptv_channel.dart';
import '../services/api_service.dart';
import '../services/iptv_service.dart';
import 'player_screen.dart';

class IptvScreen extends StatefulWidget {
  const IptvScreen({super.key});

  @override
  State<IptvScreen> createState() => _IptvScreenState();
}

class _IptvScreenState extends State<IptvScreen> {
  final _searchController = TextEditingController();
  List<IptvChannel> _channels = const [];
  String _category = 'Все';
  String _country = 'Все';
  String _quality = '240p';
  String _query = '';
  bool _loading = true;
  IptvChannel? _starting;
  String _error = '';

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final channels =
          await IptvService.loadChannels(forceRefresh: forceRefresh);
      if (!mounted) return;
      setState(() {
        _channels = channels;
        _loading = false;
        if (!_categories.contains(_category)) _category = 'Все';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _channels = IptvService.fallbackChannels;
        _loading = false;
        _error = 'Не загрузил IPTV-лист, включил резерв: $e';
      });
    }
  }

  List<String> get _categories => IptvService.categoriesFor(_channels);

  List<IptvChannel> get _filtered {
    return _channels.where((ch) {
      final catOk = _category == 'Все' || ch.category == _category;
      final countryOk = _country == 'Все' || ch.country == _country;
      return catOk && countryOk && ch.matches(_query);
    }).toList();
  }

  List<String> get _countries {
    final set = _channels.map((e) => e.country).where((e) => e.isNotEmpty).toSet();
    final result = <String>['Все'];
    for (final c in ['Россия', 'Беларусь']) { if (set.contains(c)) result.add(c); }
    return result;
  }

  Future<void> _play(IptvChannel channel) async {
    if (_starting != null) return;
    setState(() => _starting = channel);
    try {
      final result = await ApiService.transcode(
        url: channel.url,
        quality: _quality,
        referer: '',
      );
      if (!mounted) return;
      await Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => PlayerScreen(
          hlsUrl: ApiService.hlsUrl(result.playlistUrl),
          sessionId: result.sessionId,
          sourceUrl: channel.url,
          quality: _quality,
          referer: '',
          duration: result.duration,
        ),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('IPTV не запустился: $e')),
      );
    } finally {
      if (mounted) setState(() => _starting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _filtered;
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0B),
      appBar: AppBar(
        title: const Text('IPTV через сервер'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _quality,
              dropdownColor: const Color(0xFF1E1E1E),
              iconEnabledColor: Colors.orange,
              style: const TextStyle(
                  color: Colors.orange, fontWeight: FontWeight.bold),
              items: const [
                DropdownMenuItem(value: '144p', child: Text('144p')),
                DropdownMenuItem(value: '240p', child: Text('240p')),
                DropdownMenuItem(value: '360p', child: Text('360p')),
                DropdownMenuItem(value: '480p', child: Text('480p')),
              ],
              onChanged: (v) => setState(() => _quality = v ?? '240p'),
            ),
          ),
          IconButton(
            tooltip: 'Обновить список',
            icon: const Icon(Icons.refresh, color: Colors.orange),
            onPressed: _loading ? null : () => _load(forceRefresh: true),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Colors.orange.withOpacity(0.15),
              child: Text(_error, style: const TextStyle(color: Colors.orange)),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Поиск канала',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.orange),
                filled: true,
                fillColor: const Color(0xFF1A1A1A),
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
              ),
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          if (_countries.length > 1)
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Wrap(spacing: 6, children: [
              const Text('Страна:', style: TextStyle(color: Colors.white54, fontSize: 11)),
              ..._countries.map((c) => ChoiceChip(selected: c==_country, label: Text(c, style: const TextStyle(fontSize: 11)),
                selectedColor: Colors.orange, backgroundColor: const Color(0xFF1A1A1A),
                labelStyle: TextStyle(color: c==_country?Colors.black:Colors.white70),
                onSelected: (_)=>setState(()=>_country=c), visualDensity: VisualDensity.compact)))
            ])),
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              children: _categories.map((cat) {
                final selected = cat == _category;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    selected: selected,
                    label: Text(cat),
                    selectedColor: Colors.orange,
                    backgroundColor: const Color(0xFF1A1A1A),
                    labelStyle: TextStyle(
                      color: selected ? Colors.black : Colors.white70,
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.normal,
                    ),
                    onSelected: (_) => setState(() => _category = cat),
                  ),
                );
              }).toList(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              _loading
                  ? 'Загружаю список...'
                  : 'Каналов: ${filtered.length} / ${_channels.length}',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.orange))
                : RefreshIndicator(
                    onRefresh: () => _load(forceRefresh: true),
                    child: filtered.isEmpty
                        ? ListView(
                            children: const [
                              SizedBox(height: 120),
                              Center(
                                child: Text('Каналов не найдено',
                                    style: TextStyle(color: Colors.white54)),
                              ),
                            ],
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(10, 6, 10, 16),
                            itemCount: filtered.length,
                            separatorBuilder: (_, __) =>
                                const Divider(height: 1, color: Colors.white10),
                            itemBuilder: (context, index) => _ChannelTile(
                              channel: filtered[index],
                              starting: _starting?.url == filtered[index].url,
                              onPlay: () => _play(filtered[index]),
                            ),
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final IptvChannel channel;
  final bool starting;
  final VoidCallback onPlay;

  const _ChannelTile({
    required this.channel,
    required this.starting,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: _Logo(url: channel.logo),
      title: Text(
        channel.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
      ),
      subtitle: Text(
        '${channel.category}${channel.country.isNotEmpty ? ' · ${channel.country}' : ''}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white54),
      ),
      trailing: starting
          ? const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                  color: Colors.orange, strokeWidth: 2),
            )
          : FilledButton.icon(
              onPressed: onPlay,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Сжать'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orange,
                foregroundColor: Colors.black,
              ),
            ),
    );
  }
}

class _Logo extends StatelessWidget {
  final String url;
  const _Logo({required this.url});

  @override
  Widget build(BuildContext context) {
    if (url.trim().isEmpty) {
      return const CircleAvatar(
        backgroundColor: Color(0xFF1A1A1A),
        child: Icon(Icons.live_tv, color: Colors.orange),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: 44,
        height: 44,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => const CircleAvatar(
          backgroundColor: Color(0xFF1A1A1A),
          child: Icon(Icons.live_tv, color: Colors.orange),
        ),
      ),
    );
  }
}
