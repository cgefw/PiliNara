import 'dart:async';
import 'dart:convert';

import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/services/ai_chat/ai_chat_protocol.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_cache.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_api_policy.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_protocol.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_stats.dart';
import 'package:PiliPlus/services/logger.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';

export 'package:PiliPlus/services/ai_reply_filter/ai_reply_protocol.dart'
    show AiReplyVerdict;

export 'package:PiliPlus/services/ai_reply_filter/ai_reply_api_policy.dart'
    show AiThinkingParam;

typedef AiReplyCompletion = Future<String> Function(
  List<Map<String, String>> messages,
  Map<String, dynamic>? body,
  CancelToken token,
);

class _PendingComment {
  const _PendingComment({
    required this.text,
    this.oid,
    this.type = 1,
  });

  final int type;
  final String text;
  final int? oid;
}

class _VideoMeta {
  const _VideoMeta({this.title, this.tags});

  final String? title;
  final List<String>? tags;
}

class AiReplyFilterService {
  AiReplyFilterService._() : _cache = AiReplyCache();

  @visibleForTesting
  AiReplyFilterService.forTesting(this._completion, {int cacheCapacity = 1500})
    : _cache = AiReplyCache(capacity: cacheCapacity);

  AiReplyCompletion? _completion;
  final Set<CancelToken> _tokens = {};
  final Set<String> _urgent = {};
  final Map<String, Set<String>> _sampleIds = {};
  final Map<String, int> _versions = {};
  final Map<String, int> _attempts = {};
  final RxInt revision = 0.obs;
  StreamSubscription<dynamic>? _settingsSubscription;
  String? _activeFingerprint;
  String? _credentialFingerprint;
  int _generation = 0;

  static final AiReplyFilterService instance = AiReplyFilterService._();

  static const int _maxRetryEntries = 200;
  static const int _maxTextLength = 500;
  static const int _maxTitleLength = 80;
  static const int _maxTagLength = 30;
  static const int _maxTags = 10;
  static const int _maxVideoMeta = 500;
  static const int _prefetchLimit = 20;
  static const Duration _debounce = Duration(milliseconds: 50);
  static const Duration _retryCooldown = Duration(seconds: 60);

  static const String defaultSystemPrompt = AiReplyProtocol.systemPrompt;
  static const String defaultUserPrompt = AiReplyProtocol.userPrompt;

  final RxMap<String, AiReplyVerdict> verdicts = <String, AiReplyVerdict>{}.obs;

  final RxMap<String, bool> revealed = <String, bool>{}.obs;

  final RxMap<String, bool> allowed = <String, bool>{}.obs;

  final Map<String, _PendingComment> _pending = {};

  final Map<String, CancelToken> _inFlight = {};
  final Map<String, Future<AiReplyVerdict?>> _manualRequests = {};
  final RxnInt blockedStatus = RxnInt();

  final RxMap<String, DateTime> _failedAt = <String, DateTime>{}.obs;

  final Map<String, _PendingComment> _retryTexts = {};

  final AiReplyCache _cache;
  final RxInt metricsRevision = 0.obs;
  int localHits = 0, localMisses = 0, inFlightReuses = 0;
  int reportedRequests = 0, cachedInputTokens = 0, measuredInputTokens = 0;
  int inputTokens = 0, outputTokens = 0;
  int get totalCacheCount => _cache.length;
  double? get localHitRate => localHits + localMisses + inFlightReuses == 0
      ? null
      : localHits / (localHits + localMisses + inFlightReuses);
  double? get providerHitRate =>
      measuredInputTokens == 0 ? null : cachedInputTokens / measuredInputTokens;

  void _resetMetrics() {
    localHits = localMisses = inFlightReuses = 0;
    reportedRequests = cachedInputTokens = measuredInputTokens = inputTokens =
        outputTokens = 0;
    metricsRevision.value++;
  }

  void _recordUsage(AiTokenUsage usage) {
    inputTokens += usage.input ?? 0;
    outputTokens += usage.output ?? 0;
    if (usage.cached != null && usage.input != null) {
      reportedRequests++;
      measuredInputTokens += usage.input!;
      cachedInputTokens += usage.cached!;
    }
    metricsRevision.value++;
  }

