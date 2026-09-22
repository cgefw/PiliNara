enum AiThinkingParam {
  thinkingType,
  enableThinking,
  reasoningEffort,
  none,
  auto,
}

/// Request policy for the comment classifier, not a global chat-mode override.
class AiReplyApiPolicy {
  AiReplyApiPolicy({
    required this.url,
    required this.model,
    required this.thinking,
    required this.param,
    required this.compact,
  });
  final String url;
  final String model;
  final bool thinking;
  final int param;
  final bool compact;

  static String normalizeUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');
  String get host => Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
  bool get isDeepSeek => host == 'api.deepseek.com';
  bool get isDashScope =>
      const {
        'dashscope.aliyuncs.com',
        'dashscope-intl.aliyuncs.com',
        'dashscope-us.aliyuncs.com',
      }.contains(host) ||
      host.endsWith('.maas.aliyuncs.com');
  bool get isQwen =>
      isDashScope &&
      (model.trim().toLowerCase().startsWith('qwen') ||
          model.trim().toLowerCase().startsWith('qwq'));
  String get _model => model.trim().toLowerCase();
  bool get onlyThinking =>
      isQwen &&
      (_model.startsWith('qwq') ||
          _model.contains('-thinking') ||
          const {
            'qwen3.8-2.4t-a95b',
            'qwen3.7-max-preview',
            'qwen3.7-max-2026-05-17',
          }.contains(_model));
  bool get hybrid =>
      isQwen &&
      !onlyThinking &&
      !_model.contains('coder') &&
      !_model.contains('instruct') &&
      !_model.contains('omni') &&
      (_model.startsWith('qwen3') ||
          RegExp(r'^qwen-(plus|flash|turbo)(-|$)').hasMatch(_model));
  bool get effectiveThinking =>
      onlyThinking ||
      (hybrid && param == AiThinkingParam.none.index) ||
      (hybrid || !isQwen) && thinking;
  bool get useStreaming =>
      effectiveThinking &&
      (isQwen || param == AiThinkingParam.enableThinking.index);

  static Map<String, dynamic>? thinkingBody(bool enabled, int param) =>
      switch (param) {
        0 => {
          'thinking': {'type': enabled ? 'enabled' : 'disabled'},
        },
        1 => {'enable_thinking': enabled},
        2 => {'reasoning_effort': enabled ? 'low' : 'none'},
        _ => null,
      };

  Map<String, dynamic> get body {
    final result = <String, dynamic>{};
    if (param == AiThinkingParam.auto.index) {
      if (isDeepSeek) result.addAll(thinkingBody(thinking, 0)!);
      if (hybrid) result['enable_thinking'] = thinking;
    } else if (!onlyThinking) {
      result.addAll(thinkingBody(thinking, param) ?? {});
    }
    if (isQwen) {
      if (effectiveThinking) {
        // Pure thinking models must not receive enable_thinking:false.
        // Budget is supported by Qwen3; QwQ uses its normal output limit.
        if ((_model.startsWith('qwen3') || hybrid) &&
            !result.containsKey('reasoning_effort')) {
          result['thinking_budget'] = 1024;
        }
        result['max_completion_tokens'] = 4096;
      } else {
        if (!_model.contains('coder') && !_model.contains('math')) {
          result['response_format'] = {'type': 'json_object'};
        }
        result['temperature'] = 0;
        result['max_tokens'] = compact ? 1024 : 4096;
      }
    } else if (isDeepSeek) {
      result['response_format'] = {'type': 'json_object'};
      if (!thinking) {
        result['temperature'] = 0;
        result['max_tokens'] = compact ? 1024 : 4096;
      }
    }
    return result;
  }
}
