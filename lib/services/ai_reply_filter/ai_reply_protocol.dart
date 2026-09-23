import 'dart:convert';

import 'package:crypto/crypto.dart' show md5;

class AiReplyVerdict {
  const AiReplyVerdict({required this.unsafe, this.reason = ''});
  final bool unsafe;
  final String reason;
}

/// Pure protocol code: no preferences, network, UI or persistence dependencies.
abstract final class AiReplyProtocol {
  static const systemPrompt = '''你是视频评论区的评论过滤分类器。你的目标是尽量过滤具有任何攻击性、轻蔑、羞辱、嘲讽、阴阳怪气、挑衅、居高临下、嫌恶或贬损效果的评论，同时保留正常讨论、批评、反驳、纠错和无攻击性的玩梗。不要猜测评论者内心动机，只判断文字在正常中文互联网语境中的实际表达效果。低俗内容不过滤。每条评论独立判断，不得根据同一批次其他评论调整尺度。语义和语气强度相近的评论应得到相近结果。

应过滤：辱骂、侮辱、人身攻击、诅咒、威胁；嘲笑他人的智商、能力、常识、资格、身份、外貌、消费能力等；羞辱、轻蔑、嫌弃、挖苦、贬低；阴阳怪气、反讽贬低、挑衅式反问；给他人恶意扣动机、贴贬义标签；居高临下地训斥、教育或贬低别人；针对人、群体、作品或行为使用嫌恶、羞辱、贬损性措辞，如“恶心”“没品”“丢人”“可笑”“尴尬”等；地域、性别、种族、职业、外貌、IP属地等歧视或攻击；真实广告、引流、诈骗、违法推广、重复垃圾信息；真实、具体的严重血腥、尸体、残肢、体液等引起生理不适的内容。即使评论包含合理观点，只要同时存在明确的攻击、轻蔑、阴阳、羞辱、嫌恶或贬损表达，仍然过滤。

😅、流汗黄豆、呵呵、笑哭、反问句、感叹号，以及“有什么意义”“哪来的”“这都不知道”“又来了”“我说白了”等，可以强化嘲讽、阴阳、轻蔑或挑衅语气。
网络梗与复制文案：网络梗本身不过滤，但借梗攻击、羞辱或贬低别人仍然过滤。对于看起来像广告、交易或诈骗的文案，如果文本没有真实联系方式、链接、账号、交易渠道等可执行推广路径，同时具有荒诞、反差或复制文案结构，应优先理解为玩梗。如果存在明确联系方式、交易渠道、下单方式、引流信息或真实招揽行为，则按广告或诈骗过滤。

校准案例：不过滤：“设计图已经泄露了，实际应该是9GB，不是12GB。”正常纠错。“这个做法会影响其他人的体验。”正常批评。“我觉得这种做法不太尊重其他人。”正常评价。“美元收入直接换算成人民币参考意义有限。”正常观点。“转到AI具体是指什么？”正常质疑。“我觉得换18没什么必要。”正常观点。“我觉得这种消费方式有点过度。”普通批评。“荧光棒听到塑料英文变红，剧烈燃烧，发出尖锐的爆鸣”荒诞玩梗，没有实际攻击对象。“代抢iPhone18，转我6000，没抢到退5950”无真实交易路径，属于荒诞复制文案/反转玩梗。过滤：“😅😅😅设计图都泄露了，iPhone18用1.5g拼出来的9gb运存，哪来的12g?”事实反驳中带有阴阳嘲讽。“线下还这样搞，影响别人体验，好恶心[呆]”批评行为同时使用嫌恶性措辞。“这种做法真的很不尊重其他人，坐前排带这种节奏觉得真的挺没品的”带有贬损性措辞。“挣美元折合人民币是什么意思？他们挣美元当人民币花吗？”反问式挖苦。“什么叫转到AI了，发了几篇CCF-A？”用资格反问嘲讽对方。“总结：我换不起18，你们也不能换”虚构他人动机并嘲讽。“这些人就是被消费主义洗脑了。想当年某app广告，贷款过生日哈哈哈”贬低群体判断能力并带嘲笑。“想买iPhone18的加微信xxx，6000代抢，先付款”存在明确交易和引流路径。“被ai狂轰滥炸炸懵了是这样的”嘲讽贬低。''';

  static const legacyUserPrompt =
      '只输出JSON对象，格式为{"c":{}}，c必须覆盖每条输入编号。值为类别：0保留；1辱骂威胁；2轻蔑嘲讽羞辱嫌恶；3歧视；4广告诈骗垃圾推广；5真实血腥不适；6其他命中用户规则。校准中的1表示过滤，最终按类别编码，不输出解释。\n'
      '视频标题：{title}\n'
      '简介：{desc}\n'
      '评论（共{count}条，每项为[编号,文本]）：{comments}';

  static const userPrompt =
      '只输出JSON对象，格式为{"c":{}}，c必须覆盖每条输入编号。值为类别：0保留；1辱骂威胁；2轻蔑嘲讽羞辱嫌恶；3歧视；4广告诈骗垃圾推广；5真实血腥不适；6其他命中用户规则。最终按类别编码，不输出解释。\n'
      '评论（共{count}条，每项为[编号,文本]）：{comments}';

  // Preserve explicitly customized legacy templates, with separate cache identity.
  static const binaryUserPrompt =
      '只输出JSON对象，结构示例（不是本批答案）：{"v":{},"r":{}}。v的键为每条输入编号，值为0保留或1过滤，必须覆盖全部编号；r可省略，仅给过滤项提供至多6字原因，键为从0开始的下标。\n'
      '视频标题：{title}\n'
      '简介：{desc}\n'
      '评论（共{count}条，每项为[编号,文本]）：{comments}';