  void _touchCache(String key) {
    final before = _cache.revision;
    _cache.get(_activeFingerprint ?? _fingerprint, key);
    if (_cache.revision != before) {
      _schedulePersist(recencyOnly: true);
    }
  }

  void _activateCache() =>
      verdicts.assignAll(_cache.active(_activeFingerprint ?? _fingerprint));

  final Map<(int, int), _VideoMeta> _videoMeta = {};

  Timer? _timer;

  Timer? _retryTimer;

  Duration _retryDelay = _retryCooldown;

  int _batchesInFlight = 0;

  Timer? _persistTimer;
  bool _persistRecencyOnly = false;

  static bool get enabled => Pref.enableAiReplyFilter && apiReady;

  static bool get apiReady =>
      Pref.aiApiUrl.trim().isNotEmpty && Pref.aiModel.trim().isNotEmpty;

  int get _batchSize => Pref.aiReplyFilterBatchSize.clamp(5, 50);

  int get _maxConcurrent => Pref.aiReplyFilterConcurrency.clamp(1, 8);

  static int get prefetchLimit => _prefetchLimit;

  int get cacheCount => verdicts.length;

  String get _systemTemplate {
    final custom = Pref.aiReplyFilterSystemPrompt.trim();
    return custom.isEmpty ? defaultSystemPrompt : custom;
  }

  String get _userTemplate {
    final custom = Pref.aiReplyFilterUserPrompt.trim();
    return AiReplyProtocol.resolveUserTemplate(custom);
  }

  AiReplyApiPolicy get apiPolicy => AiReplyApiPolicy(
    url: Pref.aiApiUrl,
    model: Pref.aiModel,
    thinking: Pref.enableAiReplyFilterThinking,
    param: Pref.aiReplyFilterThinkingParam,
    compact: AiReplyProtocol.isCompactTemplate(_userTemplate),
  );

  String get _fingerprint => fingerprintOf(
    buildSystemPrompt(_systemTemplate, Pref.aiReplyFilterCriteria),
    jsonEncode([
      _userTemplate,
      'comment-only-codes-v1',
      AiReplyApiPolicy.normalizeUrl(Pref.aiApiUrl),
      Pref.aiModel.trim(),
      apiPolicy.body,
      apiPolicy.useStreaming,
    ]),
  );

  static String normalize(String text) => AiReplyProtocol.normalize(text);
  static String contentHash(String text) => AiReplyProtocol.hash(text);
  static String fingerprintOf(String system, String user) =>
      AiReplyProtocol.fingerprint(system, user);

  String keyFor(String text, {int? oid, int type = 1}) =>
      '$type:${oid ?? 0}:${contentHash(text)}';

  void refreshSettings() {
    final fingerprint = _fingerprint;
    final credential = fingerprintOf('credential', Pref.aiApiKey);
    final credentialChanged = credential != _credentialFingerprint;
    _credentialFingerprint = credential;
    if (_activeFingerprint != fingerprint) {
      onCriteriaChanged();
    } else if (!enabled || credentialChanged) {
      // A key change can repair authentication without changing classification.
      _invalidateRequests();
    }
    revision.value++;
  }

  static String buildSystemPrompt(String base, String criteria) {
    final extra = criteria.trim();
    if (extra.isEmpty) return base;
    return '$base\n额外过滤标准（用户自定义，优先遵守）：$extra';
  }

  static String buildUserPrompt(
    String template, {
    required List<String> texts,
  }) => AiReplyProtocol.buildUserPrompt(
    template,
    texts: texts,
    compact: AiReplyProtocol.isCompactTemplate(template),
  );

  static Map<String, dynamic>? buildThinkingParams(bool enabled, int param) =>
      AiReplyApiPolicy.thinkingBody(enabled, param);

  static String? _sanitize(String? value, int maxLength) {
    final text = value == null ? '' : normalize(value);
    if (text.isEmpty) return null;
    return text.length > maxLength ? text.substring(0, maxLength) : text;
  }

  static String _truncate(String text) =>
      AiReplyProtocol.truncate(text, _maxTextLength);

  @visibleForTesting
  static Map<int, AiReplyVerdict> parseVerdicts(String raw, int count) =>
      AiReplyProtocol.parse(raw, count);

