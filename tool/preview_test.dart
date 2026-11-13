// Developer-only visual check: flutter test tool/preview_test.dart.
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:daily_expenses/database/app_database.dart';
import 'package:daily_expenses/services/app_store.dart';
import 'package:daily_expenses/services/bill_files.dart';
import 'package:daily_expenses/services/pin_service.dart';
import 'package:daily_expenses/ui/home.dart';

void main() {
  testWidgets('developer preview', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    final font = File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
    if (font.existsSync()) {
      final loader = FontLoader('PreviewSans')
        ..addFont(Future.value(ByteData.sublistView(font.readAsBytesSync())));
      await loader.load();
    }
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    final dir = Directory.systemTemp.createTempSync('preview');
    final store = AppStore(
      AppDatabase(NativeDatabase.memory()),
      BillFiles(dir),
      PinService(),
    );
    await store.ledger.setSetting('selected_month', '2026-11-01');
    final month = await store.ledger.month(2026, 11);
    await store.ledger.opening(month.id, 5000000);
    for (final n in [75000, 90000]) {
      final day = (await store.ledger.days(
        month.id,
      )).singleWhere((d) => d.status == 'open');
      await store.ledger.save(dayId: day.id, name: 'Daily expenses', paise: n);
      await store.ledger.closeDay(day);
    }
    final day = (await store.ledger.days(
      month.id,
    )).singleWhere((d) => d.status == 'open');
    for (final item in [
      ('Vegetables', 25000),
      ('Milk', 8000),
      ('Petrol', 50000),
      ('School supplies', 18000),
      ('Phone recharge', 29900),
      ('Groceries', 64000),
    ]) {
      await store.ledger.save(dayId: day.id, name: item.$1, paise: item.$2);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/image_picker'),
          (_) async => null,
        );
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          fontFamily: 'PreviewSans',
          visualDensity: VisualDensity.compact,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff7047c6)),
          scaffoldBackgroundColor: const Color(0xfffcfaff),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xffede5ff),
            toolbarHeight: 52,
            titleTextStyle: TextStyle(
              fontFamily: 'PreviewSans',
              fontSize: 18,
              color: Color(0xff332052),
              fontWeight: FontWeight.w700,
            ),
          ),
          inputDecorationTheme: InputDecorationTheme(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 12,
            ),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
          ),
        ),
        home: RepaintBoundary(
          key: key,
          child: HomeScreen(store: store),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      final image =
          await (key.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary)
              .toImage(pixelRatio: 2);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File(
        Platform.environment['PREVIEW_OUTPUT'] ?? 'preview.png',
      ).writeAsBytesSync(bytes!.buffer.asUint8List());
      image.dispose();
    });
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.byType(TextField).last).bottom,
      lessThanOrEqualTo(520),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await store.db.close();
    dir.deleteSync(recursive: true);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetViewInsets();
  });
}