  static bool isCompactTemplate(String template) =>
      template == userPrompt ||
      template == legacyUserPrompt ||
      template == binaryUserPrompt;

  static String resolveUserTemplate(String template) =>
      template.isEmpty || template == legacyUserPrompt ? userPrompt : template;

  static String normalize(String text) =>
      text.trim().replaceAll(RegExp(r'\s+'), ' ');
  static String hash(String text) =>
      md5.convert(utf8.encode(normalize(text))).toString();
  static String fingerprint(String system, String user) =>
      md5.convert(utf8.encode(jsonEncode([system, user]))).toString();

  // Keep the end of long comments, where a reversal or insult often occurs.
  static String truncate(String text, int limit) => text.length <= limit
      ? text
      : '${text.substring(0, limit * 2 ~/ 3)}…[中间省略]…${text.substring(text.length - limit ~/ 3)}';

  static String buildUserPrompt(
    String template, {
    required List<String> texts,
    bool compact = false,
  }) {
    final payload = jsonEncode(
      compact
          ? [
              for (var i = 0; i < texts.length; i++) [i, texts[i]],
            ]
          : [
              for (var i = 0; i < texts.length; i++) {'i': i, 'text': texts[i]},
            ],
    );
    final values = {
      'count': '${texts.length}',
      'title': '',
      'desc': '',
      'comments': payload,
    };
    // Strip built-in legacy context lines and blank legacy placeholders.
    // One pass: braces in comment text are data, never template code.
    var result = template
        .replaceAll('视频标题：{title}\n', '')
        .replaceAll('简介：{desc}\n', '')
        .replaceAllMapped(
          RegExp(r'\{(count|title|desc|comments)\}'),
          (match) => values[match[1]]!,
        );
    if (!template.contains('{comments}')) result = '$result\n$payload';
    return result;
  }

  static bool? _unsafe(dynamic value) => switch (value) {
    true || 1 || '1' || 'true' => true,
    false || 0 || '0' || 'false' => false,
    _ => null,
  };

  static Map<int, AiReplyVerdict> parse(
    String raw,
    int count, {
    bool requireCodes = false,
  }) {
    if (count <= 0) return const {};
    var text = raw
        .trim()
        .replaceFirst(RegExp(r'^```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```$'), '')
        .trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      // Legacy providers sometimes surround their JSON array with prose.
      final start = text.indexOf('['), end = text.lastIndexOf(']');
      if (start < 0 || end <= start || text.startsWith('{')) return const {};
      try {
        decoded = jsonDecode(text.substring(start, end + 1));
      } catch (_) {
        return const {};
      }
    }
    if (decoded is Map && decoded.containsKey('c')) {
      final codes = decoded['c'];
      const reasons = [
        '',
        '辱骂或威胁',
        '轻蔑嘲讽或贬损',
        '歧视攻击',
        '广告诈骗或垃圾推广',
        '血腥不适',
        '命中自定义规则',
      ];
      if (decoded.containsKey('v') ||
          codes is! Map ||
          codes.length != count ||
          !List.generate(count, (i) => '$i').every(codes.containsKey) ||
          codes.values.any((v) => v is! int || v < 0 || v >= reasons.length)) {
        return const {};
      }
      return {
        for (var i = 0; i < count; i++)
          i: AiReplyVerdict(
            unsafe: codes['$i'] != 0,
            reason: reasons[codes['$i'] as int],
          ),
      };
    }
    if (requireCodes) return const {};
    if (decoded is Map && decoded.containsKey('v')) {
      final rawValues = decoded['v'];
      final values =
          rawValues is Map &&
              rawValues.length == count &&
              List.generate(count, (i) => '$i').every(rawValues.containsKey)
          ? [for (var i = 0; i < count; i++) rawValues['$i']]
          : rawValues;
      // A positional response is usable only when ALL positions are present.
      if (values is! List ||
          values.length != count ||
          values.any((v) => v is! int || (v != 0 && v != 1))) {
        return const {};
      }
      final reasons = decoded['r'];
      return {
        for (var i = 0; i < count; i++)
          i: AiReplyVerdict(
            unsafe: values[i] == 1,
            reason: values[i] == 1 && reasons is Map
                ? _reason(reasons['$i'])
                : '',
          ),
      };
    }
    if (decoded is Map) decoded = decoded['results'] ?? decoded['verdicts'];
    if (decoded is! List) return const {};
    final indexed = <int, AiReplyVerdict>{};
    for (final item in decoded) {
      if (item is! Map) continue;
      final rawIndex = item['i'] ?? item['index'] ?? item['id'];
      final index = rawIndex is int
          ? rawIndex
          : rawIndex is String
          ? int.tryParse(rawIndex)
          : null;
      final unsafe = _unsafe(item['u'] ?? item['unsafe']);
      if (index == null || index < 0 || index > count || unsafe == null) {
        continue;
      }
      if (indexed.containsKey(index)) {
        return const {}; // conflicting/duplicate ID
      }
      indexed[index] = AiReplyVerdict(
        unsafe: unsafe,
        reason: _reason(item['r'] ?? item['reason']),
      );
    }
    if (indexed.containsKey(0)) {
      indexed.remove(count);
      return indexed;
    }
    // Partial 1-based responses are ambiguous. Never shift them onto another comment.
    if (indexed.length == count && indexed.containsKey(count)) {
      return {for (final e in indexed.entries) e.key - 1: e.value};
    }
    return const {};
  }

  static String _reason(dynamic value) {
    final reason = value is String ? value.trim() : '';
    return reason.length <= 30 ? reason : reason.substring(0, 30);
  }
}
