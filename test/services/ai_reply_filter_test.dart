import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('contentHash', () {
    test('stable and ignores whitespace and case', () {
      final a = AiReplyFilterService.contentHash('Hello  World');
      final b = AiReplyFilterService.contentHash('  hello\tworld ');
      expect(a, b);
      expect(a, AiReplyFilterService.contentHash('Hello World'));
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
      const raw = '分析结果如下：\n'
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

  group('buildPrompt', () {
    test('includes criteria and numbered json payload', () {
      final (system, user) = AiReplyFilterService.buildPrompt(
        ['第一条', '第二条'],
        criteria: '过滤剧透',
      );
      expect(system, contains('过滤剧透'));
      expect(user, contains('"i":0'));
      expect(user, contains('"i":1'));
      expect(user, contains('第一条'));
      expect(user, contains('第二条'));
    });

    test('uses default system prompt without criteria', () {
      final (system, _) = AiReplyFilterService.buildPrompt(['x']);
      expect(system, AiReplyFilterService.defaultSystemPrompt);
    });
  });

  group('criteriaFingerprint', () {
    test('changes with criteria', () {
      expect(
        AiReplyFilterService.criteriaFingerprint(),
        isNot(AiReplyFilterService.criteriaFingerprint('新标准')),
      );
    });
  });

  group('buildThinkingParams', () {
    test('returns null when disabled', () {
      expect(AiReplyFilterService.buildThinkingParams(false, 0), isNull);
    });

    test('returns params by mode', () {
      expect(AiReplyFilterService.buildThinkingParams(true, 0), {
        'enable_thinking': true,
      });
      expect(AiReplyFilterService.buildThinkingParams(true, 1), {
        'thinking': {'type': 'enabled'},
      });
      expect(AiReplyFilterService.buildThinkingParams(true, 2), {
        'reasoning_effort': 'low',
      });
    });

    test('clamps out-of-range mode', () {
      expect(AiReplyFilterService.buildThinkingParams(true, 99), {
        'reasoning_effort': 'low',
      });
    });
  });
}
