import 'package:flutter/material.dart';
import 'package:drift/drift.dart' show QueryRow;
import 'package:intl/intl.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';
import '../models/money.dart';
import '../services/app_store.dart';
import 'common.dart';

class BillsScreen extends StatefulWidget {
  final AppStore store;
  final int? expenseId;
  final DateTime initialMonth;
  const BillsScreen({
    super.key,
    required this.store,
    this.expenseId,
    required this.initialMonth,
  });
  @override
  State<BillsScreen> createState() => _BillsScreenState();
}

class _BillsScreenState extends State<BillsScreen> {
  late DateTime month = widget.initialMonth;
  DateTime? date;
  String query = '';
  bool busy = false, loading = true, allMonths = false;
  List<QueryRow> rows = [];
  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final result = await widget.store.db
          .customSelect(
            'SELECT a.*, e.particulars, e.amount_paise, d.expense_date FROM expense_attachments a JOIN expenses e ON e.id=a.expense_id JOIN days d ON d.id=e.day_id ORDER BY d.expense_date DESC, a.id DESC',
          )
          .get();
      if (mounted) {
        setState(() {
          rows = result;
          loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => loading = false);
        showError(context, e);
      }
    }
  }

  Future<void> run(Future<void> Function() op) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await op();
      await refresh();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> add({int? replaceId, String? oldPath, int? expenseId}) =>
      run(() async {
        if (replaceId != null &&
            !await confirm(
              context,
              'Replace bill?',
              'The selected bill will be replaced. Its expense stays saved.',
            )) {
          return;
        }
        if (!mounted) return;
        final bills = await pickBills(context, widget.store);
        if (bills.isEmpty) return;
        try {
          await widget.store.mutate(
            () => widget.store.db.transaction(() async {
              for (final bill in bills) {
                await widget.store.ledger.attach(
                  expenseId ?? widget.expenseId!,
                  bill,
                );
              }
              if (replaceId != null) {
                await (widget.store.db.delete(
                  widget.store.db.expenseAttachments,
                )..where((t) => t.id.equals(replaceId))).go();
              }
            }),
          );
        } catch (_) {
          for (final bill in bills) {
            await widget.store.files.remove(bill.relative);
          }
          rethrow;
        }
        if (oldPath != null) {
          try {
            await widget.store.files.remove(oldPath);
          } catch (_) {}
        }
      });
  @override
  Widget build(BuildContext context) {
    final filtered = rows.where((r) {
      final d = r.read<String>('expense_date');
      return (widget.expenseId == null ||
              r.read<int>('expense_id') == widget.expenseId) &&
          (widget.expenseId != null ||
              allMonths ||
              d.startsWith(dateKey(month).substring(0, 7))) &&
          (date == null || d == dateKey(date!)) &&
          ('${r.read<String>('particulars')} ${r.read<String>('original_filename')}'
              .toLowerCase()
              .contains(query.toLowerCase()));
    }).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('View Bills'),
        actions: [
          if (widget.expenseId != null)
            compactIcon(
              Icons.add,
              'Attach bills to expense',
              busy ? null : () => add(),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search bills or expense',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (value) => setState(() => query = value),
              ),
            ),
            if (widget.expenseId == null)
              Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: month,
                        firstDate: DateTime(1900),
                        lastDate: DateTime(2200, 12, 31),
                      );
                      if (d != null) {
                        setState(() {
                          month = DateTime(d.year, d.month);
                          allMonths = false;
                          date = null;
                        });
                      }
                    },
                    child: Text(DateFormat('MMM yyyy').format(month)),
                  ),
                  FilterChip(
                    label: const Text('All months'),
                    selected: allMonths,
                    onSelected: (v) => setState(() {
                      allMonths = v;
                      date = null;
                    }),
                  ),
                  TextButton(
                    onPressed: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: date ?? month,
                        firstDate: DateTime(1900),
                        lastDate: DateTime(2200, 12, 31),
                      );
                      if (d != null) {
                        setState(() {
                          date = d;
                          month = DateTime(d.year, d.month);
                        });
                      }
                    },
                    child: Text(
                      date == null
                          ? 'Filter date'
                          : DateFormat('dd MMM').format(date!),
                    ),
                  ),
                  if (date != null)
                    compactIcon(
                      Icons.clear,
                      'Clear date filter',
                      () => setState(() => date = null),
                    ),
                ],
              ),
            if (busy) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: loading
                  ? const Center(child: CircularProgressIndicator())
                  : filtered.isEmpty
                  ? Center(
                      child: Text(
                        widget.expenseId == null
                            ? 'No bills match these filters.'
                            : 'No bills yet. Tap + to attach.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (c, i) {
                        final row = filtered[i],
                            path = filtered[i].read<String>(
                              'relative_file_path',
                            );
                        final file = widget.store.files.resolve(path);
                        final missing = !file.existsSync();
                        final pdf =
                            row.read<String>('mime_type') == 'application/pdf';
                        return ListTile(
                          dense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 10,
                          ),
                          leading: SizedBox(
                            width: 40,
                            height: 44,
                            child: missing
                                ? const Icon(
                                    Icons.broken_image_outlined,
                                    color: Colors.orange,
                                  )
                                : pdf
                                ? const Icon(
                                    Icons.picture_as_pdf,
                                    color: Colors.redAccent,
                                  )
                                : Image.file(
                                    file,
                                    cacheWidth: 100,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) =>
                                        const Icon(Icons.broken_image),
                                  ),
                          ),
                          title: Text(
                            row.read<String>('particulars'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${row.read<String>('expense_date')} · ${money(row.read<int>('amount_paise'))}\n${missing
                                ? 'Missing file · replace to recover'
                                : pdf
                                ? 'PDF'
                                : 'Image'} · ${row.read<String>('original_filename')}',
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: missing
                              ? () => showError(
                                  context,
                                  const FormatException(
                                    'This bill file is missing. Use Replace to recover it.',
                                  ),
                                )
                              : () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => Scaffold(
                                      appBar: AppBar(
                                        title: Text(
                                          row.read<String>('original_filename'),
                                        ),
                                      ),
                                      body: pdf
                                          ? PdfViewer.file(file.path)
                                          : Center(
                                              child: InteractiveViewer(
                                                minScale: .5,
                                                maxScale: 6,
                                                child: Image.file(
                                                  file,
                                                  errorBuilder: (_, _, _) =>
                                                      const Text(
                                                        'Cannot decode this image. Replace the bill.',
                                                      ),
                                                ),
                                              ),
                                            ),
                                    ),
                                  ),
                                ),
                          trailing: PopupMenuButton<String>(
                            enabled: !busy,
                            tooltip: 'Bill actions',
                            onSelected: (action) {
                              if (action == 'replace') {
                                add(
                                  replaceId: row.read<int>('id'),
                                  oldPath: path,
                                  expenseId: row.read<int>('expense_id'),
                                );
                              }
                              if (action == 'share') {
                                run(() async {
                                  if (missing) {
                                    throw const FormatException(
                                      'The bill file is missing.',
                                    );
                                  }
                                  await SharePlus.instance.share(
                                    ShareParams(
                                      files: [
                                        XFile(
                                          file.path,
                                          mimeType: row.read<String>(
                                            'mime_type',
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                });
                              }
                              if (action == 'delete') {
                                run(() async {
                                  if (!await confirm(
                                    context,
                                    'Delete bill?',
                                    'Only this attachment will be deleted. The expense remains.',
                                  )) {
                                    return;
                                  }
                                  await widget.store.mutate(() async {
                                    await (widget.store.db.delete(
                                          widget.store.db.expenseAttachments,
                                        )..where(
                                          (t) =>
                                              t.id.equals(row.read<int>('id')),
                                        ))
                                        .go();
                                  });
                                  try {
                                    await widget.store.files.remove(path);
                                  } catch (_) {}
                                });
                              }
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(
                                value: 'share',
                                child: Text('Share'),
                              ),
                              PopupMenuItem(
                                value: 'replace',
                                child: Text('Replace'),
                              ),
                              PopupMenuItem(
                                value: 'delete',
                                child: Text('Delete'),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
