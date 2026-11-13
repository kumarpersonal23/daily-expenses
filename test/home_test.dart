import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:daily_expenses/database/app_database.dart';
import 'package:daily_expenses/services/app_store.dart';
import 'package:daily_expenses/services/bill_files.dart';
import 'package:daily_expenses/services/pin_service.dart';
import 'package:daily_expenses/ui/home.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'compact entry saves and closed dates collapse without changing active date',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final dir = Directory.systemTemp.createTempSync('ui_test');
      final db = AppDatabase(NativeDatabase.memory());
      final store = AppStore(db, BillFiles(dir), PinService());
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/image_picker'),
            (_) async => null,
          );
      await tester.pumpWidget(MaterialApp(home: HomeScreen(store: store)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Vegetables');
      await tester.enterText(find.byType(TextField).last, '250');
      await tester.tap(find.byTooltip('Add expense / Next row'));
      await tester.pumpAndSettle();
      expect(find.text('Vegetables'), findsOneWidget);
      expect((await db.select(db.expenses).get()).single.amountPaise, 25000);
      await tester.tap(find.text('Close Day / Next'));
      await tester.pumpAndSettle();
      expect(find.text('Vegetables'), findsNothing);
      final active = (await db.select(db.days).get())
          .singleWhere((d) => d.status == 'open')
          .id;
      await tester.tap(find.byTooltip('Expand or collapse date'));
      await tester.pumpAndSettle();
      expect(find.text('Vegetables'), findsOneWidget);
      expect(
        (await db.select(db.days).get())
            .singleWhere((d) => d.status == 'open')
            .id,
        active,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await db.close();
      dir.deleteSync(recursive: true);
    },
  );
}
