import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/ai_chat/ai_chat_protocol.dart';
import 'package:PiliPlus/services/ai_chat/ai_chat_service.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late Future<void> Function(HttpRequest) handler;
  const messages = [
    {'role': 'user', 'content': 'classify'},
  ];

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('ai-transport-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('settings');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    subscription = server.listen((request) async {
      try {
        await handler(request);
      } catch (_) {
        // Client cancellation can close an intentionally stalled test response.
        await request.response.close();
      }
    });
    Pref.aiApiUrl = 'http://127.0.0.1:${server.port}/v1';
    Pref.aiModel = 'qwen3-32b';
    Pref.aiApiKey = '';
  });
  tearDownAll(() async {
    await subscription.cancel();
    await server.close(force: true);
    await Hive.close();
    await directory.delete(recursive: true);
  });

  test(
    'stream transport requests usage, collects final content and reports once',
    () async {
      final received = Completer<Map>();
      handler = (request) async {
        received.complete(jsonDecode(await utf8.decodeStream(request)) as Map);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        for (final frame in [
          {
            'choices': [
              {
                'delta': {'reasoning_content': '不能混入答案'},
              },
            ],
          },
          {
            'choices': [
              {
                'delta': {'content': '{"v":{"0":0}}'},
                'finish_reason': 'stop',
              },
            ],
          },
          {
            'choices': [],
            'usage': {
              'prompt_tokens': 1234,
              'completion_tokens': 90,
              'prompt_tokens_details': {'cached_tokens': 1024},
            },
          },
        ]) {
          request.response.write('data: ${jsonEncode(frame)}\n\n');
          await request.response.flush();
        }
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      };
      final usages = <AiTokenUsage>[];
      expect(
        await AiChatService.completeChat(
          messages: messages,
          stream: true,
          extraBody: {'enable_thinking': true, 'thinking_budget': 1024},
          onUsage: usages.add,
        ),
        '{"v":{"0":0}}',
      );
      final body = await received.future;
      expect(body['stream'], isTrue);
      expect(body['stream_options'], {'include_usage': true});
      expect(body['enable_thinking'], isTrue);
      expect(usages, hasLength(1));
      expect(usages.single.cached, 1024);
    },
  );

  test(
    'nonstream transport reports DeepSeek cache usage and preserves content',
    () async {
      handler = (request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'choices': [
              {
                'message': {'content': '{"v":{"0":1}}'},
                'finish_reason': 'stop',
              },
            ],
            'usage': {
              'prompt_tokens': 800,
              'completion_tokens': 12,
              'prompt_cache_hit_tokens': 512,
            },
          }),
        );
        await request.response.close();
      };
      final usages = <AiTokenUsage>[];
      expect(
        await AiChatService.completeChat(
          messages: messages,
          onUsage: usages.add,
        ),
        '{"v":{"0":1}}',
      );
      expect(usages.single.cached, 512);
    },
  );

  test('cancelled stream stops waiting for final content', () async {
    final started = Completer<void>();
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"reasoning_content":"thinking"}}]}\n\n',
      );
      await request.response.flush();
      started.complete();
    };
    final token = CancelToken();
    final request = AiChatService.completeChat(
      messages: messages,
      stream: true,
      cancelToken: token,
    );
    final assertion = expectLater(request, throwsA(isA<AiApiException>()));
    await started.future;
    token.cancel();
    await assertion.timeout(const Duration(seconds: 2));
  });

  test('deadline bounds a stream that never finishes', () async {
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write('data: {"choices":[]}\n\n');
      await request.response.flush();
    };
    await expectLater(
      AiChatService.completeChat(
        messages: messages,
        stream: true,
        receiveTimeout: const Duration(milliseconds: 100),
      ),
      throwsA(
        isA<AiApiException>().having((e) => e.detail, 'detail', contains('超时')),
      ),
    );
  });

  test('EOF without a finish frame cannot accept otherwise valid verdict JSON', () async {
    handler = (request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: {"choices":[{"delta":{"content":"{\\"c\\":{\\"0\\":0}}"}}]}\n\n',
      );
      await request.response.close();
    };
    await expectLater(
      AiChatService.completeChat(messages: messages, stream: true),
      throwsA(
        isA<AiApiException>().having((e) => e.detail, 'detail', '流式响应提前结束'),
      ),
    );
  });
}
