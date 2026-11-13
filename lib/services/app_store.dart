import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:synchronized/synchronized.dart';
import '../database/app_database.dart';
import '../repositories/ledger.dart';
import 'bill_files.dart';
import 'backup_service.dart';
import 'pin_service.dart';

class AppStore extends ChangeNotifier {
  final AppDatabase db;
  final BillFiles files;
  final PinService pin;
  final lock = Lock();
  late final ledger = Ledger(db);
  late final backup = BackupService(db, files);
  AppStore(this.db, this.files, this.pin);
  static Future<AppStore> open() async {
    final base = await getApplicationSupportDirectory();
    await base.create(recursive: true);
    final store = AppStore(
      AppDatabase.file(File('${base.path}/daily_expenses.sqlite')),
      BillFiles(base),
      PinService(),
    );
    await store.db.customSelect('SELECT 1').get();
    return store;
  }

  Future<T> mutate<T>(Future<T> Function() operation) =>
      lock.synchronized(() async {
        final result = await operation();
        notifyListeners();
        return result;
      });
}
