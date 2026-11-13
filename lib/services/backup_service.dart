import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:sqlite3/sqlite3.dart' as sql;
import '../database/app_database.dart';
import 'bill_files.dart';

/// Called only while the application's operation lock is held.
/// Backup is a portable plaintext ZIP: UI warns before export.
class BackupService {
  final AppDatabase db;
  final BillFiles files;
  BackupService(this.db, this.files);
  static const tables = [
    'settings',
    'months',
    'days',
    'expenses',
    'expense_attachments',
    'categories',
  ];
  Future<Uint8List> export() async {
    final tmp = File(
      '${files.root.path}/snapshot_${files.uniqueName()}.sqlite',
    );
    try {
      // VACUUM INTO captures a consistent SQLite snapshot, including committed WAL data.
      await db.customStatement('VACUUM INTO ?', [tmp.path]);
      final archive = Archive();
      final manifest = utf8.encode(
        jsonEncode({
          'format': 'daily-expenses',
          'version': 1,
          'schema': db.schemaVersion,
        }),
      );
      archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
      final data = await tmp.readAsBytes();
      archive.addFile(ArchiveFile('database.sqlite', data.length, data));
      final attachments = await db.select(db.expenseAttachments).get();
      for (final bill in attachments) {
        final file = files.resolve(bill.relativeFilePath);
        if (!await file.exists()) {
          throw const FormatException(
            'A bill is missing. Replace or remove it before making a complete backup.',
          );
        }
        final bytes = await file.readAsBytes();
        archive.addFile(
          ArchiveFile(bill.relativeFilePath, bytes.length, bytes),
        );
      }
      return Uint8List.fromList(ZipEncoder().encode(archive));
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }

  Future<void> restore(Uint8List bytes) async {
    if (bytes.length > 512 * 1024 * 1024) {
      throw const FormatException('Backup exceeds the 512 MB import limit.');
    }
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    var total = 0;
    final seen = <String>{};
    for (final entry in archive) {
      total += entry.size;
      if (!entry.isFile ||
          !seen.add(entry.name) ||
          entry.size > 512 * 1024 * 1024 ||
          total > 512 * 1024 * 1024 ||
          (entry.name != 'manifest.json' &&
              entry.name != 'database.sqlite' &&
              !RegExp(r'^bills/[A-Za-z0-9_.-]+$').hasMatch(entry.name))) {
        throw const FormatException('Invalid or oversized backup entry.');
      }
    }
    final manifestFile = archive.findFile('manifest.json');
    final databaseFile = archive.findFile('database.sqlite');
    if (manifestFile == null || databaseFile == null) {
      throw const FormatException('Not a Daily Expenses backup.');
    }
    final manifest =
        jsonDecode(utf8.decode(manifestFile.content as List<int>))
            as Map<String, dynamic>;
    if (manifest['format'] != 'daily-expenses' ||
        manifest['version'] != 1 ||
        !(manifest['schema'] == 1 || manifest['schema'] == 2)) {
      throw const FormatException('Unsupported backup version.');
    }
    final tmp = File('${files.root.path}/restore_${files.uniqueName()}.sqlite');
    final created = <String>[];
    sql.Database? source;
    var committed = false;
    try {
      await tmp.writeAsBytes(databaseFile.content as List<int>, flush: true);
      source = sql.sqlite3.open(tmp.path, mode: sql.OpenMode.readOnly);
      if (source.select('PRAGMA integrity_check').single.values.first != 'ok' ||
          source.select('PRAGMA foreign_key_check').isNotEmpty) {
        throw const FormatException('Backup database failed validation.');
      }
      if (source.select('PRAGMA user_version').single.values.first !=
          manifest['schema']) {
        throw const FormatException('Backup schema mismatch.');
      }
      final rows = <String, List<Map<String, Object?>>>{};
      for (final table in tables) {
        // A fixed table allowlist; incoming database SQL is never executed.
        final expected =
            (await db.customSelect('PRAGMA table_info($table)').get())
                .map((r) => r.read<String>('name'))
                .toSet();
        final actual = source
            .select('PRAGMA table_info($table)')
            .map((r) => r['name'] as String)
            .toSet();
        if (expected.length != actual.length || !expected.containsAll(actual)) {
          throw const FormatException('Backup columns do not match this app.');
        }
        rows[table] = source
            .select('SELECT * FROM $table')
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      }
      final monthRows = {for (final m in rows['months']!) m['id']: m};
      for (final day in rows['days']!) {
        final date = DateTime.tryParse(day['expense_date'] as String);
        final m = monthRows[day['month_id']];
        if (date == null ||
            m == null ||
            date.year != m['year'] ||
            date.month != m['month'] ||
            date.toIso8601String().substring(0, 10) != day['expense_date']) {
          throw const FormatException('Invalid expense date in backup.');
        }
      }
      for (final bill in rows['expense_attachments']!) {
        final oldPath = bill['relative_file_path'] as String;
        files.resolve(oldPath); // validates relative path
        final item = archive.findFile(oldPath);
        if (item == null || item.size != bill['file_size']) {
          throw const FormatException('Backup has a missing or damaged bill.');
        }
        final stage = File('${files.root.path}/import_${files.uniqueName()}');
        try {
          await stage.writeAsBytes(item.content as List<int>, flush: true);
          final imported = await files.importFile(
            stage.path,
            original: bill['original_filename'] as String,
          );
          created.add(imported.relative);
          bill['relative_file_path'] = imported.relative;
          bill['stored_filename'] = imported.relative.split('/').last;
          bill['mime_type'] = imported.mime;
        } finally {
          if (await stage.exists()) await stage.delete();
        }
      }
      await db.transaction(() async {
        for (final table in tables.reversed) {
          await db.customStatement('DELETE FROM $table');
        }
        for (final table in tables) {
          for (final row in rows[table]!) {
            final names = row.keys.toList();
            await db.customStatement(
              'INSERT INTO $table (${names.join(',')}) VALUES (${List.filled(names.length, '?').join(',')})',
              names.map((n) => row[n]).toList(),
            );
          }
        }
        if ((await db.customSelect('PRAGMA foreign_key_check').get())
            .isNotEmpty) {
          throw const FormatException('Invalid backup relationships.');
        }
      });
      committed = true;
      // Original files are deliberately retained until a later cleanup; rollback/crash cannot erase bills.
    } finally {
      source?.dispose();
      if (await tmp.exists()) await tmp.delete();
      if (!committed) {
        for (final path in created) {
          await files.remove(path);
        }
      }
    }
  }
}
