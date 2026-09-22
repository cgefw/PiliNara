import 'dart:convert';

/// Null means the endpoint did not report a value; it does not mean zero hits.
class AiTokenUsage {
  const AiTokenUsage({this.input, this.output, this.cached, this.created});
  final int? input;
  final int? output;
  final int? cached;
  final int? created;

  factory AiTokenUsage.fromJson(Map data) {
    int? number(dynamic value) => value is int && value >= 0 ? value : null;
    final details = data['prompt_tokens_details'];
    final input = number(data['prompt_tokens'] ?? data['input_tokens']);
    final cached = number(
      (details is Map ? details['cached_tokens'] : null) ??
          data['prompt_cache_hit_tokens'] ??
          data['cached_tokens'],
    );
    return AiTokenUsage(
      input: input,
      output: number(data['completion_tokens'] ?? data['output_tokens']),
      cached: input != null && cached != null && cached > input ? null : cached,
      created: number(
        details is Map ? details['cache_creation_input_tokens'] : null,
      ),
    );
  }
}

/// SSE frames can cross UTF-8/network boundaries or contain several data lines.
Stream<Map<String, dynamic>> decodeAiSse(Stream<List<int>> bytes) async* {
  final data = <String>[];
  var sawEvent = false;
  await for (final line
      in bytes.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.startsWith(':')) continue;
    if (line.startsWith('data:')) {
      data.add(line.substring(5).trimLeft());
    } else if (line.isEmpty && data.isNotEmpty) {
      final value = data.join('\n');
      data.clear();
      if (value.trim() == '[DONE]') return;
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('无效的流式响应');
      }
      sawEvent = true;
      yield decoded;
    }
  }
  if (data.isNotEmpty) {
    final value = data.join('\n');
    if (value.trim() == '[DONE]') return;
    final decoded = jsonDecode(value);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('无效的流式响应');
    }
    sawEvent = true;
    yield decoded;
  }
  if (!sawEvent) throw const FormatException('接口未返回 SSE 流式响应');
}

/// Keeps reasoning separate from the final answer, for both response formats.
class AiCompletionContent {
  final _content = StringBuffer();
  String? _finishReason;
  bool _streaming = false;

  void add(Map data, {required bool streaming}) {
    _streaming |= streaming;
    final error = data['error'];
    if (error != null) {
      throw FormatException(
        error is Map ? '${error['message'] ?? error}' : '$error',
      );
    }
    final choices = data['choices'];
    if (choices is! List || choices.isEmpty) return; // usage-only SSE frame
    final choice = choices.first;
    if (choice is! Map) throw const FormatException('无效的响应选项');
    _finishReason = choice['finish_reason']?.toString() ?? _finishReason;
    final message = choice[streaming ? 'delta' : 'message'];
    final content = message is Map ? message['content'] : choice['text'];
    if (content is String) _content.write(content);
  }

  String finish() {
    if (_streaming && _finishReason == null) {
      throw const FormatException('流式响应提前结束');
    }
    if (_finishReason == 'length' || _finishReason == 'content_filter') {
      throw FormatException('响应未完整生成（$_finishReason）');
    }
    final content = _content.toString();
    if (content.trim().isEmpty) throw const FormatException('响应缺少最终内容');
    return content;
  }
}
