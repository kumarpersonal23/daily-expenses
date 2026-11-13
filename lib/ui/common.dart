import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../services/app_store.dart';
import '../services/bill_files.dart';

void showError(BuildContext context, Object error) {
  final message = error is FormatException
      ? error.message
      : error is StateError
      ? error.message
      : 'Could not finish. Please try again.';
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    ) ??
    false;
Future<List<StagedBill>> pickBills(BuildContext context, AppStore store) async {
  final choice = await showModalBottomSheet<int>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.pop(c, 0),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose images'),
            onTap: () => Navigator.pop(c, 1),
          ),
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('Select PDF'),
            onTap: () => Navigator.pop(c, 2),
          ),
        ],
      ),
    ),
  );
  final sources = <({String path, String name})>[];
  if (choice == 0) {
    final photo = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 90,
    );
    if (photo != null) sources.add((path: photo.path, name: photo.name));
  } else if (choice == 1) {
    for (final photo in await ImagePicker().pickMultiImage(imageQuality: 90)) {
      sources.add((path: photo.path, name: photo.name));
    }
  } else if (choice == 2) {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      allowMultiple: true,
    );
    if (result != null) {
      for (final file in result.files) {
        if (file.path != null) sources.add((path: file.path!, name: file.name));
      }
    }
  }
  final bills = <StagedBill>[];
  try {
    for (final source in sources) {
      bills.add(
        await store.files.importFile(source.path, original: source.name),
      );
    }
    return bills;
  } catch (_) {
    for (final bill in bills) {
      await store.files.remove(bill.relative);
    }
    rethrow;
  }
}

Widget compactIcon(
  IconData icon,
  String tooltip,
  VoidCallback? action, {
  Color? color,
}) => IconButton(
  tooltip: tooltip,
  onPressed: action,
  icon: Icon(icon, size: 19, color: color),
  visualDensity: VisualDensity.standard,
  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
  padding: const EdgeInsets.all(6),
);
