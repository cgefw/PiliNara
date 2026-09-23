import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:dio/dio.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_protocol.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_stats.dart';
import 'package:PiliPlus/services/ai_reply_filter/reply_page_cache.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fixnum/fixnum.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart';
import 'package:PiliPlus/pages/video/reply/widgets/ai_reply_guard.dart';

Future<void> drain() => Future<void>.delayed(const Duration(milliseconds: 10));

void main() {
  late Directory directory;
  late AiReplyFilterService service;
  final requests = <Completer<String>>[];
  final messages = <List<Map<String, String>>>[];
  final tokens = <CancelToken>[];

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('reply-regression-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('settings');
    GStorage.localCache = await Hive.openBox('cache');
  });
  setUp(() async {
    await GStorage.setting.clear();
    await GStorage.localCache.clear();
    await AiReplyStats.instance.clear();
    Pref.aiApiUrl = 'https://api.deepseek.com';
    Pref.aiModel = 'deepseek-flash';
    Pref.enableAiReplyFilter = true;
    requests.clear();
    messages.clear();
    tokens.clear();
    service = AiReplyFilterService.forTesting((m, body, token) {
      final completer = Completer<String>();
      requests.add(completer);
      tokens.add(token);
      messages.add(m);
      return completer.future;
    })..init();
  });
  tearDown(() {
    service.dispose();
    AiReplyStats.instance.dispose();
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test('compact response rejects missing, extra and invalid slots', () {
    for (final raw in [
      '{"v":[0]}',
      '{"v":[0,1,0]}',
      '{"v":[0,null]}',
      '{"v":[0,"safe"]}',
      '{"v":[0,true]}',
    ]) {
      expect(AiReplyProtocol.parse(raw, 2), isEmpty, reason: raw);
    }
    final result = AiReplyProtocol.parse('{"v":[0,1],"r":{"1":"阴阳"}}', 2);
    expect(result[0]!.unsafe, isFalse);
    expect(result[1]!.reason, '阴阳');
  });

  test('indexed compact results require every exact ID', () {
    final result = AiReplyProtocol.parse('{"v":{"1":1,"0":0}}', 2);
    expect(result[0]!.unsafe, isFalse);
    expect(result[1]!.unsafe, isTrue);
    for (final raw in [
      '{"v":{"0":0}}',
      '{"v":{"1":0,"2":1}}',
      '{"v":{"0":0,"1":1,"2":0}}',
      '{"v":{"0":0,"1":null}}',
    ]) {
      expect(AiReplyProtocol.parse(raw, 2), isEmpty);
    }
  });

  test('malformed legacy values do not become safe verdicts', () {
    expect(AiReplyProtocol.parse('[{"i":0}]', 1), isEmpty);
    expect(AiReplyProtocol.parse('[{"i":0,"u":"maybe"}]', 1), isEmpty);
    expect(AiReplyProtocol.parse('[{"i":0.5,"u":true}]', 1), isEmpty);
    expect(
      AiReplyProtocol.parse('[{"i":0,"u":true},{"i":0,"u":false}]', 2),
      isEmpty,
    );
    expect(AiReplyProtocol.parse('[{"i":1,"u":true}]', 3), isEmpty);
  });

  test(
    'template expansion blanks context and preserves braces in comments',
    () {
      final prompt = AiReplyProtocol.buildUserPrompt(
        '标题{title} 评论{comments}',
        texts: ['{count}'],
      );
      expect(prompt, startsWith('标题 评论'));
      expect(prompt, contains('{count}'));
    },
  );

  test('long comment keeps both opening context and ending reversal', () {
    final text = '开头${'中' * 700}结尾并不是在骂你';
    final truncated = AiReplyProtocol.truncate(text, 500);
    expect(truncated, startsWith('开头'));
    expect(truncated, endsWith('结尾并不是在骂你'));
    expect(truncated.length, lessThan(520));
  });

  test('default system prompt matches the user supplied text exactly', () {
    expect(
      AiReplyProtocol.systemPrompt,
      File('test/fixtures/ai_reply_system_prompt.txt')
          .readAsStringSync()
          .trimRight(),
    );
  });

  test(
    'all request paths send comments only and show local code labels',
    () async {
      service
        ..registerVideo(
          1,
          title: 'private-video-title',
          tags: ['private-tag'],
        )
        ..trackAll(['comment'], oid: 1);
      requests.single.complete('{"c":{"0":2},"r":{"0":"不要显示这段模型解释"}}');
      await drain();
      expect(
        service.verdictOfHash(service.keyFor('comment', oid: 1))!.reason,
        '轻蔑嘲讽或贬损',
      );
      final recheck = service.recheck('comment', oid: 1);
      requests.last.complete('{"c":{"0":0}}');
      await recheck;
      final test = service.checkNow('comment');
      requests.last.complete('{"c":{"0":0}}');
      await test;
      expect(messages, hasLength(3));
      for (final request in messages) {
        expect(request.first['content'], AiReplyProtocol.systemPrompt);
        expect(
          request.last['content'],
          AiReplyFilterService.buildUserPrompt(
            AiReplyProtocol.userPrompt,
            texts: ['comment'],
          ),
        );
        expect(request.toString(), isNot(contains('private-video-title')));
        expect(request.toString(), isNot(contains('private-tag')));
      }
    },
  );

  test('default code contract rejects a legacy detailed response', () async {
    final result = service.checkNow('comment');
    requests.single.complete('{"v":{"0":1},"r":{"0":"详细原因"}}');
    expect(await result, isNull);
  });

  test(
    'saved previous default migrates to the current code contract',
    () async {
      Pref.aiReplyFilterUserPrompt = AiReplyProtocol.legacyUserPrompt;
      await drain();
      final result = service.checkNow('comment');
      expect(
        messages.single.last['content'],
        AiReplyFilterService.buildUserPrompt(
          AiReplyProtocol.userPrompt,
          texts: ['comment'],
        ),
      );
      requests.single.complete('{"c":{"0":4}}');
      expect((await result)!.reason, '广告诈骗或垃圾推广');
    },
  );

  test('legacy context lines are omitted without rewriting comment data', () {
    final result = AiReplyFilterService.buildUserPrompt(
      AiReplyProtocol.binaryUserPrompt,
      texts: ['{title} {desc} {comments}'],
    );
    expect(result, isNot(contains('视频标题：')));
    expect(result, isNot(contains('简介：')));
    expect(result, contains('[[0,"{title} {desc} {comments}"]]'));
  });

  test('one page is sent immediately as one compact request', () async {
    service.trackAll(List.generate(20, (i) => 'comment $i'), oid: 1);
    expect(requests.length, 1);
    expect(messages.single.last['content'], isNot(contains('"text":')));
    expect(messages.single.first['content'], AiReplyProtocol.systemPrompt);
    expect(messages.single.last['content'], contains('{"c":{}}'));
    expect(messages.single.last['content'], isNot(contains('"v"')));
    expect(messages.single.last['content'], isNot(contains('视频标题')));
    expect(messages.single.last['content'], isNot(contains('简介')));
    requests.single.complete(
      jsonEncode({
        'c': {for (var i = 0; i < 20; i++) '$i': 0},
      }),
    );
    await drain();
    expect(service.cacheCount, 20);
  });

  test(
    'same video reuses text, different videos never share verdicts',
    () async {
      service
        ..track('一样', oid: 1, sampleId: 'a')
        ..track('一样', oid: 1, sampleId: 'b')
        ..track('一样', oid: 2, sampleId: 'c')
        ..flush();
      expect(requests.length, 2);
      requests[0].complete('{"c":{"0":0}}');
      requests[1].complete('{"c":{"0":1}}');
      await drain();
      expect(
        service.verdictOfHash(service.keyFor('一样', oid: 1))!.unsafe,
        isFalse,
      );
      expect(
        service.verdictOfHash(service.keyFor('一样', oid: 2))!.unsafe,
        isTrue,
      );
      expect(AiReplyStats.instance.commentCount, 3);
      service.track('一样', oid: 1, sampleId: 'a');
      expect(AiReplyStats.instance.commentCount, 3);
      expect(requests.length, 2);
    },
  );

  test(
    'equal numeric IDs in different content types keep separate context',
    () async {
      service
        ..registerVideo(1, title: 'isolated-video-context')
        ..trackAll(['comment'], oid: 1, type: 17);
      expect(
        messages.single.last['content'],
        isNot(contains('isolated-video-context')),
      );
      requests.single.complete('{"c":{"0":0}}');
      await drain();
      expect(AiReplyStats.instance.commentCount, 0);
    },
  );

  test('legacy manual allowlist stays effective after cache migration', () {
    service.allowed[AiReplyFilterService.contentHash('hello')] = true;
    final key = service.keyFor('HELLO', oid: 1);
    service.trackAll(['HELLO'], oid: 1);
    expect(service.isRevealed(key, text: 'HELLO'), isTrue);
    expect(requests, isEmpty);
  });

  test(
    'deadline cancellation becomes a failure instead of a stuck skeleton',
    () async {
      service.trackAll(['timeout'], oid: 1);
      tokens.single.cancel('request deadline');
      requests.single.completeError(
        AiApiException(url: 'https://example.test', detail: 'request deadline'),
      );
      await drain();
      expect(service.isFailed(service.keyFor('timeout', oid: 1)), isTrue);
      service.trackAll(['timeout'], oid: 1);
      expect(requests, hasLength(1));
    },
  );

  test(
    'new credential clears failures while retaining cached verdicts',
    () async {
      service.trackAll(['known'], oid: 1);
      requests[0].complete('{"c":{"0":0}}');
      await drain();
      service.trackAll(['failed'], oid: 1);
      requests[1].complete('{}');
      await drain();
      Pref.aiApiKey = 'replacement-test-credential';
      await drain();
      expect(service.cacheCount, 1);
      expect(service.isFailed(service.keyFor('failed', oid: 1)), isFalse);
      service.trackAll(['failed', 'known'], oid: 1);
      expect(requests, hasLength(3));
    },
  );

  test(
    'permanent API errors stop requests until configuration changes',
    () async {
      service.trackAll(['unauthorized'], oid: 1);
      requests.single.completeError(
        AiApiException(
          url: 'https://example.test',
          statusCode: 401,
          detail: 'unauthorized',
        ),
      );
      await drain();
      service.trackAll(['another page'], oid: 2);
      expect(requests, hasLength(1));
      expect(service.isFailed(service.keyFor('another page', oid: 2)), isTrue);
      Pref.aiApiKey = 'corrected-test-credential';
      await drain();
      service.trackAll(['another page'], oid: 2);
      expect(requests, hasLength(2));
    },
  );

  test('manual recheck is shared by repeated taps and page tracking', () async {
    final first = service.recheck('manual', oid: 1);
    final second = service.recheck('manual', oid: 1);
    service.trackAll(['manual'], oid: 1);
    expect(requests, hasLength(1));
    requests.single.complete('{"c":{"0":1}}');
    expect((await first)!.unsafe, isTrue);
    expect((await second)!.unsafe, isTrue);
  });

  test('cancelled generation releases the new concurrency limit', () async {
    Pref.aiReplyFilterConcurrency = 1;
    await drain();
    service.trackAll(['before'], oid: 1);
    Pref.aiReplyFilterCriteria = 'changed';
    await drain();
    service.trackAll(['after'], oid: 1);
    expect(requests, hasLength(2));
    requests[0].complete('{"c":{"0":1}}');
    requests[1].complete('{"c":{"0":0}}');
    await drain();
    service.trackAll(['last'], oid: 1);
    expect(requests, hasLength(3));
  });

  test('switching back restores a bounded configuration cache', () async {
    service.trackAll(['comment'], oid: 1);
    requests.single.complete('{"c":{"0":1}}');
    await drain();
    Pref.aiModel = 'model-B';
    await drain();
    expect(service.cacheCount, 0);
    expect(service.totalCacheCount, 1);
    service.trackAll(['comment'], oid: 1);
    requests.last.complete('{"c":{"0":0}}');
    await drain();
    Pref.aiModel = 'deepseek-flash';
    await drain();
    expect(
      service.verdictOfHash(service.keyFor('comment', oid: 1))!.unsafe,
      isTrue,
    );
    service.trackAll(['comment'], oid: 1);
    expect(requests, hasLength(2));
    expect(service.localHits, 1);
    expect(service.totalCacheCount, 2);
    await service.clearCache();
    Pref.aiModel = 'model-B';
    await drain();
    expect(service.cacheCount, 0);
    expect(service.totalCacheCount, 0);
  });

  test(
    'cosmetic URL edits and equivalent thinking formats keep cache',
    () async {
      service.trackAll(['comment'], oid: 1);
      requests.single.complete('{"c":{"0":0}}');
      await drain();
      Pref.aiApiUrl = ' https://api.deepseek.com/ ';
      Pref.aiReplyFilterThinkingParam = 0;
      await drain();
      service.trackAll(['comment'], oid: 1);
      expect(requests, hasLength(1));
      expect(service.cacheCount, 1);
    },
  );

  test('local metrics count page lookups but not widget reads', () async {
    service.trackAll(['comment', 'comment'], oid: 1);
    expect(service.localMisses, 1);
    expect(service.inFlightReuses, 1);
    requests.single.complete('{"c":{"0":0}}');
    await drain();
    final key = service.keyFor('comment', oid: 1);
    for (var i = 0; i < 5; i++) {
      service
        ..verdictOfHash(key)
        ..trackHash(key, 'comment', oid: 1);
    }
    expect(service.localHits, 0);
    service.trackAll(['comment'], oid: 1);
    expect(service.localHits, 1);
    expect(service.localHitRate, closeTo(1 / 3, 0.0001));
    expect(service.providerHitRate, isNull);
  });

  test('old request cannot repopulate cache after rules change', () async {
    service.trackAll(['comment'], oid: 1);
    Pref.aiReplyFilterCriteria = '新的规则';
    service.onCriteriaChanged();
    await drain();
    service.trackAll(['comment'], oid: 1);
    expect(requests.length, 2);
    requests[0].complete('{"c":{"0":1}}');
    await drain();
    expect(service.cacheCount, 0);
    requests[1].complete('{"c":{"0":0}}');
    await drain();
    expect(
      service.verdictOfHash(service.keyFor('comment', oid: 1))!.unsafe,
      isFalse,
    );
  });

  test('allow forever wins over a late request', () async {
    service.trackAll(['comment'], oid: 1);
    final key = service.keyFor('comment', oid: 1);
    service.allowForever(key);
    requests.single.complete('{"c":{"0":1}}');
    await drain();
    expect(service.isRevealed(key), isTrue);
    expect(service.verdictOfHash(key), isNull);
    expect(service.cacheCount, 0);
  });

  test('failure state is reactive and rebuilds do not resubmit', () async {
    service.trackAll(['comment'], oid: 1);
    final key = service.keyFor('comment', oid: 1);
    requests.single.complete('{}');
    await drain();
    expect(service.isFailed(key), isTrue);
    service.trackAll(['comment'], oid: 1);
    expect(requests.length, 1);
  });

  test(
    'cache clearing preserves distinct sample IDs and recheck updates count',
    () async {
      service
        ..track('comment', oid: 1, sampleId: '42')
        ..flush();
      requests[0].complete('{"c":{"0":1}}');
      await drain();
      expect(AiReplyStats.instance.commentCount, 1);
      await service.clearCache();
      service
        ..track('comment', oid: 1, sampleId: '42')
        ..flush();
      requests[1].complete('{"c":{"0":0}}');
      await drain();
      expect(AiReplyStats.instance.commentCount, 1);
      expect(AiReplyStats.instance.unsafeCount, 0);
      final checking = service.recheck('comment', oid: 1, sampleId: '42');
      requests[2].complete('{"c":{"0":1}}');
      await checking;
      expect(AiReplyStats.instance.commentCount, 1);
      expect(AiReplyStats.instance.unsafeCount, 1);
    },
  );

  test('late old verdict cannot overwrite an explicit recheck', () async {
    service.trackAll(['comment'], oid: 1);
    final check = service.recheck('comment', oid: 1);
    requests[1].complete('{"c":{"0":0}}');
    await check;
    requests[0].complete('{"c":{"0":1}}');
    await drain();
    expect(
      service.verdictOfHash(service.keyFor('comment', oid: 1))!.unsafe,
      isFalse,
    );
  });

  test('old batch completion cannot remove an active manual request', () async {
    service.trackAll(['shared'], oid: 1);
    final manual = service.recheck('shared', oid: 1, sampleId: 'manual-id');
    requests[0].complete('{"c":{"0":1}}');
    await drain();
    service
      ..track('shared', oid: 1, sampleId: 'second-id')
      ..flush();
    expect(requests, hasLength(2));
    requests[1].complete('{"c":{"0":0}}');
    expect((await manual)!.unsafe, isFalse);
    expect(AiReplyStats.instance.commentCount, 3);
  });

  test('category mode never reuses detailed legacy reasons', () async {
    Pref.aiReplyFilterUserPrompt = AiReplyProtocol.binaryUserPrompt;
    await drain();
    service.trackAll(['existing'], oid: 1);
    expect(messages.last.last['content'], contains('[[0,"existing"]]'));
    requests.single.complete('{"v":{"0":1},"r":{"0":"旧版详细解释"}}');
    await drain();
    expect(
      service.verdictOfHash(service.keyFor('existing', oid: 1))!.reason,
      '旧版详细解释',
    );
    Pref.aiReplyFilterUserPrompt = '';
    await drain();
    service.trackAll(['existing'], oid: 1);
    expect(requests, hasLength(2));
    expect(service.verdictOfHash(service.keyFor('existing', oid: 1)), isNull);
    requests.last.complete('{"c":{"0":2}}');
    await drain();
    expect(
      service.verdictOfHash(service.keyFor('existing', oid: 1))!.reason,
      '轻蔑嘲讽或贬损',
    );
    Pref.aiReplyFilterCriteria = 'different rules';
    await drain();
    expect(service.cacheCount, 0);
  });

  test(
    'successful settings test resumes filtering after provider repair',
    () async {
      service.trackAll(['failed'], oid: 1);
      requests.single.completeError(
        AiApiException(
          url: 'https://example.test',
          statusCode: 402,
          detail: 'balance',
        ),
      );
      await drain();
      final probe = service.checkNow('test');
      requests.last.complete('{"c":{"0":0}}');
      expect((await probe)!.unsafe, isFalse);
      service.trackAll(['new'], oid: 1);
      expect(requests, hasLength(3));
    },
  );

  test('concurrency cap is respected', () async {
    Pref.aiReplyFilterConcurrency = 2;
    service
      ..trackAll(['one'], oid: 1)
      ..trackAll(['two'], oid: 2)
      ..trackAll(['three'], oid: 3);
    expect(requests.length, 2);
    requests[0].complete('{"c":{"0":0}}');
    await drain();
    expect(requests.length, 3);
    requests[1].complete('{"c":{"0":0}}');
    requests[2].complete('{"c":{"0":0}}');
    await drain();
  });

  test('sample identity survives persistence and verdict updates', () {
    final stat = AiVideoStat(oid: 1, ts: 0, fingerprint: 'v2')
      ..recordSample('id1', true);
    final restored = AiVideoStat.fromJson(
      1,
      jsonDecode(jsonEncode(stat.toJson())),
    );
    expect(restored.recordSample('id1', true), isFalse);
    restored.recordSample('id1', false);
    expect(restored.total, 1);
    expect(restored.unsafe, 0);
  });

  test(
    'prefetch shares in-flight request, is single use and expires',
    () async {
      var now = DateTime(2026);
      var calls = 0;
      final result = Completer<int>();
      final cache = ReplyPageCache<int>(
        isSuccess: (v) => v > 0,
        now: () => now,
      );
      Future<int> load() {
        calls++;
        return result.future;
      }

      final prefetch = cache.load('hot:1', load, prefetch: true);
      final visible = cache.load('hot:1', load);
      result.complete(1);
      expect(await prefetch, 1);
      expect(await visible, 1);
      expect(calls, 1);
      await cache.load('hot:1', load);
      expect(calls, 2);
      await cache.load('time:1', load, prefetch: true);
      expect(calls, 3);
      now = now.add(const Duration(seconds: 31));
      await cache.load('time:1', load);
      expect(calls, 4);
    },
  );

  test('failed prefetch does not poison retry', () async {
    var calls = 0;
    final cache = ReplyPageCache<int>(isSuccess: (v) => v > 0);
    Future<int> load() async => ++calls == 1 ? -1 : 1;
    expect(await cache.load('page', load, prefetch: true), -1);
    expect(await cache.load('page', load), 1);
    expect(calls, 2);
  });
  Widget guard() => MaterialApp(
    home: Scaffold(
      body: AiReplyGuard(
        filterService: service,
        reply: ReplyInfo(
          oid: Int64(1),
          type: Int64(1),
          id: Int64(42),
          content: Content(message: 'comment'),
        ),
        child: const Text('original comment'),
      ),
    ),
  );

  Future<void> cleanWidget(WidgetTester tester) async {
    service.dispose();
    AiReplyStats.instance.dispose();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('failure replaces skeleton without scroll or another verdict', (
    tester,
  ) async {
    await tester.pumpWidget(guard());
    expect(find.text('original comment'), findsNothing);
    service.flush();
    requests.single.complete('{}');
    await tester.pump();
    await tester.pump();
    expect(find.text('original comment'), findsOneWidget);
    await cleanWidget(tester);
  });

  testWidgets('both display modes and allow forever update live', (
    tester,
  ) async {
    await tester.pumpWidget(guard());
    expect(find.text('original comment'), findsNothing);
    await tester.runAsync(
      () => GStorage.setting.put(
        SettingBoxKey.aiReplyFilterShowBeforeVerdict,
        true,
      ),
    );
    service.refreshSettings();
    await tester.pump();
    expect(find.text('original comment'), findsOneWidget);
    service.flush();
    requests.single.complete('{"c":{"0":1}}');
    await tester.pump();
    await tester.pump();
    expect(find.text('original comment'), findsNothing);
    service.allowForever(service.keyFor('comment', oid: 1));
    await tester.pump();
    expect(find.text('original comment'), findsOneWidget);
    await cleanWidget(tester);
  });

  testWidgets(
    'automatic retry stops after one retry and never restores skeleton',
    (tester) async {
      await tester.pumpWidget(guard());
      service.flush();
      requests[0].complete('{}');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 61));
      expect(requests.length, 2);
      expect(find.text('original comment'), findsOneWidget);
      requests[1].complete('{}');
      await tester.pump();
      await tester.pump(const Duration(minutes: 20));
      expect(requests.length, 2);
      expect(find.text('original comment'), findsOneWidget);
      await cleanWidget(tester);
    },
  );
}
