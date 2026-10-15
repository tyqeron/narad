// Generate desktop and phone layout previews: flutter test tools/preview.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/main.dart';
import 'package:narad_client/app_settings.dart';
import '../test/widget_test.dart' show FakeApi;

void main() {
  testWidgets('render layout previews', (tester) async {
    final fontPath =
        Platform.environment['NARAD_PREVIEW_FONT'] ??
        '/usr/share/fonts/TTF/DejaVuSans.ttf';
    await tester.runAsync(() async {
      final font = File(fontPath);
      if (await font.exists()) {
        final bytes = await font.readAsBytes();
        for (final family in ['Roboto', 'Ahem']) {
          await (FontLoader(
            family,
          )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
        }
      }
    });
    await tester.runAsync(() async {
      final font = File(
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      );
      if (await font.exists()) {
        await (FontLoader('MaterialIcons')..addFont(
              Future.value(ByteData.sublistView(await font.readAsBytes())),
            ))
            .load();
      }
    });
    final root = GlobalKey();
    final api = FakeApi();
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      for (final size in [const Size(1280, 850), const Size(390, 844)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        await tester.pumpWidget(
          RepaintBoundary(
            key: root,
            child: NaradApp(
              api: api,
              preferences: MemoryThemePreferences(mode),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final render =
            root.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final screenshot = await render.toImage();
          final png = await screenshot.toByteData(
            format: ui.ImageByteFormat.png,
          );
          await File(
            '/tmp/narad-${size.width.toInt()}-${mode.name}.png',
          ).writeAsBytes(png!.buffer.asUint8List());
          screenshot.dispose();
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
    }
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}
