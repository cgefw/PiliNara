import 'dart:convert';

import 'package:PiliPlus/services/ai_chat/ai_chat_protocol.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_api_policy.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_cache.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

AiReplyApiPolicy policy({
  String url = 'https://dashscope.aliyuncs.com/compatible-mode/v1',
  String model = 'qwen3-32b',
  bool thinking = false,
  int param = 4,
}) => AiReplyApiPolicy(
  url: url,
  model: model,
  thinking: thinking,
  param: param,
  compact: true,
);

void main() {
  const safe = AiReplyVerdict(unsafe: false);
  const unsafe = AiReplyVerdict(unsafe: true, reason: '嘲讽');
  test('repeated hot-cache reads do not make persistence dirty', () {
    final cache = AiReplyCache(capacity: 2)..put('A', 'hot', safe);
    final revision = cache.revision;
    for (var i = 0; i < 100; i++) {
      expect(cache.get('A', 'hot'), same(safe));
    }
    expect(cache.revision, revision);
    cache
      ..put('A', 'new', unsafe)
      ..get('A', 'hot')
      ..put('A', 'third', safe);
    expect(cache.get('A', 'new'), isNull);
    expect(cache.get('A', 'hot'), same(safe));
  });

  test('coded results preserve ID coverage and provide local explanations', () {
    final result = AiReplyProtocol.parse('{"c":{"0":0,"1":2,"2":4}}', 3);
    expect(result[0]!.unsafe, isFalse);
    expect(result[1]!.reason, '轻蔑嘲讽或贬损');
    expect(result[2]!.reason, '广告诈骗或垃圾推广');
    for (final raw in [
      '{"c":{"0":0}}',
      '{"c":{"0":0,"1":7}}',
      '{"c":{"0":0,"1":-1}}',
      '{"c":{"0":0,"1":true}}',
      '{"c":{"0":0,"1":2.0}}',
      '{"c":{"0":0,"1":"2"}}',
      '{"c":[0,2]}',
      '{"c":{"1":0,"2":2}}',
      '{"c":{"0":0,"1":2},"v":{"0":0,"1":1}}',
    ]) {
      expect(AiReplyProtocol.parse(raw, 2), isEmpty, reason: raw);
    }
  });
  test('LRU keeps read entries and bounds all namespaces together', () {
    final cache = AiReplyCache(capacity: 2)
      ..put('A', 'hot', safe)
      ..put('B', 'cold', unsafe);
    expect(cache.get('A', 'hot'), same(safe));
    cache.put('B', 'new', unsafe);
    expect(cache.length, 2);
    expect(cache.get('B', 'cold'), isNull);
    expect(cache.get('A', 'hot'), same(safe));
    expect(cache.active('B').keys, ['new']);
  });

  test('LRU order survives persistence and bad legacy entries are skipped', () {
    final cache = AiReplyCache(capacity: 2)
      ..put('A', 'one', safe)
      ..put('A', 'two', unsafe)
      ..get('A', 'one');
    final restored = AiReplyCache(capacity: 2)
      ..restore(jsonDecode(jsonEncode({'entries': cache.toJson()})) as Map)
      ..put('B', 'three', safe);
    expect(restored.get('A', 'two'), isNull);
    expect(restored.get('A', 'one')!.unsafe, isFalse);
    final legacy = AiReplyCache()
      ..restore({
        'items': {
          'ok': [1, '嘲讽', 123, 'old'],
          'bad': [0, '', 'not a timestamp', 'old'],
        },
      });
    expect(legacy.length, 1);
    expect(legacy.get('old', 'ok')!.unsafe, isTrue);
  });

  test('auto Qwen disables thinking without DeepSeek fields', () {
    for (final host in [
      'dashscope.aliyuncs.com',
      'dashscope-intl.aliyuncs.com',
      'dashscope-us.aliyuncs.com',
      'workspace.cn-beijing.maas.aliyuncs.com',
    ]) {
      final p = policy(url: 'https://$host/compatible-mode/v1');
      expect(p.body['enable_thinking'], isFalse);
      expect(p.body.containsKey('thinking'), isFalse);
      expect(p.body['response_format'], {'type': 'json_object'});
      expect(p.body['max_tokens'], 1024);
      expect(p.useStreaming, isFalse);
    }
  });

  test(
    'Qwen thinking uses stream and bounded output without JSON constraint',
    () {
      for (final model in ['qwen3-32b', 'qwen-plus', 'qwen3.8-max']) {
        final p = policy(model: model, thinking: true);
        expect(p.useStreaming, isTrue);
        expect(p.body['enable_thinking'], isTrue);
        expect(p.body['thinking_budget'], 1024);
        expect(p.body['max_completion_tokens'], 4096);
        expect(p.body.containsKey('response_format'), isFalse);
        expect(p.body.containsKey('temperature'), isFalse);
      }
      final explicit = policy(thinking: true, param: 2);
      expect(explicit.body['reasoning_effort'], 'low');
      expect(explicit.body.containsKey('thinking_budget'), isFalse);
    },
  );

  test('pure thinking cannot accidentally receive enable_thinking false', () {
    for (final model in [
      'qwq-plus',
      'qwen3-235b-a22b-thinking-2507',
      'qwen3.8-2.4t-a95b',
    ]) {
      final p = policy(model: model, param: 1);
      expect(p.useStreaming, isTrue);
      expect(p.body.containsKey('enable_thinking'), isFalse);
      expect(p.body.containsKey('response_format'), isFalse);
    }
  });

  test('legacy and coder models do not get hybrid-only parameters', () {
    for (final model in ['qwen2.5-72b-instruct', 'qwen3-coder-plus']) {
      final p = policy(model: model);
      expect(p.body.containsKey('enable_thinking'), isFalse);
      expect(p.useStreaming, isFalse);
    }
    expect(
      policy(model: 'qwen3-coder-plus').body.containsKey('response_format'),
      isFalse,
    );
  });

  test(
    'unknown gateways require explicit parameters and no-param keeps default',
    () {
      expect(
        policy(url: 'https://dashscope.aliyuncs.com.example.org/v1').body,
        isEmpty,
      );
      final gateway = policy(
        url: 'https://example.org/v1',
        thinking: true,
        param: 1,
      );
      expect(gateway.body, {'enable_thinking': true});
      expect(gateway.useStreaming, isTrue);
      final defaults = policy(param: 3);
      expect(defaults.body.containsKey('enable_thinking'), isFalse);
      expect(defaults.useStreaming, isTrue); // server might default to thinking
      expect(defaults.body.containsKey('response_format'), isFalse);
      expect(
        policy(
          url: 'https://api.deepseek.com',
          model: 'deepseek-flash',
        ).body['thinking'],
        {'type': 'disabled'},
      );
    },
  );

  test(
    'missing cache usage differs from zero and invalid counts are ignored',
    () {
      expect(AiTokenUsage.fromJson({'prompt_tokens': 12}).cached, isNull);
      expect(
        AiTokenUsage.fromJson({
          'prompt_tokens': 12,
          'prompt_cache_hit_tokens': 0,
        }).cached,
        0,
      );
      expect(
        AiTokenUsage.fromJson({
          'prompt_tokens': 12,
          'prompt_cache_hit_tokens': 8,
        }).cached,
        8,
      );
      final qwen = AiTokenUsage.fromJson({
        'prompt_tokens': 1200,
        'completion_tokens': 100,
        'prompt_tokens_details': {'cached_tokens': 1024},
      });
      expect(qwen.cached, 1024);
      expect(qwen.output, 100);
      expect(
        AiTokenUsage.fromJson({
          'prompt_tokens': 12,
          'prompt_cache_hit_tokens': 99,
        }).cached,
        isNull,
      );
    },
  );

  test('fragmented UTF8 SSE preserves final JSON and trailing usage', () async {
    final frames = [
      {
        'choices': [
          {
            'delta': {'reasoning_content': '思考中'},
          },
        ],
      },
      {
        'choices': [
          {
            'delta': {'content': '{"v":{"0":1},'},
          },
        ],
      },
      {
        'choices': [
          {
            'delta': {'content': '"r":{"0":"嘲讽"}}'},
            'finish_reason': 'stop',
          },
        ],
      },
      {
        'choices': [],
        'usage': {
          'prompt_tokens': 1200,
          'prompt_tokens_details': {'cached_tokens': 1024},
        },
      },
    ];
    final encoded = utf8.encode(
      ': keepalive\r\n\r\n${frames.map((f) => 'data: ${jsonEncode(f)}\r\n\r\n').join()}data: [DONE]\r\n\r\n',
    );
    final content = AiCompletionContent();
    AiTokenUsage? usage;
    await for (final frame in decodeAiSse(
      Stream.fromIterable(encoded.map((b) => [b])),
    )) {
      content.add(frame, streaming: true);
      if (frame['usage'] is Map) {
        usage = AiTokenUsage.fromJson(frame['usage'] as Map);
      }
    }
    expect(AiReplyProtocol.parse(content.finish(), 1)[0]!.reason, '嘲讽');
    expect(usage!.cached, 1024);
  });

  test(
    'SSE supports multiline frames and a final frame without delimiter',
    () async {
      final frames = await decodeAiSse(
        Stream.value(utf8.encode('data: {"choices":[],\ndata: "usage":{}}')),
      ).toList();
      expect(frames.single['usage'], isEmpty);
      await expectLater(
        decodeAiSse(Stream.value(utf8.encode('<html>'))).toList(),
        throwsFormatException,
      );
      await expectLater(
        decodeAiSse(Stream.value(utf8.encode('data: broken\n\n'))).toList(),
        throwsFormatException,
      );
    },
  );

  test(
    'errors, truncated answers and reasoning-only responses cannot pass',
    () {
      final content = AiCompletionContent();
      expect(
        () => content.add({
          'error': {'message': 'quota'},
        }, streaming: true),
        throwsFormatException,
      );
      content.add({
        'choices': [
          {
            'delta': {'reasoning_content': '{}'},
          },
        ],
      }, streaming: true);
      expect(content.finish, throwsFormatException);
      content.add({
        'choices': [
          {
            'delta': {'content': '{"v":{"0":0}}'},
            'finish_reason': 'length',
          },
        ],
      }, streaming: true);
      expect(content.finish, throwsFormatException);
      final normal = AiCompletionContent()
        ..add({
          'choices': [
            {
              'message': {'content': '{"v":{"0":0}}'},
              'finish_reason': 'stop',
            },
          ],
        }, streaming: false);
      expect(AiReplyProtocol.parse(normal.finish(), 1)[0]!.unsafe, isFalse);
    },
  );
}
