import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';

class AiReplyVerdict {
  const AiReplyVerdict({required this.unsafe, this.reason = ''});

  final bool unsafe;
  final String reason;
}

class AiReplyFilterService {
  AiReplyFilterService._();

  static final AiReplyFilterService instance = AiReplyFilterService._();

  static const int _batchSize = 20;
  static const int _maxConcurrent = 3;
  static const int _maxCacheEntries = 1500;
  static const int _maxRetryEntries = 200;
  static const int _maxTextLength = 500;
  static const int _maxReasonLength = 30;
  static const Duration _debounce = Duration(milliseconds: 350);
  static const Duration _retryCooldown = Duration(seconds: 60);

  static const String defaultSystemPrompt =
      '你是视频评论区的内容审查助手，负责判断一条评论是否会让普通浏览者感到不适。\n'
      '以下内容属于「令人不适」，需要过滤：\n'
      '1. 辱骂、人身攻击、诅咒、威胁、挑衅；\n'
      '2. 地域、性别、种族、职业、外貌、IP 属地等歧视与仇恨言论；\n'
      '3. 阴阳怪气、引战、恶意嘲讽、反讽贬低、抬杠、挑动对立，'
      '包括拿 IP 属地、地域说事的攻击与阴阳；\n'
      '4. 说教、居高临下地教训或指点他人、爹味发言；\n'
      '5. 隐含贬义、含沙射影、指桑骂槐、暗讽等不明显的贬低；\n'
      '6. 色情低俗、性暗示、荤段子；\n'
      '7. 血腥、暴力、恐怖、恶心、猎奇等引起生理不适的内容；\n'
      '8. 广告推广、诈骗、违法与垃圾信息；\n'
      '9. 其他让普通人明显反感、不适的内容。\n'
      '注意：正常的批评、吐槽、负面评价、不同观点、玩梗不属于令人不适，不要误判；'
      '但说教、隐含贬义、引战（含 IP 属地引战）都要判定为令人不适。';

  final RxMap<String, AiReplyVerdict> verdicts =
      <String, AiReplyVerdict>{}.obs;

  final RxMap<String, bool> revealed = <String, bool>{}.obs;

  final RxMap<String, bool> allowed = <String, bool>{}.obs;

  final Map<String, String> _pending = {};

  final Set<String> _inFlight = {};

  final Map<String, DateTime> _failedAt = {};

  final Map<String, String> _retryTexts = {};

  final Map<String, List<Object?>> _cache = {};

  Timer? _timer;

  Timer? _retryTimer;

  Duration _retryDelay = _retryCooldown;

  int _batchesInFlight = 0;

  bool _persistScheduled = false;

  static bool get enabled => Pref.enableAiReplyFilter && apiReady;

  static bool get apiReady =>
      Pref.aiApiUrl.trim().isNotEmpty && Pref.aiModel.trim().isNotEmpty;

  int get cacheCount => verdicts.length;

