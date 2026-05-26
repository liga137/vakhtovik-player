import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:package_info_plus/package_info_plus.dart';

class AppUpdateInfo {
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String htmlUrl;
  final String releaseNotes;
  final String windowsAssetUrl;
  final String androidAssetUrl;

  const AppUpdateInfo({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.htmlUrl,
    required this.releaseNotes,
    required this.windowsAssetUrl,
    required this.androidAssetUrl,
  });
}

class UpdateService {
  static const _repoApiBase =
      'https://api.github.com/repos/liga137/vakhtovik-player';
  static const _repoLatestReleaseUrl = '$_repoApiBase/releases/latest';
  static const _repoReleasesUrl = '$_repoApiBase/releases?per_page=1';
  static const _repoTagsUrl = '$_repoApiBase/tags?per_page=1';
  static const _repoReleasesPage =
      'https://github.com/liga137/vakhtovik-player/releases';
  static http.Client get _client => IOClient(_directHttpClient());

  static HttpClient _directHttpClient() {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 20);
    return client;
  }

  static Future<AppUpdateInfo> checkLatest() async {
    final pkg = await PackageInfo.fromPlatform();
    final current = pkg.version;
    final map = await _fetchLatestRelease();
    var rawTag = map != null ? (map['tag_name'] ?? '').toString().trim() : '';
    if (rawTag.isEmpty) {
      rawTag = await _fetchLatestTag();
    }
    if (rawTag.isEmpty) {
      rawTag = current;
    }
    final latest = _normalizeVersion(rawTag);
    final currentNorm = _normalizeVersion(current);
    final hasUpdate = _compareVersion(currentNorm, latest) < 0;

    String winUrl = '';
    String apkUrl = '';
    if (map != null) {
      final assets = (map['assets'] as List<dynamic>? ?? const []);
      for (final a in assets) {
        final m = Map<String, dynamic>.from(a as Map);
        final name = (m['name'] ?? '').toString().toLowerCase();
        final url = (m['browser_download_url'] ?? '').toString();
        if (url.isEmpty) continue;
        if (winUrl.isEmpty &&
            (name.contains('windows') ||
                name.endsWith('.zip') ||
                name.endsWith('.exe'))) {
          winUrl = url;
        }
        if (apkUrl.isEmpty && name.endsWith('.apk')) {
          apkUrl = url;
        }
      }
    }

    return AppUpdateInfo(
      hasUpdate: hasUpdate,
      currentVersion: currentNorm,
      latestVersion: latest,
      htmlUrl: map != null
          ? (map['html_url'] ?? _repoReleasesPage).toString()
          : _repoReleasesPage,
      releaseNotes: map != null
          ? (map['body'] ?? '').toString()
          : 'GitHub Releases пока не опубликованы. Используется последняя версия из тегов.',
      windowsAssetUrl: winUrl,
      androidAssetUrl: apkUrl,
    );
  }

  static Future<Map<String, dynamic>?> _fetchLatestRelease() async {
    final headers = {
      'Accept': 'application/vnd.github+json',
      'User-Agent': 'vakhtovik-player'
    };

    final latestResp =
        await _client.get(Uri.parse(_repoLatestReleaseUrl), headers: headers);
    if (latestResp.statusCode == 200) {
      return jsonDecode(latestResp.body) as Map<String, dynamic>;
    }
    if (latestResp.statusCode != 404 && latestResp.statusCode != 403) {
      throw Exception('GitHub API releases/latest: ${latestResp.statusCode}');
    }

    final releasesResp =
        await _client.get(Uri.parse(_repoReleasesUrl), headers: headers);
    if (releasesResp.statusCode == 200) {
      final list = jsonDecode(releasesResp.body) as List<dynamic>;
      if (list.isNotEmpty) {
        return Map<String, dynamic>.from(list.first as Map);
      }
      return null;
    }
    if (releasesResp.statusCode == 404 || releasesResp.statusCode == 403)
      return null;
    throw Exception('GitHub API releases: ${releasesResp.statusCode}');
  }

  static Future<String> _fetchLatestTag() async {
    final resp = await _client.get(
      Uri.parse(_repoTagsUrl),
      headers: {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'vakhtovik-player'
      },
    );
    if (resp.statusCode == 404 || resp.statusCode == 403) {
      return '';
    }
    if (resp.statusCode != 200) {
      throw Exception('GitHub API tags: ${resp.statusCode}');
    }
    final tags = jsonDecode(resp.body) as List<dynamic>;
    if (tags.isEmpty) return '0.0.0';
    final first = Map<String, dynamic>.from(tags.first as Map);
    return (first['name'] ?? '').toString();
  }

  static String _normalizeVersion(String v) {
    final t = v.trim();
    if (t.isEmpty) return '0.0.0';
    return t.startsWith('v') || t.startsWith('V') ? t.substring(1) : t;
  }

  static int _compareVersion(String a, String b) {
    final pa = a
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final pb = b
        .split('.')
        .map((e) => int.tryParse(e.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
        .toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final av = i < pa.length ? pa[i] : 0;
      final bv = i < pb.length ? pb[i] : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }
}
