class IptvChannel {
  final String name;
  final String url;
  final String category;
  final String logo;
  final String country;
  final String language;
  final String source;

  const IptvChannel({
    required this.name,
    required this.url,
    required this.category,
    this.logo = '',
    this.country = '',
    this.language = '',
    this.source = '',
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'category': category,
        'logo': logo,
        'country': country,
        'language': language,
        'source': source,
      };

  factory IptvChannel.fromJson(Map<String, dynamic> json) => IptvChannel(
        name: (json['name'] ?? '').toString(),
        url: (json['url'] ?? '').toString(),
        category: (json['category'] ?? 'Разное').toString(),
        logo: (json['logo'] ?? '').toString(),
        country: (json['country'] ?? '').toString(),
        language: (json['language'] ?? '').toString(),
        source: (json['source'] ?? '').toString(),
      );

  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        category.toLowerCase().contains(q) ||
        country.toLowerCase().contains(q) ||
        language.toLowerCase().contains(q);
  }
}
