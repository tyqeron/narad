import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:narad_client/api.dart';
import 'package:narad_client/contacts_page.dart';

class GeneratedContacts implements NaradApi {
  bool denied = false;
  @override
  Future<Map<String, dynamic>> call(Map<String, dynamic> command) async {
    if (denied) throw StateError('Generated permission denial');
    return {
      'items': [
        {
          'name': 'Narad Generated Fixture DO NOT SAVE',
          'phones': ['123450000'],
          'emails': ['fixture@example.invalid'],
        },
      ],
      'next_after': null,
    };
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'tablet contacts clear on denial and offer explicit contact saving',
    (tester) async {
      final api = GeneratedContacts();
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: ContactsPage(
              api: api,
              peer: const {
                'device_id': 'generated',
                'device_name': 'Generated source',
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text('Narad Generated Fixture DO NOT SAVE'),
          findsOneWidget,
        );
        api.denied = true;
        await tester.tap(find.byTooltip('Refresh contacts'));
        await tester.pumpAndSettle();
        expect(find.text('Narad Generated Fixture DO NOT SAVE'), findsNothing);
        api.denied = false;
        await tester.tap(find.byTooltip('Refresh contacts'));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Contact actions'));
        await tester.pumpAndSettle();
        expect(find.text('Save contact'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
      }
    },
  );
}
