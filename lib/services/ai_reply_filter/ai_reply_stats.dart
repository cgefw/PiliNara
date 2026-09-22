import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';

class AiVideoStat {
  AiVideoStat({
    required this.oid,
    this.title,
    this.tags = const [],
    this.total = 0,
    this.unsafe = 0,
    required this.ts,
  });

  final int oid;
  String? title;
  List<String> tags;
  int total;
  int unsafe;
  int ts;

  double get ratio => total == 0 ? 0 : unsafe / total;

  Map<String, dynamic> toJson() => {
    'title': title,
    'tags': tags,
    'total': total,
    'unsafe': unsafe,
    'ts': ts,
  };

  factory AiVideoStat.fromJson(int oid, Map<String, dynamic> json) =>
      AiVideoStat(
        oid: oid,
        title: json['title']?.toString(),
        tags: (json['tags'] as List?)
                ?.map((e) => e.toString())
                .where((e) => e.isNotEmpty)
                .take(AiReplyStats._maxTagsPerVideo)
                .toList() ??
            const [],
        total: (json['total'] as num?)?.toInt() ?? 0,
        unsafe: (json['unsafe'] as num?)?.toInt() ?? 0,
        ts: (json['ts'] as num?)?.toInt() ?? 0,
      );
}

class AiTagStat {
  const AiTagStat({
    required this.tag,
    required this.videoCount,
    required this.sampleCount,
    required this.unsafeCount,
    required this.avgRatio,
  });

  final String tag;
  final int videoCount;
  final int sampleCount;
  final int unsafeCount;
  final double avgRatio;
}

class AiReplyStats {
  AiReplyStats._();

  static final AiReplyStats instance = AiReplyStats._();

  static const int _maxVideos = 3000;
  static const int _maxTagsPerVideo = 10;
  static const int _maxTagLength = 30;

  final RxInt revision = 0.obs;

  final Map<int, AiVideoStat> _videos = {};

  bool _loaded = false;
  bool _persistScheduled = false;

  void init() {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = GStorage.localCache.get(LocalCacheKey.aiReplyStats);
      if (raw is! String || raw.isEmpty) return;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final videos = decoded['videos'];
      if (videos is Map) {
        videos.forEach((key, value) {
          final oid = int.tryParse(key.toString());
          if (oid == null || value is! Map) return;
          _videos[oid] = AiVideoStat.fromJson(
            oid,
            Map<String, dynamic>.from(value),
          );
        });
      }
    } catch (e) {
      logger.e('AI 争议统计加载失败', error: e);
    }
  }

  int get videoCount => _videos.length;

  int get commentCount =>
      _videos.values.fold(0, (sum, video) => sum + video.total);

  int get unsafeCount =>
      _videos.values.fold(0, (sum, video) => sum + video.unsafe);

  void registerVideo(int oid, {String? title, List<String>? tags}) {
    if (oid == 0 || !Pref.enableAiReplyStats) return;
    final safeTags = _sanitizeTags(tags);
    final stat = _videos[oid];
    if (stat == null) {
      if ((title == null || title.isEmpty) && safeTags == null) return;
      _videos[oid] = AiVideoStat(
        oid: oid,
        title: title,
        tags: safeTags ?? const [],
        ts: DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      if (title != null && title.isNotEmpty) stat.title = title;
      if (safeTags != null && safeTags.isNotEmpty) stat.tags = safeTags;
    }
    _schedulePersist();
    revision.value++;
  }

  void record(
    int oid, {
    required bool unsafe,
    String? title,
    List<String>? tags,
  }) {
    if (oid == 0 || !Pref.enableAiReplyStats) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var stat = _videos[oid];
    if (stat == null) {
      stat = AiVideoStat(
        oid: oid,
        title: title,
        tags: _sanitizeTags(tags) ?? const [],
        ts: now,
      );
      _videos[oid] = stat;
    } else {
      if ((stat.title == null || stat.title!.isEmpty) && title != null) {
        stat.title = title;
      }
      if (stat.tags.isEmpty) {
        final safeTags = _sanitizeTags(tags);
        if (safeTags != null) stat.tags = safeTags;
      }
    }
    stat.total++;
    if (unsafe) stat.unsafe++;
    stat.ts = now;
    _trim();
    _schedulePersist();
    revision.value++;
  }

  List<AiTagStat> tagStats({int minVideoSamples = 10, int minVideos = 3}) {
    final byTag = <String, List<AiVideoStat>>{};
    for (final video in _videos.values) {
      if (video.total < minVideoSamples) continue;
      for (final tag in video.tags) {
        (byTag[tag] ??= []).add(video);
      }
    }
    final result = <AiTagStat>[];
    byTag.forEach((tag, videos) {
      if (videos.length < minVideos) return;
      var ratioSum = 0.0;
      var samples = 0;
      var unsafe = 0;
      for (final video in videos) {
        ratioSum += video.ratio;
        samples += video.total;
        unsafe += video.unsafe;
      }
      result.add(
        AiTagStat(
          tag: tag,
          videoCount: videos.length,
          sampleCount: samples,
          unsafeCount: unsafe,
          avgRatio: ratioSum / videos.length,
        ),
      );
    });
    result.sort((a, b) => b.avgRatio.compareTo(a.avgRatio));
    return result;
  }

  List<AiVideoStat> videosOfTag(String tag, {int minVideoSamples = 10}) {
    final list = _videos.values
        .where((video) => video.total >= minVideoSamples && video.tags.contains(tag))
        .toList()
      ..sort((a, b) => b.ratio.compareTo(a.ratio));
    return list;
  }

  Future<void> clear() async {
    _videos.clear();
    revision.value++;
    try {
      await GStorage.localCache.delete(LocalCacheKey.aiReplyStats);
    } catch (e) {
      logger.e('AI 争议统计清除失败', error: e);
    }
  }

  List<String>? _sanitizeTags(List<String>? tags) {
    if (tags == null) return null;
    final result = <String>[];
    for (final tag in tags) {
      final text = tag.trim().replaceAll(RegExp(r'\s+'), ' ');
      if (text.isEmpty) continue;
      final value = text.length > _maxTagLength
          ? text.substring(0, _maxTagLength)
          : text;
      if (!result.contains(value)) result.add(value);
      if (result.length >= _maxTagsPerVideo) break;
    }
    return result.isEmpty ? null : result;
  }

  void _trim() {
    if (_videos.length <= _maxVideos) return;
    final entries = _videos.values.toList()
      ..sort((a, b) => a.ts.compareTo(b.ts));
    final removeCount = _videos.length - _maxVideos;
    for (var i = 0; i < removeCount; i++) {
      _videos.remove(entries[i].oid);
    }
  }

  void _schedulePersist() {
    if (_persistScheduled) return;
    _persistScheduled = true;
    Timer(const Duration(seconds: 2), () {
      _persistScheduled = false;
      _persist();
    });
  }

  void _persist() {
    try {
      GStorage.localCache.put(
        LocalCacheKey.aiReplyStats,
        jsonEncode({
          'videos': {
            for (final entry in _videos.entries)
              entry.key.toString(): entry.value.toJson(),
          },
        }),
      );
    } catch (e) {
      logger.e('AI 争议统计保存失败', error: e);
    }
  }
}
