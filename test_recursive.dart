void main() {
    final Map<String, dynamic> map = {
        "richItemRenderer": {
            "content": {
                "videoRenderer": {
                    "videoId": "12345",
                    "title": {"runs": [{"text": "Hello"}]}
                }
            }
        }
    };
    int videos = 0;
    void searchTree(dynamic node) {
      if (node == null) return;
      if (node is List) {
        for (var item in node) {
          searchTree(item);
        }
        return;
      }
      if (node is Map) {
        final m = node as Map<String, dynamic>;
        final renderer = m['gridVideoRenderer'] ?? m['videoRenderer'] ?? m['compactVideoRenderer'] ?? m['reelItemRenderer'];
        if (renderer != null && renderer is Map<String, dynamic>) {
            final videoId = renderer['videoId']?.toString();
            if (videoId != null && videoId.isNotEmpty) {
                videos++;
            }
        }
        m.values.forEach(searchTree);
      }
    }
    searchTree(map);
    print('Found $videos videos');
}
