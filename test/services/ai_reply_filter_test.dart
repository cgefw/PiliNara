import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contentHash', () {
    test('stable and ignores repeated whitespace', () {
      final a = AiReplyFilterService.contentHash('Hello  World');
      final b = AiReplyFilterService.contentHash('  Hello\tWorld ');
      expect(a, b);
      expect(a, AiReplyFilterService.contentHash('Hello World'));
    });

    test('preserves case for meaning-sensitive text', () {
      expect(
        AiReplyFilterService.contentHash('US'),
        isNot(AiReplyFilterService.contentHash('us')),
      );
    });

    test('differs for different texts', () {
      expect(
        AiReplyFilterService.contentHash('好'),
        isNot(AiReplyFilterService.contentHash('不好')),
      );
    });
  });

  group('parseVerdicts', () {
    test('parses zero-based json array', () {
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":0,"u":true,"r":"辱骂"},{"i":1,"u":false,"r":""}]',
        2,
      );
      expect(result.keys.toSet(), {0, 1});
      expect(result[0]!.unsafe, isTrue);
      expect(result[0]!.reason, '辱骂');
      expect(result[1]!.unsafe, isFalse);
    });

    test('falls back to one-based indices', () {
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":1,"u":true,"r":"引战"},{"i":2,"u":false,"r":""}]',
        2,
      );
      expect(result.keys.toSet(), {0, 1});
      expect(result[0]!.unsafe, isTrue);
      expect(result[1]!.unsafe, isFalse);
    });

    test('single comment works for both index bases', () {
      final zero = AiReplyFilterService.parseVerdicts(
        '[{"i":0,"u":true,"r":"a"}]',
        1,
      );
      final one = AiReplyFilterService.parseVerdicts(
        '[{"i":1,"u":true,"r":"a"}]',
        1,
      );
      expect(zero[0]!.unsafe, isTrue);
      expect(one[0]!.unsafe, isTrue);
    });

    test('parses fenced json with surrounding text', () {
      const raw =
          '分析结果如下：\n'
          '```json\n'
          '[{"i": 0, "u": 1, "r": "引战"}]\n'
          '```\n';
      final result = AiReplyFilterService.parseVerdicts(raw, 1);
      expect(result[0]!.unsafe, isTrue);
      expect(result[0]!.reason, '引战');
    });

    test('ignores out-of-range and invalid entries', () {
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":-1,"u":true},{"i":9,"u":true},{"x":1},{"i":"abc"}]',
        2,
      );
      expect(result, isEmpty);
    });

    test('keeps only returned entries', () {
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":0,"u":true,"r":"a"}]',
        3,
      );
      expect(result.keys.toSet(), {0});
    });

    test('returns empty on invalid json', () {
      expect(AiReplyFilterService.parseVerdicts('not json', 1), isEmpty);
      expect(AiReplyFilterService.parseVerdicts('{"a":1}', 1), isEmpty);
    });

    test('truncates long reason', () {
      final long = List.filled(50, '原').join();
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":0,"u":true,"r":"$long"}]',
        1,
      );
      expect(result[0]!.reason.length, 30);
    });
  });

  group('buildSystemPrompt', () {
    test('appends custom criteria', () {
      final result = AiReplyFilterService.buildSystemPrompt('base', '过滤剧透');
      expect(result, contains('base'));
      expect(result, contains('过滤剧透'));
    });

    test('keeps base without criteria', () {
      expect(
        AiReplyFilterService.buildSystemPrompt('base', '  '),
        'base',
      );
    });
  });

  group('buildUserPrompt', () {
    test('replaces all placeholders', () {
      final result = AiReplyFilterService.buildUserPrompt(
        't:{title} d:{desc} n:{count} c:{comments}',
        texts: ['第一条', '第二条'],
        title: '标题',
        desc: '简介',
      );
      expect(result, contains('t:标题'));
      expect(result, contains('d:简介'));
      expect(result, contains('n:2'));
      expect(result, contains('"i":0'));
      expect(result, contains('第一条'));
    });

    test('prepends context when template has no title/desc', () {
      final result = AiReplyFilterService.buildUserPrompt(
        '审查：{comments}',
        texts: ['x'],
        title: '标题',
        desc: '简介',
      );
      expect(result, startsWith('视频标题：《标题》，简介：简介'));
    });

    test('appends payload when template lacks comments placeholder', () {
      final result = AiReplyFilterService.buildUserPrompt(
        '审查这些评论',
        texts: ['x'],
      );
      expect(result, contains('"i":0'));
    });
  });

  group('fingerprintOf', () {
    test('changes with system or user prompt', () {
      expect(
        AiReplyFilterService.fingerprintOf('a', 'b'),
        isNot(AiReplyFilterService.fingerprintOf('a2', 'b')),
      );
      expect(
        AiReplyFilterService.fingerprintOf('a', 'b'),
        isNot(AiReplyFilterService.fingerprintOf('a', 'b2')),
      );
    });
  });

  group('buildThinkingParams', () {
    test('thinking.type enabled/disabled', () {
      expect(AiReplyFilterService.buildThinkingParams(true, 0), {
        'thinking': {'type': 'enabled'},
      });
      expect(AiReplyFilterService.buildThinkingParams(false, 0), {
        'thinking': {'type': 'disabled'},
      });
    });

    test('enable_thinking and reasoning_effort by switch', () {
      expect(AiReplyFilterService.buildThinkingParams(true, 1), {
        'enable_thinking': true,
      });
      expect(AiReplyFilterService.buildThinkingParams(false, 1), {
        'enable_thinking': false,
      });
      expect(AiReplyFilterService.buildThinkingParams(true, 2), {
        'reasoning_effort': 'low',
      });
      expect(AiReplyFilterService.buildThinkingParams(false, 2), {
        'reasoning_effort': 'none',
      });
    });

    test('none sends nothing', () {
      expect(AiReplyFilterService.buildThinkingParams(true, 3), isNull);
      expect(AiReplyFilterService.buildThinkingParams(false, 3), isNull);
    });

    test('clamps out-of-range mode', () {
      expect(AiReplyFilterService.buildThinkingParams(true, 99), isNull);
    });
  });
}