  void init() {
    AiReplyStats.instance.init();
    _activeFingerprint = _fingerprint;
    _credentialFingerprint = fingerprintOf('credential', Pref.aiApiKey);
    AiReplyStats.instance.useFingerprint(_activeFingerprint!);
    _settingsSubscription ??= GStorage.setting.watch().listen((event) {
      if (event.key.toString().startsWith('ai') ||
          event.key.toString().startsWith('enableAi')) {
        refreshSettings();
      }
    });
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
      _cache.restore(decoded);
      _activateCache();
    } catch (e) {
      logger.e('AI 评论过滤缓存加载失败', error: e);
    }
  }

  AiReplyVerdict? verdictOfHash(String hash) {
    if (allowed.containsKey(hash)) return null;
    final verdict = verdicts[hash];
    if (verdict != null) _touchCache(hash);
    return verdict;
  }

  bool isFailed(String hash) =>
      blockedStatus.value != null || _failedAt.containsKey(hash);

  bool _isAllowed(String hash, String? text) =>
      allowed.containsKey(hash) ||
      (text != null &&
          allowed.containsKey(contentHash(normalize(text).toLowerCase())));

  bool isRevealed(String hash, {String? text}) =>
      revealed.containsKey(hash) || _isAllowed(hash, text);

  void track(
    String text, {
    int? oid,
    int type = 1,
    String? sampleId,
    bool priority = false,
  }) {
    if (!enabled || text.trim().isEmpty) return;
    trackHash(
      keyFor(text, oid: oid, type: type),
      text,
      oid: oid,
      type: type,
      sampleId: sampleId,
      priority: priority,
      countLookup: true,
    );
  }

  void trackAll(Iterable<String> texts, {int? oid, int type = 1}) {
    for (final text in texts) {
      track(text, oid: oid, type: type);
    }
    flush();
  }

  void flush() {
    _timer?.cancel();
    _pump();
  }

  void trackHash(
    String hash,
    String text, {
    int? oid,
    int type = 1,
    String? sampleId,
    bool priority = false,
    bool countLookup = false,
  }) {
    if (!enabled || text.trim().isEmpty || _isAllowed(hash, text)) return;
    final cached = verdicts[hash];
    if (cached != null) {
      _touchCache(hash);
      if (countLookup) {
        localHits++;
        metricsRevision.value++;
      }
      _recordSample(oid, type, sampleId ?? contentHash(text), cached);
      return;
    }
    if (blockedStatus.value != null) return;
    if (countLookup && !_failedAt.containsKey(hash)) {
      if (_pending.containsKey(hash) || _inFlight.containsKey(hash)) {
        inFlightReuses++;
      } else {
        localMisses++;
      }
      metricsRevision.value++;
    }
    if (oid != null && type == 1) {
      (_sampleIds[hash] ??= {}).add(sampleId ?? contentHash(text));
    }
    if (priority) _urgent.add(hash);
    if (_pending.containsKey(hash) ||
        _inFlight.containsKey(hash) ||
        _failedAt.containsKey(hash)) {
      return;
    }
    _pending[hash] = _PendingComment(
      text: _truncate(normalize(text)),
      oid: oid,
      type: type,
    );
    if (!(_timer?.isActive ?? false)) _timer = Timer(_debounce, _pump);
  }

  void _recordSample(
    int? oid,
    int type,
    String sampleId,
    AiReplyVerdict verdict,
  ) {
    if (oid == null || type != 1) return;
    final meta = _videoMeta[(type, oid)];
    AiReplyStats.instance.record(
      oid,
      sampleId: sampleId,
      unsafe: verdict.unsafe,
      title: meta?.title,
      tags: meta?.tags,
    );
  }

  void registerVideo(
    int oid, {
    int type = 1,
    String? title,
    List<String>? tags,
  }) {
    if (oid == 0) return;
    final existing = _videoMeta[(type, oid)];
    final meta = _VideoMeta(
      title: _sanitize(title, _maxTitleLength) ?? existing?.title,
      tags: _sanitizeTags(tags) ?? existing?.tags,
    );
    _videoMeta[(type, oid)] = meta;
    if (_videoMeta.length > _maxVideoMeta) {
      _videoMeta.remove(_videoMeta.keys.first);
    }
    if (type == 1) {
      AiReplyStats.instance.registerVideo(
        oid,
        title: meta.title,
        tags: meta.tags,
      );
    }
  }

  static List<String>? _sanitizeTags(List<String>? tags) {
    if (tags == null) return null;
    final result = <String>[];
    for (final tag in tags) {
      final text = normalize(tag);
      if (text.isEmpty) continue;
      final value = text.length > _maxTagLength
          ? text.substring(0, _maxTagLength)
          : text;
      if (!result.contains(value)) result.add(value);
      if (result.length >= _maxTags) break;
    }
    return result.isEmpty ? null : result;
  }

  void reveal(String hash) {
    revealed[hash] = true;
  }

  void allowForever(String hash) {
    allowed[hash] = true;
    _versions[hash] = (_versions[hash] ?? 0) + 1;
    _pending.remove(hash);
    _urgent.remove(hash);
    _sampleIds.remove(hash);
    _retryTexts.remove(hash);
    _failedAt.remove(hash);
    revealed.remove(hash);
    verdicts.remove(hash);
    _cache.remove(_activeFingerprint ?? _fingerprint, hash);
    _schedulePersist();
  }

  void _invalidateRequests() {
    _generation++;
    for (final token in _tokens.toList()) {
      token.cancel('filter settings changed');
    }
    _tokens.clear();
    _batchesInFlight = 0;
    _manualRequests.clear();
    _versions.clear();
    blockedStatus.value = null;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
    _inFlight.clear();
    _urgent.clear();
    _sampleIds.clear();
    _retryTexts.clear();
    _attempts.clear();
    _failedAt.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _retryDelay = _retryCooldown;
  }

  void onCriteriaChanged() {
    _invalidateRequests();
    _activeFingerprint = _fingerprint;
    _activateCache();
    revealed.clear();
    _resetMetrics();
    AiReplyStats.instance.useFingerprint(_activeFingerprint!);
    revision.value++;
    _schedulePersist();
  }

  Future<void> clearCache() async {
    _invalidateRequests();
    verdicts.clear();
    _cache.clear();
    _resetMetrics();
    revision.value++;
    // Statistics keep their sample identities when only verdict cache is cleared.
    await GStorage.localCache.delete(LocalCacheKey.aiReplyFilterCache);
    await _persist();
  }

  @visibleForTesting
  void dispose() {
    _invalidateRequests();
    _persistTimer?.cancel();
    _settingsSubscription?.cancel();
  }

  @visibleForTesting
  Future<Map<int, AiReplyVerdict>> classifyTexts(
    List<String> texts, {
    String? criteria,
    CancelToken? cancelToken,
  }) async {
    final userTemplate = _userTemplate;
    final (system, user) = (
      buildSystemPrompt(
        _systemTemplate,
        criteria ?? Pref.aiReplyFilterCriteria,
      ),
      buildUserPrompt(
        userTemplate,
        texts: texts,
      ),
    );
    final messages = [
      {'role': 'system', 'content': system},
      {'role': 'user', 'content': user},
    ];
    final token = cancelToken ?? CancelToken();
    final fingerprint = _fingerprint;
    final policy = apiPolicy;
    final body = policy.body;
    final content = _completion != null
        ? await _completion!(messages, body.isEmpty ? null : body, token)
        : await AiChatService.completeChat(
            messages: messages,
            receiveTimeout: policy.effectiveThinking
                ? const Duration(seconds: 120)
                : const Duration(seconds: 60),
            cancelToken: token,
            extraBody: body.isEmpty ? null : body,
            stream: policy.useStreaming,
            onUsage: (usage) {
              if (fingerprint == _activeFingerprint) _recordUsage(usage);
            },
          );
    return AiReplyProtocol.parse(
      content,
      texts.length,
      requireCodes: userTemplate == defaultUserPrompt,
    );
  }

  Future<AiReplyVerdict?> checkNow(String text) async {
    final normalized = normalize(text);
    if (normalized.isEmpty) return null;
    final generation = _generation;
    final results = await classifyTexts(
      [_truncate(normalized)],
    );
    if (results[0] != null &&
        generation == _generation &&
        blockedStatus.value != null) {
      // A successful explicit settings test can recover after a balance/top-up
      // or provider-side repair, even when the saved key itself did not change.
      _invalidateRequests();
      revision.value++;
    }
    return results[0];
  }

  Future<AiReplyVerdict?> recheck(
    String text, {
    int? oid,
    int type = 1,
    String? sampleId,
  }) {
    final normalized = normalize(text);
    if (normalized.isEmpty) return Future.value();
    final hash = keyFor(normalized, oid: oid, type: type);
    final existing = _manualRequests[hash];
    if (existing != null) return existing;
    if (blockedStatus.value != null) {
      _invalidateRequests(); // An explicit recheck can probe a repaired endpoint.
      revision.value++;
    }
    late final Future<AiReplyVerdict?> request;
    request = _recheck(normalized, hash, oid, type, sampleId).whenComplete(() {
      if (identical(_manualRequests[hash], request)) {
        _manualRequests.remove(hash);
      }
    });
    _manualRequests[hash] = request;
    return request;
  }

  Future<AiReplyVerdict?> _recheck(
    String normalized,
    String hash,
    int? oid,
    int type,
    String? sampleId,
  ) async {
    final generation = _generation;
    final version = (_versions[hash] ?? 0) + 1;
    _versions[hash] = version;
    _pending.remove(hash);
    _retryTexts.remove(hash);
    _urgent.remove(hash);
    final token = CancelToken();
    _tokens.add(token);
    _inFlight[hash] = token;
    try {
      final results = await classifyTexts(
        [_truncate(normalized)],
        cancelToken: token,
      );
      if (generation != _generation || _versions[hash] != version) return null;
      final verdict = results[0];
      if (verdict == null) {
        _failedAt[hash] = DateTime.now();
        return null;
      }
      allowed.remove(hash);
      allowed.remove(contentHash(normalized.toLowerCase()));
      revealed.remove(hash);
      _failedAt.remove(hash);
      _attempts.remove(hash);
      _saveVerdict(hash, verdict, _fingerprint);
      verdicts[hash] = verdict;
      _recordSample(oid, type, sampleId ?? contentHash(normalized), verdict);
      for (final id in _sampleIds.remove(hash) ?? <String>{}) {
        _recordSample(oid, type, id, verdict);
      }
      _trimCache();
      _schedulePersist();
      return verdict;
    } catch (e) {
      if (generation == _generation && _versions[hash] == version) {
        if (_permanentFailure(e)) {
          _blockRequests((e as AiApiException).statusCode!);
        } else {
          _failedAt[hash] = DateTime.now();
        }
      }
      rethrow;
    } finally {
      _tokens.remove(token);
      if (identical(_inFlight[hash], token)) _inFlight.remove(hash);
    }
  }

  void _saveVerdict(String hash, AiReplyVerdict verdict, String fingerprint) {
    _cache.put(fingerprint, hash, verdict);
  }

  void _pump() {
    _timer?.cancel();
    _timer = null;
    if (!enabled || blockedStatus.value != null) {
      _pending.clear();
      return;
    }
    while (_batchesInFlight < _maxConcurrent && _pending.isNotEmpty) {
      _startBatch();
    }
  }

  void _startBatch() {
    final firstKey =
        _urgent.where(_pending.containsKey).firstOrNull ?? _pending.keys.first;
    final first = _pending[firstKey]!;
    final batch = <MapEntry<String, _PendingComment>>[];
    var characters = 0;
    // Limit input size as well as comment count. Do not split ordinary pages
    // into many tiny calls: each would repeat the entire system prompt.
    final keys = [firstKey, ..._pending.keys.where((key) => key != firstKey)];
    for (final key in keys) {
      final value = _pending[key]!;
      if (value.oid != first.oid || value.type != first.type) continue;
      if (batch.length >= _batchSize ||
          (batch.isNotEmpty && characters + value.text.length > 4000)) {
        break;
      }
      batch.add(MapEntry(key, value));
      characters += value.text.length;
    }
    final token = CancelToken();
    _tokens.add(token);
    for (final entry in batch) {
      _pending.remove(entry.key);
      _urgent.remove(entry.key);
      _inFlight[entry.key] = token;
      _attempts[entry.key] = (_attempts[entry.key] ?? 0) + 1;
    }
    _batchesInFlight++;
    _runBatch(batch, _generation, _fingerprint, token, {
      for (final entry in batch) entry.key: _versions[entry.key] ?? 0,
    });
  }

  Future<void> _runBatch(
    List<MapEntry<String, _PendingComment>> batch,
    int generation,
    String fingerprint,
    CancelToken token,
    Map<String, int> versions,
  ) async {
    bool current(String key) =>
        generation == _generation &&
        (_versions[key] ?? 0) == versions[key] &&
        !allowed.containsKey(key);
    final updates = <String, AiReplyVerdict>{};
    final failures = <String, DateTime>{};
    void fail(MapEntry<String, _PendingComment> entry) {
      if (!current(entry.key)) return;
      failures[entry.key] = DateTime.now();
      _queueRetry(entry.key, entry.value);
    }

    try {
      final results = await classifyTexts(
        batch.map((e) => e.value.text).toList(),
        cancelToken: token,
      );
      // Check the expensive prompt fingerprint once per completed request.
      if (generation != _generation || fingerprint != _fingerprint) return;
      for (var i = 0; i < batch.length; i++) {
        final entry = batch[i];
        if (!current(entry.key)) continue;
        final verdict = results[i];
        if (verdict == null) {
          fail(entry);
          continue;
        }
        updates[entry.key] = verdict;
        _failedAt.remove(entry.key);
        _retryTexts.remove(entry.key);
        _attempts.remove(entry.key);
        _saveVerdict(entry.key, verdict, fingerprint);
        for (final id in _sampleIds.remove(entry.key) ?? <String>{}) {
          _recordSample(entry.value.oid, entry.value.type, id, verdict);
        }
      }
      if (updates.isNotEmpty) {
        verdicts.addAll(updates); // one list notification per batch
        _trimCache();
        _schedulePersist();
      }
    } catch (e, s) {
      if (generation != _generation || fingerprint != _fingerprint) return;
      if (_permanentFailure(e)) {
        _blockRequests((e as AiApiException).statusCode!);
        return;
      }
      if (!token.isCancelled) {
        logger.e('AI 评论过滤请求失败', error: e, stackTrace: s);
      }
      // A deadline also cancels its token. Current requests must fail open;
      // settings cancellations are already excluded by generation above.
      for (final entry in batch) {
        fail(entry);
      }
    } finally {
      if (failures.isNotEmpty) _failedAt.addAll(failures);
      for (final entry in batch) {
        if (identical(_inFlight[entry.key], token)) _inFlight.remove(entry.key);
      }
      _tokens.remove(token);
      if (generation == _generation) _batchesInFlight--;
      if (_retryTexts.isNotEmpty) _scheduleRetry();
      _pump();
    }
  }

  static bool _permanentFailure(Object error) =>
      error is AiApiException &&
      const {400, 401, 402, 403, 404, 422}.contains(error.statusCode);

  void _blockRequests(int status) {
    _invalidateRequests();
    blockedStatus.value = status;
    revision.value++;
  }

  void _queueRetry(String hash, _PendingComment comment) {
    // At most ONE automatic retry per comment. Scrolling/rebuilds must not
    // turn a malformed response or unsupported API into an endless token bill.
    if ((_attempts[hash] ?? 0) >= 2) {
      _sampleIds.remove(hash);
      return;
    }
    if (_retryTexts.length >= _maxRetryEntries &&
        !_retryTexts.containsKey(hash)) {
      _retryTexts.remove(_retryTexts.keys.first);
    }
    _retryTexts[hash] = comment;
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
        if (verdicts.containsKey(entry.key) || allowed.containsKey(entry.key)) {
          continue;
        }
        if (_inFlight.containsKey(entry.key) ||
            _pending.containsKey(entry.key)) {
          continue;
        }
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

  void _trimCache() {
    final active = _cache.active(_activeFingerprint ?? _fingerprint);
    if (verdicts.keys.any((key) => !active.containsKey(key))) {
      verdicts.assignAll(active);
    }
  }

  void _schedulePersist({bool recencyOnly = false}) {
    if (_persistTimer?.isActive ?? false) {
      if (recencyOnly || !_persistRecencyOnly) return;
      _persistTimer?.cancel();
    }
    _persistRecencyOnly = recencyOnly;
    _persistTimer = Timer(Duration(seconds: recencyOnly ? 30 : 2), _persist);
  }

  Future<void> _persist() async {
    try {
      await GStorage.localCache.put(
        LocalCacheKey.aiReplyFilterCache,
        jsonEncode({
          'allow': allowed.keys.toList(),
          'version': 3,
          'entries': _cache.toJson(),
        }),
      );
    } catch (e) {
      logger.e('AI 评论过滤缓存保存失败', error: e);
    }
  }
}
