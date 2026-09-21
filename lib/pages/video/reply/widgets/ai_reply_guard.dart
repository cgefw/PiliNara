import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show ReplyInfo;
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class AiReplyGuard extends StatelessWidget {
  const AiReplyGuard({
    super.key,
    required this.reply,
    required this.child,
    this.isSubReply = false,
  });

  final ReplyInfo reply;
  final Widget child;
  final bool isSubReply;

  @override
  Widget build(BuildContext context) {
    if (!AiReplyFilterService.enabled) return child;
    final text = reply.content.message;
    if (text.trim().isEmpty) return child;
    final service = AiReplyFilterService.instance;
    final hash = AiReplyFilterService.contentHash(text);
    return Obx(() {
      final verdict = service.verdictOfHash(hash);
      if (verdict == null) {
        if (service.isFailed(hash)) return child;
        service.trackHash(hash, text);
        return const SizedBox.shrink();
      }
      if (!verdict.unsafe) return child;
      if (!Pref.aiReplyFilterRevealFiltered) {
        return const SizedBox.shrink();
      }
      if (service.isRevealed(hash)) return child;
      void showDetail() => _showDetail(context, hash, verdict);
      void reveal() => service.reveal(hash);
      return isSubReply
          ? _SubReplyFiltered(onReveal: reveal, onShowDetail: showDetail)
          : _ReplyFiltered(
              reason: verdict.reason,
              onReveal: reveal,
              onShowDetail: showDetail,
            );
    });
  }

  void _showDetail(
    BuildContext context,
    String hash,
    AiReplyVerdict verdict,
  ) {
    final service = AiReplyFilterService.instance;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AI 评论过滤'),
        content: Text(
          verdict.reason.isEmpty
              ? '该评论可能让人感到不适，已被 AI 过滤。'
              : '该评论可能让人感到不适，已被 AI 过滤。\n\n判定原因：${verdict.reason}',
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ),
          TextButton(
            onPressed: () {
              service.allowForever(hash);
              Get.back();
            },
            child: const Text('不再过滤'),
          ),
          TextButton(
            onPressed: () {
              service.reveal(hash);
              Get.back();
            },
            child: const Text('显示'),
          ),
        ],
      ),
    );
  }
}

class _ReplyFiltered extends StatelessWidget {
  const _ReplyFiltered({
    required this.reason,
    required this.onReveal,
    required this.onShowDetail,
  });

  final String reason;
  final VoidCallback onReveal;
  final VoidCallback onShowDetail;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onReveal,
        onLongPress: onShowDetail,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(56, 10, 16, 10),
          child: Row(
            children: [
              Icon(
                Icons.shield_outlined,
                size: 18,
                color: colorScheme.outline,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  reason.isEmpty
                      ? '已过滤可能令人不适的评论'
                      : '已过滤可能令人不适的评论（$reason）',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colorScheme.outline),
                ),
              ),
              TextButton(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                onPressed: onReveal,
                child: const Text('显示'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SubReplyFiltered extends StatelessWidget {
  const _SubReplyFiltered({
    required this.onReveal,
    required this.onShowDetail,
  });

  final VoidCallback onReveal;
  final VoidCallback onShowDetail;

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    return InkWell(
      onTap: onReveal,
      onLongPress: onShowDetail,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
        child: Row(
          children: [
            Icon(
              Icons.shield_outlined,
              size: 14,
              color: colorScheme.outline,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '已过滤可能令人不适的回复',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colorScheme.outline),
              ),
            ),
            Text(
              '显示',
              style: TextStyle(fontSize: 13, color: colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }
}
