import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/pages/setting/ai_reply_stats.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class AiReplyFilterSetting extends StatefulWidget {
  const AiReplyFilterSetting({super.key});

  @override
  State<AiReplyFilterSetting> createState() => _AiReplyFilterSettingState();
}

class _AiReplyFilterSettingState extends State<AiReplyFilterSetting> {
  Future<String?> _showTextDialog({
    required String title,
    required String hint,
    String initial = '',
    int maxLines = 5,
    String confirmText = '确定',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: maxLines,
          autofocus: true,
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
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
            onPressed: () => Get.back(result: controller.text.trim()),
            child: Text(confirmText),
          ),
        ],
      ),
    );
  }

  Future<void> _editCriteria() async {
    final result = await _showTextDialog(
      title: '自定义过滤标准',
      hint: '留空使用默认标准。例如：过滤所有剧透内容；不要过滤谐音梗',
      initial: Pref.aiReplyFilterCriteria,
      maxLines: 6,
    );
    if (result == null) return;
    Pref.aiReplyFilterCriteria = result;
    AiReplyFilterService.instance.onCriteriaChanged();
    if (mounted) setState(() {});
    SmartDialog.showToast(result.isEmpty ? '已恢复默认标准' : '已保存，评论将按新标准重新判定');
  }

  Future<void> _testFilter() async {
    final text = await _showTextDialog(
      title: '测试过滤效果',
      hint: '输入一段评论文本进行检测',
      maxLines: 4,
      confirmText: '检测',
    );
    if (text == null || text.isEmpty) return;
    SmartDialog.showLoading();
    try {
      final verdict = await AiReplyFilterService.instance.checkNow(text);
      SmartDialog.dismiss();
      if (!mounted) return;
      if (verdict == null) {
        SmartDialog.showToast('接口未返回判定结果');
        return;
      }
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(verdict.unsafe ? '会被过滤' : '不会被过滤'),
          content: Text(
            verdict.unsafe
                ? 'AI 判定该内容令人不适'
                      '${verdict.reason.isEmpty ? '' : '，原因：${verdict.reason}'}。'
                : 'AI 判定该内容不会令人不适。',
          ),
          actions: [
            TextButton(onPressed: Get.back, child: const Text('确定')),
          ],
        ),
      );
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast(e.toString());
    }
  }

  Future<void> _clearCache() async {
    final confirmed = await showConfirmDialog(
      context: context,
      title: const Text('清除过滤缓存？'),
      content: const Text('清除后，已判定过的评论会重新请求 AI 检测。'),
    );
    if (!confirmed) return;
    await AiReplyFilterService.instance.clearCache();
    if (mounted) setState(() {});
    SmartDialog.showToast('已清除');
  }

  String _thinkingParamLabel(int value) => switch (value) {
    0 => 'thinking.type（DeepSeek/火山方舟等，推荐）',
    1 => 'enable_thinking（通义/硅基流动等）',
    2 => 'reasoning_effort（OpenAI o 系列）',
    _ => '不发送参数（用接口默认；DeepSeek 默认会思考）',
  };

  String _promptPreview(String value, String fallback) {
    final text = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty) return fallback;
    return text.length > 40 ? '${text.substring(0, 40)}…' : text;
  }

  Future<void> _selectThinkingParam() async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Thinking 参数格式'),
        children: [
          for (var i = 0; i < 4; i++)
            SimpleDialogOption(
              onPressed: () => Get.back(result: i),
              child: Text(
                _thinkingParamLabel(i),
                style: const TextStyle(fontSize: 14),
              ),
            ),
        ],
      ),
    );
    if (value == null) return;
    Pref.aiReplyFilterThinkingParam = value;
    if (mounted) setState(() {});
  }

  Future<void> _editSystemPrompt() async {
    final result = await _showTextDialog(
      title: '自定义 System 提示词',
      hint: '留空恢复默认。这里定义完整的审查规则',
      initial: Pref.aiReplyFilterSystemPrompt,
      maxLines: 10,
    );
    if (result == null) return;
    Pref.aiReplyFilterSystemPrompt = result;
    AiReplyFilterService.instance.onCriteriaChanged();
    if (mounted) setState(() {});
    SmartDialog.showToast(result.isEmpty ? '已恢复默认 System 提示词' : '已保存，将按新提示词重新判定');
  }

  Future<void> _editUserPrompt() async {
    final result = await _showTextDialog(
      title: '自定义 User 提示词',
      hint: '留空恢复默认。可用占位符：{comments} 评论JSON、{count} 条数、'
          '{title} 视频标题、{desc} 视频简介',
      initial: Pref.aiReplyFilterUserPrompt,
      maxLines: 10,
    );
    if (result == null) return;
    Pref.aiReplyFilterUserPrompt = result;
    AiReplyFilterService.instance.onCriteriaChanged();
    if (mounted) setState(() {});
    SmartDialog.showToast(result.isEmpty ? '已恢复默认 User 提示词' : '已保存，将按新提示词重新判定');
  }

  Future<void> _editBatchSize() => _editIntSetting(
    title: '单批评论数',
    value: Pref.aiReplyFilterBatchSize,
    min: 5,
    max: 50,
    divisions: 9,
    suffix: ' 条',
    onConfirm: (value) => Pref.aiReplyFilterBatchSize = value,
  );

  Future<void> _editConcurrency() => _editIntSetting(
    title: '并行请求数',
    value: Pref.aiReplyFilterConcurrency,
    min: 1,
    max: 8,
    divisions: 7,
    suffix: ' 个',
    onConfirm: (value) => Pref.aiReplyFilterConcurrency = value,
  );

  Future<void> _editIntSetting({
    required String title,
    required int value,
    required int min,
    required int max,
    required int divisions,
    required String suffix,
    required ValueChanged<int> onConfirm,
  }) async {
    var current = value;
    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$current$suffix'),
              Slider(
                value: current.toDouble(),
                min: min.toDouble(),
                max: max.toDouble(),
                divisions: divisions,
                label: '$current$suffix',
                onChanged: (value) =>
                    setDialogState(() => current = value.round()),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: Get.back, child: const Text('取消')),
            TextButton(
              onPressed: () {
                onConfirm(current);
                Get.back();
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final apiReady = AiReplyFilterService.apiReady;
    final service = AiReplyFilterService.instance;
    final criteria = Pref.aiReplyFilterCriteria.trim();
    return Scaffold(
      appBar: AppBar(title: const Text('AI 评论过滤设置')),
      body: ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(context).bottom + 100,
        ),
        children: [
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        apiReady
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 20,
                        color: apiReady
                            ? colorScheme.primary
                            : colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text('接口状态', style: theme.textTheme.titleMedium),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    apiReady
                        ? '模型：${Pref.aiModel}\n地址：${Pref.aiApiUrl}'
                        : '尚未配置 AI 接口，AI 评论过滤不会生效。',
                    style: theme.textTheme.bodySmall,
                  ),
                  if (!apiReady) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: () => Get.toNamed('/aiSetting'),
                      icon: const Icon(Icons.settings, size: 18),
                      label: const Text('前往配置'),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SetSwitchItem(
            title: '启用 AI 评论过滤',
            subtitle: '评论加载后立即送检，仅显示通过检测的评论',
            leading: Icon(Icons.auto_awesome),
            setKey: SettingBoxKey.enableAiReplyFilter,
            defaultVal: false,
          ),
          const SetSwitchItem(
            title: '显示被过滤的评论',
            subtitle: '开启后被过滤的评论以折叠提示显示，可点击查看原文',
            leading: Icon(Icons.visibility_off_outlined),
            setKey: SettingBoxKey.aiReplyFilterRevealFiltered,
            defaultVal: false,
          ),
          ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('AI 接口设置'),
            subtitle: Text(apiReady ? '修改接口地址、API Key 或模型' : '配置 OpenAI 兼容接口'),
            onTap: () => Get.toNamed('/aiSetting'),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('自定义过滤标准'),
            subtitle: Text(
              criteria.isEmpty
                  ? '默认：过滤辱骂、引战、说教、低俗、歧视等令人不适的内容'
                  : criteria,
            ),
            onTap: _editCriteria,
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('自定义 System 提示词'),
            subtitle: Text(
              _promptPreview(Pref.aiReplyFilterSystemPrompt, '默认：内置审查规则'),
            ),
            onTap: _editSystemPrompt,
          ),
          ListTile(
            leading: const Icon(Icons.chat_outlined),
            title: const Text('自定义 User 提示词'),
            subtitle: Text(
              _promptPreview(
                Pref.aiReplyFilterUserPrompt,
                '默认：含 {title}/{desc}/{comments} 占位符模板',
              ),
            ),
            onTap: _editUserPrompt,
          ),
          ListTile(
            leading: const Icon(Icons.science_outlined),
            title: const Text('测试过滤效果'),
            subtitle: const Text('输入一段文字，立即用当前配置检测'),
            onTap: _testFilter,
          ),
          ListTile(
            leading: const Icon(Icons.insights_outlined),
            title: const Text('争议统计'),
            subtitle: const Text('按视频标签统计争议程度，样本达标才计入'),
            onTap: () => Get.to(() => const AiReplyStatsPage()),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('清除过滤缓存'),
            subtitle: Obx(() => Text('已缓存 ${service.cacheCount} 条判定结果')),
            onTap: _clearCache,
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('启用 Thinking 推理'),
            subtitle: const Text('DeepSeek 等接口默认思考且很慢，建议保持关闭'),
            secondary: const Icon(Icons.psychology_outlined),
            value: Pref.enableAiReplyFilterThinking,
            onChanged: (value) {
              Pref.enableAiReplyFilterThinking = value;
              setState(() {});
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('Thinking 参数格式'),
            subtitle: Text(
              _thinkingParamLabel(Pref.aiReplyFilterThinkingParam),
            ),
            onTap: _selectThinkingParam,
          ),
          ListTile(
            leading: const Icon(Icons.batch_prediction_outlined),
            title: const Text('单批评论数'),
            subtitle: Text('每次请求最多送检 ${Pref.aiReplyFilterBatchSize} 条'),
            onTap: _editBatchSize,
          ),
          ListTile(
            leading: const Icon(Icons.bolt_outlined),
            title: const Text('并行请求数'),
            subtitle: Text('同时进行 ${Pref.aiReplyFilterConcurrency} 个批次请求'),
            onTap: _editConcurrency,
          ),
          const SizedBox(height: 8),
          Card(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            color: colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '说明：\n'
                '• 进入视频先检测首屏约 20 条，评论区下滑时会自动预检下一页\n'
                '• 只显示通过检测的评论；检测中的评论显示为骨架占位，结果返回后逐条出现\n'
                '• 被过滤的评论默认完全不显示，可开启「显示被过滤的评论」查看\n'
                '• 判定会带上视频标题、简介与标签；长按评论可选择「AI 重新检测」\n'
                '• DeepSeek 默认开启思考且响应很慢，请把「Thinking 参数格式」设为 thinking.type，保持开关关闭\n'
                '• 修改提示词/过滤标准后缓存自动失效并重新判定；判定结果跨视频共享',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
