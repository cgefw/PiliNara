import 'dart:io';
import 'dart:ui' as ui;

import 'package:PiliPlus/pages/setting/ai_reply_filter_setting.dart';
import 'package:PiliPlus/pages/setting/widgets/switch_item.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_filter_service.dart';
import 'package:PiliPlus/services/ai_reply_filter/ai_reply_stats.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  final font = Platform.environment['AI_REPLY_UI_FONT'];
  final output = Platform.environment['AI_REPLY_UI_PREVIEW_DIR'];
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('reply-settings-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('settings');
    GStorage.localCache = await Hive.openBox('cache');
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    if (font != null) {
      await (FontLoader(
        'PreviewChinese',
      )..addFont(File(font).readAsBytes().then(ByteData.sublistView))).load();
    }
  });
  setUp(() async {
    await GStorage.setting.clear();
    await GStorage.setting.putAll({
      SettingBoxKey.aiApiUrl: 'https://api.deepseek.com',
      SettingBoxKey.aiModel: 'deepseek-flash',
      SettingBoxKey.enableAiReplyFilter: true,
      SettingBoxKey.aiReplyFilterRevealFiltered: true,
    });
  });
  tearDownAll(() async {
    AiReplyFilterService.instance.dispose();
    AiReplyStats.instance.dispose();
    await Hive.close();
    await directory.delete(recursive: true);
  });

  for (final scale in [1.0, 1.35]) {
    testWidgets('phone settings align switches and work at text scale $scale', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(393, 852);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final boundaryKey = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xffffafc5),
              brightness: Brightness.dark,
            ),
            fontFamily: font == null ? null : 'PreviewChinese',
          ),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: RepaintBoundary(key: boundaryKey, child: child!),
          ),
          home: const AiReplyFilterSetting(),
        ),
      );
      await tester.pumpAndSettle();

      Finder tile(String key) => find.byWidgetPredicate(
        (widget) => widget is SetSwitchItem && widget.setKey == key,
      );
      Finder toggle(String key) =>
          find.descendant(of: tile(key), matching: find.byType(Switch));
      const displayKey = SettingBoxKey.aiReplyFilterShowBeforeVerdict;
      final switchX = tester.getCenter(toggle(displayKey)).dx;
      expect(
        switchX,
        greaterThan(tester.getCenter(find.byIcon(Icons.speed)).dx),
      );
      expect(
        switchX,
        closeTo(
          tester.getCenter(toggle(SettingBoxKey.enableAiReplyFilter)).dx,
          0.1,
        ),
      );
      expect(find.byType(SwitchListTile), findsNothing);
      expect(tester.takeException(), isNull);

      if (output != null) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 2);
          final bytes = (await image.toByteData(
            format: ui.ImageByteFormat.png,
          ))!;
          await Directory(output).create(recursive: true);
          await File('$output/settings-$scale.png')
              .writeAsBytes(bytes.buffer.asUint8List());
          image.dispose();
        });
      }

      await tester.runAsync(() async {
        await tester.tap(toggle(displayKey));
        // The shared settings row updates after Hive finishes persisting.
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(Pref.aiReplyFilterShowBeforeVerdict, isTrue);
      expect(find.text('立即阅读，AI 判定为不适后隐藏；可能短暂看到不适评论'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('自定义 User 提示词'), 300);
      expect(find.text('默认：仅发送评论，返回 0–6 分类码'), findsOneWidget);
      expect(find.text('默认：含 {title}/{desc}/{comments} 占位符模板'), findsNothing);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        tile(SettingBoxKey.enableAiReplyFilterThinking),
        300,
      );
      expect(
        tester.getCenter(toggle(SettingBoxKey.enableAiReplyFilterThinking)).dx,
        closeTo(switchX, 0.1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
