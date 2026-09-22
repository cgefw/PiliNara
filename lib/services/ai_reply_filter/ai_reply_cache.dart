import 'package:PiliPlus/services/ai_reply_filter/ai_reply_protocol.dart';

/// One bounded LRU shared by configuration namespaces. Reading refreshes recency.
class AiReplyCache {
  AiReplyCache({this.capacity = 1500}) : assert(capacity > 0);
  final int capacity;
  final _entries = <(String, String), AiReplyVerdict>{};
  (String, String)? _newest;
  int _revision = 0;
  int get revision => _revision;
  int get length => _entries.length;

  AiReplyVerdict? get(String fingerprint, String key) {
    final id = (fingerprint, key);
    final result = _entries[id];
    if (result != null && id != _newest) {
      _entries.remove(id);
      _entries[id] = result;
      _newest = id;
      _revision++;
    }
    return result;
  }

  void put(String fingerprint, String key, AiReplyVerdict verdict) {
    final id = (fingerprint, key);
    _entries.remove(id);
    _entries[id] = verdict;
    _newest = id;
    _revision++;
    while (_entries.length > capacity) {
      _entries.remove(_entries.keys.first);
    }
  }

  Map<String, AiReplyVerdict> active(String fingerprint) => {
    for (final entry in _entries.entries)
      if (entry.key.$1 == fingerprint) entry.key.$2: entry.value,
  };

  void remove(String fingerprint, String key) {
    final id = (fingerprint, key);
    if (_entries.remove(id) == null) return;
    if (_newest == id) _newest = null;
    _revision++;
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    _newest = null;
    _revision++;
  }

  List<List<Object>> toJson() => [
    for (final entry in _entries.entries)
      [
        entry.key.$1,
        entry.key.$2,
        entry.value.unsafe ? 1 : 0,
        entry.value.reason,
      ],
  ];

  void restore(Map decoded) {
    final entries = decoded['entries'];
    if (entries is List) {
      for (final entry in entries) {
        if (entry is! List ||
            entry.length != 4 ||
            entry[0] is! String ||
            entry[1] is! String ||
            (entry[2] != 0 && entry[2] != 1) ||
            entry[3] is! String) {
          continue;
        }
        put(
          entry[0] as String,
          entry[1] as String,
          AiReplyVerdict(unsafe: entry[2] == 1, reason: entry[3] as String),
        );
      }
      return;
    }
    final items = decoded['items'];
    if (items is! Map) return;
    final legacy =
        items.entries
            .where(
              (e) =>
                  e.key is String &&
                  e.value is List &&
                  (e.value as List).length >= 4 &&
                  (e.value as List)[2] is int,
            )
            .toList()
          ..sort(
            (a, b) => ((a.value as List)[2] as int? ?? 0).compareTo(
              (b.value as List)[2] as int? ?? 0,
            ),
          );
    for (final entry in legacy) {
      final value = entry.value as List;
      if (value[3] is! String ||
          (value[0] != 0 && value[0] != 1 && value[0] is! bool)) {
        continue;
      }
      put(
        value[3] as String,
        entry.key as String,
        AiReplyVerdict(
          unsafe: value[0] == 1 || value[0] == true,
          reason: value[1]?.toString() ?? '',
        ),
      );
    }
  }
}
