import 'package:PiliPlus/common/widgets/custom_icon.dart';
import 'package:PiliPlus/grpc/reply.dart';
import 'package:PiliPlus/pages/setting/ai_reply_filter_setting.dart';
import 'package:PiliPlus/pages/setting/models/model.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/user_whitelist.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

List<SettingsModel> get replySettings => [
  getListBanWordModel(
    title: '关键词过滤',
    key: SettingBoxKey.banWordForReply,
    onChanged: (value) {
      ReplyGrpc.replyRegExp = value;
      ReplyGrpc.enableFilter = value.pattern.isNotEmpty;
    },
  ),
  getListUidWithNameModel(
    title: '屏蔽用户',
    getUidsMap: () => Pref.replyBlockedMids,
    setUidsMap: (mids) {
      Pref.replyBlockedMids = mids;
      ReplyGrpc.replyBlockedMids = mids;
    },
    onUpdate: () {},
  ),
  getListUidWithNameModel(
    title: '白名单用户',
    leading: const Icon(Icons.person_add_alt_1_outlined),
    emptySubtitle: '点击添加白名单用户',
    countSubtitleBuilder: (count) => '已加入白名单 $count 个用户',
    getUidsMap: () => Pref.whitelistMids,
    setUidsMap: UserWhitelist.save,
    onUpdate: () {},
  ),
  const SwitchModel(
    title: 'AI 评论过滤',
    subtitle: '进视频先检测首屏约 20 条，评论区下滑时继续；只显示通过检测的评论',
    leading: Icon(Icons.auto_awesome),
    setKey: SettingBoxKey.enableAiReplyFilter,
    defaultVal: false,
  ),
  NormalModel(
    title: 'AI 过滤设置',
    leading: const Icon(Icons.shield_outlined),
    getSubtitle: () => AiReplyFilterService.apiReady
        ? '当前模型：${Pref.aiModel}'
        : '未配置 AI 接口，点击前往设置',
    onTap: (context, _) => Get.to(() => const AiReplyFilterSetting()),
  ),
  SwitchModel(
    title: '屏蔽带货评论',
    subtitle: '过滤包含商品推广的评论',
    leading: const Icon(CustomIcons.shopping_bag_not_interested),
    setKey: SettingBoxKey.antiGoodsReply,
    defaultVal: false,
    onChanged: (value) => ReplyGrpc.antiGoodsReply = value,
  ),
  SwitchModel(
    title: '保留 UP 主自己的评论',
    subtitle: '保留 UP 主发布的评论，黑名单和带货屏蔽仍会生效',
    leading: const Icon(Icons.person_outline),
    setKey: SettingBoxKey.keepUpOwnerReply,
    defaultVal: true,
    onChanged: (value) => ReplyGrpc.keepUpOwnerReply = value,
  ),
  SwitchModel(
    title: '保留置顶评论',
    subtitle: '保留 UP 主置顶的评论，黑名单和带货屏蔽仍会生效',
    leading: const Icon(Icons.vertical_align_top_outlined),
    setKey: SettingBoxKey.keepUpTopReply,
    defaultVal: true,
    onChanged: (value) => ReplyGrpc.keepUpTopReply = value,
  ),
  SwitchModel(
    title: '保留 UP 主觉得很赞的评论',
    subtitle: '保留 UP 主点赞的评论，黑名单和带货屏蔽仍会生效',
    leading: const Icon(Icons.thumb_up_outlined),
    setKey: SettingBoxKey.keepUpLikeReply,
    defaultVal: false,
    onChanged: (value) => ReplyGrpc.keepUpLikeReply = value,
  ),
  SwitchModel(
    title: '保留 UP 主参与回复的评论',
    subtitle: '保留 UP 主回复过的评论，黑名单和带货屏蔽仍会生效',
    leading: const Icon(Icons.mark_chat_read_outlined),
    setKey: SettingBoxKey.keepUpReplyReply,
    defaultVal: false,
    onChanged: (value) => ReplyGrpc.keepUpReplyReply = value,
  ),
];
