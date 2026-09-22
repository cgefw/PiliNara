import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_stats.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class AiReplyStatsPage extends StatefulWidget {
  const AiReplyStatsPage({super.key});

  @override
  State<AiReplyStatsPage> createState() => _AiReplyStatsPageState();
}

class _AiReplyStatsPageState extends State<AiReplyStatsPage> {
  int _minVideoSamples = 10;
  int _minVideos = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final stats = AiReplyStats.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('评论争议统计')),
      body: Obx(() {
        final _ = stats.revision.value;
        final enabled = Pref.enableAiReplyStats;
        final tags = enabled
            ? stats.tagStats(
                minVideoSamples: _minVideoSamples,
                minVideos: _minVideos,
              )
            : const <AiTagStat>[];
        return ListView(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
          ),
          children: [
            SwitchListTile(
              title: const Text('启用争议统计'),
              subtitle: const Text('关闭后不再记录新的判定结果，已有数据保留'),
              secondary: const Icon(Icons.insights_outlined),
              value: enabled,
              onChanged: (value) {
                Pref.enableAiReplyStats = value;
                setState(() {});
              },
            ),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('已统计', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      '视频 ${stats.videoCount} 个 · 评论样本 ${stats.commentCount} 条 · '
                      '判定不适 ${stats.unsafeCount} 条',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            _buildSlider(
              theme: theme,
              icon: Icons.filter_alt_outlined,
              title: '每个视频最少样本数',
              value: _minVideoSamples,
              min: 5,
              max: 50,
              divisions: 9,
              onChanged: (value) => setState(() => _minVideoSamples = value),
            ),
            _buildSlider(
              theme: theme,
              icon: Icons.video_library_outlined,
              title: '每个标签最少视频数',
              value: _minVideos,
              min: 1,
              max: 10,
              divisions: 9,
              onChanged: (value) => setState(() => _minVideos = value),
            ),
            if (!enabled)
              const ListTile(
                leading: Icon(Icons.info_outline),
                title: Text('统计已关闭'),
                subtitle: Text('开启后，AI 判定过的评论会按视频标签累计统计'),
              )
            else if (tags.isEmpty)
              Padding(
                padding: const EdgeInsets.all(32),
                child: Center(
                  child: Text(
                    '暂无达标样本\n继续浏览视频评论后会逐步积累',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colorScheme.outline),
                  ),
                ),
              )
            else ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(
                  '争议标签排行（不适评论占比，视频等权平均）',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              ...tags.map(
                (tag) => ListTile(
                  leading: const Icon(Icons.tag),
                  title: Text(tag.tag),
                  subtitle: Text(
                    '${tag.videoCount} 个视频 · ${tag.sampleCount} 条样本 · 不适 ${tag.unsafeCount} 条',
                  ),
                  trailing: Text(
                    '${(tag.avgRatio * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      color: colorScheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  onTap: () => _showTagVideos(context, tag),
                ),
              ),
            ],
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('清除统计数据'),
              onTap: () => _clear(stats),
            ),
            const SizedBox(height: 8),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              color: colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  '统计口径：\n'
                  '• 仅统计拿到 AI 判定结果的评论，请求失败或放行的不计入\n'
                  '• 每个视频需达到「最少样本数」才纳入；每个标签需包含至少 N 个合格视频才参与排名\n'
                  '• 标签取自视频详情接口，最多取前 10 个；标签按所含视频的平均不适占比排序（视频等权，避免大视频主导）\n'
                  '• 同一内容只判定一次，重复评论不会重复计数；样本随使用逐步积累\n'
                  '• 关闭「启用争议统计」后停止记录，已有数据保留在本地',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _buildSlider({
    required ThemeData theme,
    required IconData icon,
    required String title,
    required int value,
    required int min,
    required int max,
    required int divisions,
    required ValueChanged<int> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text('当前：$value'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Slider(
            value: value.toDouble(),
            min: min.toDouble(),
            max: max.toDouble(),
            divisions: divisions,
            label: '$value',
            onChanged: (v) => onChanged(v.round()),
          ),
        ),
      ],
    );
  }

  void _showTagVideos(BuildContext context, AiTagStat tag) {
    final videos = AiReplyStats.instance
        .videosOfTag(tag.tag, minVideoSamples: _minVideoSamples)
        .take(50)
        .toList();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tag.tag),
        content: SizedBox(
          width: 400,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: videos.length,
            itemBuilder: (context, index) {
              final video = videos[index];
              final title = video.title;
              return ListTile(
                dense: true,
                title: Text(
                  title == null || title.isEmpty ? 'oid:${video.oid}' : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text('不适 ${video.unsafe}/${video.total}'),
                trailing: Text(
                  '${(video.ratio * 100).toStringAsFixed(1)}%',
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(onPressed: Get.back, child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _clear(AiReplyStats stats) async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('清除统计数据？'),
      content: const Text('将删除所有已积累的争议统计数据，无法恢复。'),
    );
    if (!confirmed) return;
    await stats.clear();
    SmartDialog.showToast('已清除');
  }
}
