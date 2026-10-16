import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/contacts_page.dart';

class ContactApi implements NaradApi {
  bool denied = false;
  final commands = <Map<String, dynamic>>[];
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    commands.add(command);
    if (denied) throw StateError('permission denied');
    final next = (command['args'] as Map)['after'];
    return {
      'items': [
        {
          'name': next == null ? 'Generated contact' : 'Next contact',
          'phones': ['12345'],
          'emails': ['fixture@example.invalid'],
        },
      ],
      'next_after': next == null ? '20' : null,
    };
  }
}

void main() {
  test('vCard cannot inject fields and folds Unicode by UTF-8 octets', () {
    final card = contactVcard({
      'name': 'Alex\r\nEND:VCARD;,${List.filled(60, '😀').join()}',
      'phones': ['12345'],
      'emails': [],
    });
    expect(card.split('END:VCARD\r\n'), hasLength(2));
    expect(card, contains(r'Alex\nEND:VCARD\;\,'));
    for (final line in card.split('\r\n')) {
      expect(utf8.encode(line).length, lessThanOrEqualTo(75));
    }
    expect(card, contains('TEL:12345'));
  });
  testWidgets(
    'contacts page advances cursor, clears revoked content and fits phone width',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ContactApi();
      await tester.pumpWidget(
        MaterialApp(
          home: ContactsPage(
            api: api,
            peer: const {'device_id': 'source', 'device_name': 'Fixture phone'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Generated contact'), findsOneWidget);
      await tester.tap(find.text('Next contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Next contact'), findsOneWidget);
      expect(api.commands.last['args'], {'after': '20'});
      api.denied = true;
      await tester.tap(find.byTooltip('Refresh contacts'));
      await tester.pumpAndSettle();
      expect(find.text('Next contact'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
