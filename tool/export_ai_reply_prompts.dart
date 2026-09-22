import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/ai_reply_filter/ai_reply_protocol.dart';

void main() => stdout.writeln(
  jsonEncode({
    'system': AiReplyProtocol.systemPrompt,
    'user': AiReplyProtocol.userPrompt,
  }),
);
