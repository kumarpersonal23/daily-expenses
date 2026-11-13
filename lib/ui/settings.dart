import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import '../database/app_database.dart';
import '../models/money.dart';
import '../services/app_store.dart';
import 'common.dart';

class SettingsScreen extends StatefulWidget {
  final AppStore store;
  final Month month;
  final void Function(DateTime) onMonth;
  const SettingsScreen({
    super.key,
    required this.store,
    required this.month,
    required this.onMonth,
  });
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Month month = widget.month;
  late final opening = TextEditingController(
    text: moneyInput(month.openingAmountPaise),
  );
  bool hideOpening = true, hideBalance = true, enabled = false, busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final pin = await widget.store.pin.enabled;
    final hidden = await widget.store.ledger.setting('hide_balance') != 'false';
    if (mounted) {
      setState(() {
        enabled = pin;
        hideBalance = hidden;
      });
    }
  }

  @override
  void dispose() {
    opening.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() op) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await op();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<String?> askPin(String title) async {
    final input = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: input,
          obscureText: true,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(12),
          ],
          decoration: const InputDecoration(labelText: '6–12 digit PIN'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, input.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    // Controller remains alive until the dialog exit animation completes.
    Future<void>.delayed(const Duration(seconds: 1), input.dispose);
    return result;
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (busy) const LinearProgressIndicator(),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.calendar_month, color: Colors.deepPurple),
            title: Text(
              DateFormat('MMMM yyyy').format(DateTime(month.year, month.month)),
            ),
            subtitle: const Text('Month and year'),
            trailing: const Icon(Icons.expand_more),
            onTap: busy
                ? null
                : () => run(() async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: DateTime(month.year, month.month),
                      firstDate: DateTime(1900),
                      lastDate: DateTime(2200, 12, 31),
                    );
                    if (date == null) return;
                    month = await widget.store.ledger.month(
                      date.year,
                      date.month,
                    );
                    opening.text = moneyInput(month.openingAmountPaise);
                    widget.onMonth(DateTime(date.year, date.month));
                    await widget.store.ledger.setSetting(
                      'selected_month',
                      dateKey(DateTime(date.year, date.month)),
                    );
                  }),
          ),
          TextField(
            controller: opening,
            enabled: !busy,
            obscureText: hideOpening,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Private opening amount (₹)',
              suffixIcon: compactIcon(
                hideOpening ? Icons.visibility : Icons.visibility_off,
                'Show or hide opening amount',
                () => setState(() => hideOpening = !hideOpening),
              ),
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Hide balance by default'),
            value: hideBalance,
            onChanged: busy ? null : (v) => setState(() => hideBalance = v),
          ),
          FilledButton.icon(
            onPressed: busy
                ? null
                : () => run(() async {
                    final value = parseMoney(opening.text, allowZero: true);
                    await widget.store.mutate(
                      () => widget.store.db.transaction(() async {
                        await widget.store.ledger.opening(month.id, value);
                        await widget.store.ledger.setSetting(
                          'hide_balance',
                          '$hideBalance',
                        );
                      }),
                    );
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Settings saved')),
                      );
                    }
                  }),
            icon: const Icon(Icons.save_outlined, size: 18),
            label: const Text('Save monthly settings'),
          ),
          const Divider(height: 28),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('PIN lock'),
            subtitle: const Text('Locks when you leave the app'),
            value: enabled,
            onChanged: busy
                ? null
                : (value) => run(() async {
                    if (enabled) {
                      final old = await askPin('Enter current PIN');
                      if (old == null) return;
                      if (!await widget.store.pin.verify(old)) {
                        throw const FormatException('Incorrect PIN.');
                      }
                      await widget.store.pin.disable();
                    } else {
                      final pin = await askPin('Set a PIN');
                      if (pin == null) return;
                      final repeated = await askPin('Confirm PIN');
                      if (repeated == null) return;
                      if (pin != repeated) {
                        throw const FormatException('PINs do not match.');
                      }
                      await widget.store.pin.set(pin);
                    }
                    await load();
                  }),
          ),
          const Text(
            'Records and bills are stored privately on this phone. SQLite and exported ZIP backups are not encrypted. PIN protection controls app access; it does not encrypt your records.',
            style: TextStyle(fontSize: 12, color: Colors.blueGrey),
          ),
          const Divider(height: 28),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => run(() async {
                    if (!await confirm(
                      context,
                      'Export private backup?',
                      'The ZIP includes all amounts and bills in readable form. Store it somewhere private. PIN credentials are not exported.',
                    )) {
                      return;
                    }
                    final bytes = await widget.store.lock.synchronized(
                      () => widget.store.backup.export(),
                    );
                    final path = await FilePicker.platform.saveFile(
                      dialogTitle: 'Save Daily Expenses backup',
                      fileName:
                          'Daily-Expenses-${DateFormat('yyyyMMdd-HHmmss').format(DateTime.now())}.zip',
                      type: FileType.custom,
                      allowedExtensions: ['zip'],
                      bytes: bytes,
                    );
                    if (path != null && context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Backup exported')),
                      );
                    }
                  }),
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('Export backup'),
          ),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => run(() async {
                    final picked = await FilePicker.platform.pickFiles(
                      type: FileType.custom,
                      allowedExtensions: ['zip'],
                    );
                    if (picked == null ||
                        picked.files.single.path == null ||
                        !context.mounted) {
                      return;
                    }
                    if (!await confirm(
                      context,
                      'Replace all current data?',
                      'Restore replaces all months, expenses and bills. Export a backup first. Your existing PIN remains unchanged. Invalid backups will be rejected before changes are committed.',
                    )) {
                      return;
                    }
                    final file = File(picked.files.single.path!);
                    if (await file.length() > 512 * 1024 * 1024) {
                      throw const FormatException(
                        'Backup too large (maximum 512 MB).',
                      );
                    }
                    final bytes = await file.readAsBytes();
                    await widget.store.mutate(
                      () => widget.store.backup.restore(bytes),
                    );
                    final pref = await widget.store.ledger.setting(
                      'selected_month',
                    );
                    final date = pref == null
                        ? DateTime.now()
                        : DateTime.parse(pref);
                    month = await widget.store.ledger.month(
                      date.year,
                      date.month,
                    );
                    widget.onMonth(DateTime(date.year, date.month));
                    opening.text = moneyInput(month.openingAmountPaise);
                    await load();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Backup restored successfully'),
                        ),
                      );
                    }
                  }),
            icon: const Icon(Icons.restore),
            label: const Text('Restore backup'),
          ),
          const SizedBox(height: 16),
          const Text(
            'Daily Expenses 1.0.1\nOffline • No account • No ads\nUpdate the existing app; never uninstall to update.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: Colors.deepPurple),
          ),
        ],
      ),
    ),
  );
}
