import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:daily_expenses/database/app_database.dart';
import 'package:daily_expenses/repositories/ledger.dart';
import 'package:daily_expenses/models/money.dart';
import 'package:daily_expenses/services/bill_files.dart';
import 'package:daily_expenses/services/backup_service.dart';

void main() {
  late AppDatabase db;
  late Ledger ledger;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    ledger = Ledger(db);
  });
  tearDown(() async {
    await db.close();
  });
  test('exact paise parsing and Indian currency', () {
    expect(parseMoney('0.01'), 1);
    expect(parseMoney('123.4'), 12340);
    expect(money(12345678), '₹1,23,456.78');
    for (final bad in ['', '-1', 'NaN', '0', '1.234', '1e4']) {
      expect(() => parseMoney(bad), throwsFormatException);
    }
  });
  test('add, edit, delete, ordering and database totals', () async {
    final m = await ledger.month(2026, 11);
    final day = (await ledger.days(m.id)).single;
    final a = await ledger.save(dayId: day.id, name: 'Milk', paise: 8000);
    final b = await ledger.save(dayId: day.id, name: 'Petrol', paise: 50000);
    expect(await ledger.total(dayId: day.id), 58000);
    expect(await ledger.total(monthId: m.id), 58000);
    await ledger.save(id: a, dayId: day.id, name: 'Milk edited', paise: 9000);
    expect((await ledger.expenses(day.id)).length, 2);
    expect(await ledger.total(dayId: day.id), 59000);
    await ledger.deleteExpense(a);
    final c = await ledger.save(dayId: day.id, name: 'Rice', paise: 12500);
    final rows = await ledger.expenses(day.id);
    expect(rows.map((e) => e.id), [b, c]);
    expect(List.generate(rows.length, (i) => i + 1), [1, 2]);
    expect(await ledger.total(monthId: m.id), 62500);
  });
  test('adding never advances date; closing and editing old dates', () async {
    final m = await ledger.month(2026, 11);
    final first = (await ledger.days(m.id)).single;
    final id = await ledger.save(dayId: first.id, name: 'Food', paise: 100);
    expect((await ledger.days(m.id)).length, 1);
    await ledger.closeDay(first);
    var days = await ledger.days(m.id);
    expect(days.map((d) => d.expenseDate), ['2026-11-01', '2026-11-02']);
    await ledger.save(
      id: id,
      dayId: first.id,
      name: 'Food revised',
      paise: 200,
    );
    expect((await ledger.days(m.id)).last.status, 'open');
    expect(await ledger.total(monthId: m.id), 200);
    await ledger.reopen(first);
    days = await ledger.days(m.id);
    expect(days.where((d) => d.status == 'open').single.id, first.id);
    await ledger.closeDay(days.first);
    expect(
      (await ledger.days(
        m.id,
      )).where((d) => d.status == 'open').single.expenseDate,
      '2026-11-02',
    );
    expect((await ledger.expenses(first.id)).single.amountPaise, 200);
  });
  for (final ym in [
    (2024, 2, 29),
    (2025, 2, 28),
    (2026, 4, 30),
    (2026, 12, 31),
  ]) {
    test('month end ${ym.$1}-${ym.$2}', () async {
      final m = await ledger.month(ym.$1, ym.$2);
      for (var i = 0; i < ym.$3; i++) {
        final day = (await ledger.days(
          m.id,
        )).where((d) => d.status == 'open').single;
        await ledger.closeDay(day);
      }
      final days = await ledger.days(m.id);
      expect(days.length, ym.$3);
      expect(days.where((d) => d.status == 'open'), isEmpty);
      expect(nextInMonth(DateTime(ym.$1, ym.$2, ym.$3)), isNull);
    });
  }
  test('invalid expense and foreign key cannot commit', () async {
    final m = await ledger.month(2026, 11);
    final day = (await ledger.days(m.id)).single;
    await expectLater(
      ledger.save(dayId: day.id, name: ' ', paise: 1),
      throwsFormatException,
    );
    await expectLater(
      ledger.save(dayId: day.id, name: 'X', paise: 0),
      throwsFormatException,
    );
    await expectLater(
      db.customStatement(
        "INSERT INTO expenses(day_id, particulars, amount_paise, sort_order) VALUES (999, 'x', 1, 1)",
      ),
      throwsA(anything),
    );
    expect(await ledger.expenses(day.id), isEmpty);
  });
  test('month uniqueness and independent opening amounts', () async {
    final a = await ledger.month(2026, 11), b = await ledger.month(2026, 12);
    await ledger.opening(a.id, 100000);
    expect((await ledger.month(2026, 11)).id, a.id);
    expect((await ledger.month(2026, 11)).openingAmountPaise, 100000);
    expect((await ledger.month(2026, 12)).openingAmountPaise, 0);
    expect(a.id, isNot(b.id));
  });
  test(
    'attachment persistence, missing-file recovery, replacement and expense cascade',
    () async {
      final dir = await Directory.systemTemp.createTemp('bills_test');
      try {
        final files = BillFiles(dir);
        final source = File('${dir.path}/source.pdf');
        await source.writeAsString('%PDF-1.4\nTest fixture');
        final bill = await files.importFile(source.path);
        final m = await ledger.month(2026, 11),
            day = (await ledger.days((await ledger.month(2026, 11)).id)).single;
        final id = await ledger.save(
          dayId: day.id,
          name: 'Print',
          paise: 100,
          bills: [bill],
        );
        await source.delete();
        expect(await files.resolve(bill.relative).exists(), true);
        await files.remove(bill.relative);
        expect(await files.resolve(bill.relative).exists(), false);
        expect(
          (await ledger.attachments(id)).length,
          1,
        ); // missing record remains repairable
        await source.writeAsString('%PDF-1.4\nReplacement');
        final replacement = await files.importFile(source.path);
        await ledger.attach(id, replacement);
        final paths = await ledger.deleteExpense(id);
        expect(paths.length, 2);
        expect(await ledger.attachments(id), isEmpty);
        expect(await ledger.total(monthId: m.id), 0);
        expect(() => files.resolve('../outside'), throwsFormatException);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test('consistent backup round trip and invalid restore rollback', () async {
    final dir = await Directory.systemTemp.createTemp('backup_test');
    try {
      final files = BillFiles(dir), backup = BackupService(db, BillFiles(dir));
      final src = File('${dir.path}/bill.pdf');
      await src.writeAsString('%PDF-1.4\nBill');
      final bill = await files.importFile(src.path);
      final m = await ledger.month(2026, 11),
          day = (await ledger.days((await ledger.month(2026, 11)).id)).single;
      await ledger.opening(m.id, 20000);
      await ledger.setSetting('hide_balance', 'true');
      await ledger.save(dayId: day.id, name: 'Bill', paise: 500, bills: [bill]);
      await ledger.closeDay(day);
      final bytes = await backup.export();
      await ledger.opening(m.id, 1);
      await backup.restore(bytes);
      expect((await ledger.month(2026, 11)).openingAmountPaise, 20000);
      expect(await ledger.total(monthId: m.id), 500);
      expect((await ledger.days(m.id)).first.status, 'closed');
      final restored = (await db.select(db.expenseAttachments).get()).single;
      expect(
        await files.resolve(restored.relativeFilePath).readAsString(),
        '%PDF-1.4\nBill',
      );
      await expectLater(
        backup.restore(bytes.sublist(0, 20)),
        throwsA(anything),
      );
      expect(await ledger.total(monthId: m.id), 500);
      await files.remove(restored.relativeFilePath);
      await expectLater(backup.export(), throwsFormatException);
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test(
    'version 1 to 2 migration preserves records, settings, and bills',
    () async {
      final dir = await Directory.systemTemp.createTemp('migration_test');
      final file = File('${dir.path}/v1.sqlite');
      try {
        var old = AppDatabase.file(file);
        final repo = Ledger(old);
        final m = await repo.month(2026, 11),
            d = (await repo.days((await repo.month(2026, 11)).id)).single;
        await repo.opening(m.id, 999);
        await repo.setSetting('hide_balance', 'true');
        final id = await repo.save(
          dayId: d.id,
          name: 'Keep me',
          paise: 123,
          bills: [
            const StagedBill(
              'bill.pdf',
              'bills/example.pdf',
              'application/pdf',
              20,
            ),
          ],
        );
        // V1 schema was identical except for these indexes.
        for (final index in [
          'expenses_day_idx',
          'attachments_expense_idx',
          'days_month_idx',
          'one_open_day_per_month',
        ]) {
          await old.customStatement('DROP INDEX $index');
        }
        await old.customStatement('PRAGMA user_version=1');
        await old.close();
        old = AppDatabase.file(file);
        final upgraded = Ledger(old);
        expect((await upgraded.expenses(d.id)).single.particulars, 'Keep me');
        expect(
          (await upgraded.attachments(id)).single.relativeFilePath,
          'bills/example.pdf',
        );
        expect((await upgraded.month(2026, 11)).openingAmountPaise, 999);
        expect(await upgraded.setting('hide_balance'), 'true');
        expect(
          (await old.customSelect('PRAGMA user_version').getSingle()).read<int>(
            'user_version',
          ),
          2,
        );
        await old.close();
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
