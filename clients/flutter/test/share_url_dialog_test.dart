import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/share_url_dialog.dart';

void main() {
  Future<void> open(WidgetTester tester, void Function(String?) result) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => const ShareUrlDialog(deviceName: 'Phone'),
                  ),
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets('empty share stays open with inline validation; cancel is safe', (
    tester,
  ) async {
    final results = <String?>[];
    await open(tester, results.add);
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a web address'), findsOneWidget);
    expect(results, isEmpty);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard rejects invalid input and returns a trimmed valid link',
    (tester) async {
      final results = <String?>[];
      await open(tester, results.add);
      await tester.enterText(find.byType(TextFormField), 'not a link');
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(
        find.text('Enter a valid http:// or https:// link'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byType(TextFormField),
        ' https://example.com/path?q=1#part ',
      );
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(results, ['https://example.com/path?q=1#part']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancel and barrier dismissal never return a URL', (
    tester,
  ) async {
    final results = <String?>[];
    await open(tester, results.add);
    await tester.enterText(find.byType(TextFormField), 'https://example.com');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(results, [null]);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();
    expect(results, [null, null]);
    expect(tester.takeException(), isNull);
  });
}