  static String normalize(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String contentHash(String text) =>
      md5.convert(utf8.encode(normalize(text).toLowerCase())).toString();

  static String criteriaFingerprint([String criteria = '']) =>
      md5.convert(utf8.encode('$defaultSystemPrompt\n$criteria')).toString();

  static String _truncate(String text) =>
      text.length > _maxTextLength ? text.substring(0, _maxTextLength) : text;

  static (String, String) buildPrompt(
    List<String> texts, {
    String criteria = '',
  }) {
    final extra = criteria.trim();
    final system = extra.isEmpty
        ? defaultSystemPrompt
        : '$defaultSystemPrompt\n'
              '额外过滤标准（用户自定义，优先遵守）：$extra';
    final payload = jsonEncode([
      for (var i = 0; i < texts.length; i++) {'i': i, 'text': texts[i]},
    ]);
    final user =
        '请逐条审查下面 JSON 数组中的评论，严格只输出一个 JSON 数组，'
        '不要输出任何其他文字。\n'
        '输出元素格式：{"i":评论编号,"u":是否令人不适,"r":"原因"}；'
        'i 必须等于输入中的编号，u 为布尔值，'
        'r 为不超过 10 字的原因（不令人不适时留空字符串）。\n'
        '必须审查每一条评论并逐一输出结果，不要遗漏。\n'
        '待审查评论（JSON 数组，i 为编号）：$payload';
    return (system, user);
  }

  @visibleForTesting
  static Map<int, AiReplyVerdict> parseVerdicts(String raw, int count) {
    var text = raw.trim();
    if (text.startsWith('```')) {
      text = text
          .replaceAll(RegExp(r'^```[a-zA-Z]*\s*'), '')
          .replaceAll(RegExp(r'```\s*$'), '')
          .trim();
    }
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end <= start) return const {};
    dynamic decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } catch (_) {
      return const {};
    }
    if (decoded is! List) return const {};
    final zeroBased = <int, AiReplyVerdict>{};
    final oneBased = <int, AiReplyVerdict>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final index = switch (item['i'] ?? item['index'] ?? item['id']) {
        final int value => value,
        final num value => value.toInt(),
        final String value => int.tryParse(value) ?? -9999,
        _ => -9999,
      };
      final rawUnsafe = item['u'] ?? item['unsafe'];
      final unsafe =
          rawUnsafe == true ||
          rawUnsafe == 1 ||
          rawUnsafe == 'true' ||
          rawUnsafe == '1';
      var reason = (item['r'] ?? item['reason'] ?? '').toString().trim();
      if (reason.length > _maxReasonLength) {
        reason = reason.substring(0, _maxReasonLength);
      }
      final verdict = AiReplyVerdict(unsafe: unsafe, reason: reason);
      if (index >= 0 && index < count) {
        zeroBased[index] = verdict;
      }
      if (index >= 1 && index <= count) {
        oneBased[index - 1] = verdict;
      }
    }
    if (zeroBased.length >= oneBased.length) return zeroBased;
    return oneBased;
  }

  void init() {
    try {
      final raw = GStorage.localCache.get(LocalCacheKey.aiReplyFilterCache);
      if (raw is! String || raw.isEmpty) return;
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final allowList = decoded['allow'];
      if (allowList is List) {
        for (final hash in allowList) {
          if (hash is String) allowed[hash] = true;
        }
      }
      final items = decoded['items'];
      if (items is Map) {
        final fingerprint = criteriaFingerprint(Pref.aiReplyFilterCriteria);
        items.forEach((key, value) {
          if (key is! String || value is! List || value.length < 4) return;
          if (value[3]?.toString() != fingerprint) return;
          final unsafe = value[0] == 1 || value[0] == true;
          final reason = value[1]?.toString() ?? '';
          verdicts[key] = AiReplyVerdict(unsafe: unsafe, reason: reason);
          _cache[key] = List<Object?>.from(value);
        });
      }
    } catch (e) {
      logger.e('AI 评论过滤缓存加载失败', error: e);
    }
  }

  AiReplyVerdict? verdictOfHash(String hash) {
    if (allowed.containsKey(hash)) return null;
    return verdicts[hash];
  }

  bool isFailed(String hash) => _failedAt.containsKey(hash);

  bool isRevealed(String hash) =>
      revealed.containsKey(hash) || allowed.containsKey(hash);

  void track(String text) {
    if (!enabled) return;
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    trackHash(contentHash(trimmed), trimmed);
  }

  void trackAll(Iterable<String> texts) {
    if (!enabled) return;
    for (final text in texts) {
      track(text);
    }
  }

  void trackHash(String hash, String text) {
    if (verdicts.containsKey(hash) || allowed.containsKey(hash)) return;
    if (_pending.containsKey(hash) || _inFlight.contains(hash)) return;
    final failedAt = _failedAt[hash];
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < _retryCooldown) {
      return;
    }
    _pending[hash] = _truncate(normalize(text));
    if (!(_timer?.isActive ?? false)) {
      _timer = Timer(_debounce, _pump);
    }
  }

  void reveal(String hash) {
    revealed[hash] = true;
  }

  void allowForever(String hash) {
    allowed[hash] = true;
    revealed.remove(hash);
    verdicts.remove(hash);
    _cache.remove(hash);
    _schedulePersist();
  }

  void onCriteriaChanged() {
    verdicts.clear();
    _cache.clear();
    _pending.clear();
    _retryTexts.clear();
    _failedAt.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryDelay = _retryCooldown;
    _schedulePersist();
  }

  Future<void> clearCache() async {
    verdicts.clear();
    _cache.clear();
    _failedAt.clear();
    _retryTexts.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryDelay = _retryCooldown;
    try {
      await GStorage.localCache.delete(LocalCacheKey.aiReplyFilterCache);
      _persist();
    } catch (e) {
      logger.e('AI 评论过滤缓存清除失败', error: e);
    }
  }

  @visibleForTesting
  Future<Map<int, AiReplyVerdict>> classifyTexts(
    List<String> texts, {
    String? criteria,
  }) async {
    final (system, user) = buildPrompt(
      texts,
      criteria: criteria ?? Pref.aiReplyFilterCriteria,
    );
    final content = await AiChatService.completeChat(
      messages: [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      receiveTimeout: const Duration(seconds: 30),
    );
    return parseVerdicts(content, texts.length);
  }

  Future<AiReplyVerdict?> checkNow(String text) async {
    final normalized = normalize(text);
    if (normalized.isEmpty) return null;
    final results = await classifyTexts([_truncate(normalized)]);
    return results[0];
  }

  void _pump() {
    _timer = null;
    if (!enabled) {
      _pending.clear();
      return;
    }
    while (_batchesInFlight < _maxConcurrent && _pending.isNotEmpty) {
      _startBatch();
    }
  }

  void _startBatch() {
    final batch = _pending.entries.take(_batchSize).toList();
    if (batch.isEmpty) return;
    for (final entry in batch) {
      _pending.remove(entry.key);
      _inFlight.add(entry.key);
    }
    _batchesInFlight++;
    _runBatch(batch, DateTime.now());
  }

  Future<void> _runBatch(
    List<MapEntry<String, String>> batch,
    DateTime now,
  ) async {
    var success = false;
    var hasMissing = false;
    try {
      final results = await classifyTexts(
        batch.map((e) => e.value).toList(),
      );
      success = true;
      _retryDelay = _retryCooldown;
      final fingerprint = criteriaFingerprint(Pref.aiReplyFilterCriteria);
      final timestamp = now.millisecondsSinceEpoch;
      for (var i = 0; i < batch.length; i++) {
        final hash = batch[i].key;
        final verdict = results[i];
        if (verdict == null) {
          hasMissing = true;
          _failedAt[hash] = now;
          _queueRetry(hash, batch[i].value);
          continue;
        }
        verdicts[hash] = verdict;
        _failedAt.remove(hash);
        _retryTexts.remove(hash);
        _cache[hash] = [
          verdict.unsafe ? 1 : 0,
          verdict.reason,
          timestamp,
          fingerprint,
        ];
      }
      _trimCache();
      _schedulePersist();
    } catch (e, s) {
      logger.e('AI 评论过滤请求失败', error: e, stackTrace: s);
      for (final entry in batch) {
        _failedAt[entry.key] = now;
        _queueRetry(entry.key, entry.value);
      }
    } finally {
      for (final entry in batch) {
        _inFlight.remove(entry.key);
      }
      _batchesInFlight--;
      if (hasMissing || !success) {
        _scheduleRetry();
      }
      _pump();
    }
  }

  void _queueRetry(String hash, String text) {
    if (_retryTexts.length >= _maxRetryEntries &&
        !_retryTexts.containsKey(hash)) {
      _retryTexts.remove(_retryTexts.keys.first);
    }
    _retryTexts[hash] = text;
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) return;
    _retryTimer = Timer(_retryDelay, () {
      _retryTimer = null;
      if (!enabled) {
        _retryTexts.clear();
        return;
      }
      for (final entry in _retryTexts.entries) {
        if (verdicts.containsKey(entry.key) ||
            allowed.containsKey(entry.key)) {
          continue;
        }
        _failedAt.remove(entry.key);
        _pending[entry.key] = entry.value;
      }
      _retryTexts.clear();
      if (!(_timer?.isActive ?? false)) {
        _timer = Timer(Duration.zero, _pump);
      }
    });
    final next = _retryDelay * 2;
    _retryDelay = next > const Duration(minutes: 10)
        ? const Duration(minutes: 10)
        : next;
  }

  Future<AiReplyVerdict?> recheck(String text) async {
    final normalized = normalize(text);
    if (normalized.isEmpty) return null;
    final hash = contentHash(normalized);
    final results = await classifyTexts([_truncate(normalized)]);
    final verdict = results[0];
    if (verdict == null) return null;
    allowed.remove(hash);
    revealed.remove(hash);
    verdicts[hash] = verdict;
    _failedAt.remove(hash);
    _retryTexts.remove(hash);
    _cache[hash] = [
      verdict.unsafe ? 1 : 0,
      verdict.reason,
      DateTime.now().millisecondsSinceEpoch,
      criteriaFingerprint(Pref.aiReplyFilterCriteria),
    ];
    _trimCache();
    _schedulePersist();
    return verdict;
  }

  void _trimCache() {
    if (_cache.length <= _maxCacheEntries) return;
    final entries = _cache.entries.toList()
      ..sort(
        (a, b) => (a.value[2] as int? ?? 0).compareTo(b.value[2] as int? ?? 0),
      );
    final removeCount = _cache.length - _maxCacheEntries;
    for (var i = 0; i < removeCount; i++) {
      _cache.remove(entries[i].key);
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
        LocalCacheKey.aiReplyFilterCache,
        jsonEncode({
          'allow': allowed.keys.toList(),
          'items': _cache,
        }),
      );
    } catch (e) {
      logger.e('AI 评论过滤缓存保存失败', error: e);
    }
  }
}
