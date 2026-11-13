import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;

class StagedBill {
  final String original, relative, mime;
  final int size;
  const StagedBill(this.original, this.relative, this.mime, this.size);
}

class BillFiles {
  final Directory root;
  BillFiles(this.root);
  String uniqueName() =>
      '${DateTime.now().microsecondsSinceEpoch}_${List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  File resolve(String relative) {
    if (p.isAbsolute(relative) ||
        p.normalize(relative) != relative ||
        !relative.startsWith('bills/') ||
        relative.contains('..')) {
      throw const FormatException('Unsafe bill path.');
    }
    return File(p.join(root.path, relative));
  }

  Future<StagedBill> importFile(String source, {String? original}) async {
    final file = File(source);
    final size = await file.length();
    if (size <= 0 || size > 25 * 1024 * 1024) {
      throw const FormatException(
        'Each bill must be between 1 byte and 25 MB.',
      );
    }
    final handle = await file.open();
    final bytes = await handle.read(12);
    await handle.close();
    String ext, mime;
    if (bytes.length >= 5 && String.fromCharCodes(bytes.take(5)) == '%PDF-') {
      ext = '.pdf';
      mime = 'application/pdf';
    } else if (bytes.length >= 3 &&
        bytes[0] == 255 &&
        bytes[1] == 216 &&
        bytes[2] == 255) {
      ext = '.jpg';
      mime = 'image/jpeg';
    } else if (bytes.length >= 8 &&
        bytes.take(8).join(',') == '137,80,78,71,13,10,26,10') {
      ext = '.png';
      mime = 'image/png';
    } else {
      throw const FormatException('Select a JPG, PNG or PDF bill.');
    }
    final relative = 'bills/${uniqueName()}$ext';
    final target = resolve(relative);
    await target.parent.create(recursive: true);
    await file.copy('${target.path}.partial');
    await File('${target.path}.partial').rename(target.path);
    return StagedBill(p.basename(original ?? source), relative, mime, size);
  }

  Future<void> remove(String relative) async {
    final file = resolve(relative);
    if (await file.exists()) await file.delete();
  }
}
