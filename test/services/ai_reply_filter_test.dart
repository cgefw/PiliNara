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
    test('parses plain json array', () {
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":1,"u":true,"r":"辱骂"},{"i":2,"u":false,"r":""}]',
        2,
      );
      expect(result.length, 2);
      expect(result[1]!.unsafe, isTrue);
      expect(result[1]!.reason, '辱骂');
      expect(result[2]!.unsafe, isFalse);
    });

    test('parses fenced json with surrounding text', () {
      const raw = '分析结果如下：\n'
          '```json\n'
          '[{"i": 1, "u": 1, "r": "引战"}]\n'
          '```\n';
      final result = AiReplyFilterService.parseVerdicts(raw, 1);
      expect(result[1]!.unsafe, isTrue);
      expect(result[1]!.reason, '引战');
    });

    test('ignores out-of-range and invalid entries', () {
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":0,"u":true},{"i":5,"u":true},{"x":1},{"i":"2","u":"true"}]',
        2,
      );
      expect(result.keys, [2]);
      expect(result[2]!.unsafe, isTrue);
    });

    test('returns empty on invalid json', () {
      expect(AiReplyFilterService.parseVerdicts('not json', 1), isEmpty);
      expect(AiReplyFilterService.parseVerdicts('{"a":1}', 1), isEmpty);
    });

    test('truncates long reason', () {
      final long = List.filled(50, '原').join();
      final result = AiReplyFilterService.parseVerdicts(
        '[{"i":1,"u":true,"r":"$long"}]',
        1,
      );
      expect(result[1]!.reason.length, 30);
    });
  });

  group('buildPrompt', () {
    test('includes criteria and numbered texts', () {
      final (system, user) = AiReplyFilterService.buildPrompt(
        ['第一条', '第二条'],
        criteria: '过滤剧透',
      );
      expect(system, contains('过滤剧透'));
      expect(user, contains('1. 第一条'));
      expect(user, contains('2. 第二条'));
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
}
