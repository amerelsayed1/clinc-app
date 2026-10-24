import 'dart:typed_data';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import 'documents_api.dart';
import 'documents_models.dart';
import 'format.dart';

/// Where captured pages come from. Replaceable in tests.
abstract class PagePicker {
  Future<PickedPage?> camera();
  Future<List<PickedPage>> gallery();
}

class ImagePagePicker implements PagePicker {
  ImagePagePicker([ImagePicker? picker]) : _picker = picker ?? ImagePicker();
  final ImagePicker _picker;

  // Phone photos are huge: the picker downsizes/recompresses them before upload (F06-1).
  static const _maxSide = 2200.0;
  static const _quality = 85;

  Future<PickedPage> _page(XFile f, int n) async {
    var name = f.name.isEmpty ? 'page-$n.jpg' : f.name;
    if (!RegExp(r'\.(jpe?g|png|webp)$', caseSensitive: false).hasMatch(name)) name = '$name.jpg';
    return PickedPage(name: name, bytes: await f.readAsBytes());
  }

  @override
  Future<PickedPage?> camera() async {
    final f = await _picker.pickImage(source: ImageSource.camera, maxWidth: _maxSide, maxHeight: _maxSide, imageQuality: _quality);
    return f == null ? null : _page(f, DateTime.now().millisecondsSinceEpoch);
  }

  @override
  Future<List<PickedPage>> gallery() async {
    final fs = await _picker.pickMultiImage(maxWidth: _maxSide, maxHeight: _maxSide, imageQuality: _quality);
    return [for (final (i, f) in fs.indexed) await _page(f, i + 1)];
  }
}

const maxDocumentPages = 20;

/// Camera-first capture of a multi-page document. Pops `true` after a successful upload.
class DocumentUploadPage extends StatefulWidget {
  const DocumentUploadPage({super.key, required this.api, required this.patientId, required this.canClinical, this.encounterId, this.picker});
  final DocumentsApi api;
  final String patientId;

  /// documents.upload_clinical: otherwise only administrative documents may be added.
  final bool canClinical;
  final String? encounterId;
  final PagePicker? picker;

  @override
  State<DocumentUploadPage> createState() => _DocumentUploadPageState();
}

class _DocumentUploadPageState extends State<DocumentUploadPage> {
  late final PagePicker _picker = widget.picker ?? ImagePagePicker();
  final _pages = <PickedPage>[];
  final _title = TextEditingController();
  final _notes = TextEditingController();
  late String _category = widget.canClinical ? 'lab_result' : 'administrative';
  DateTime? _date;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() fn) async {
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not get the photo: ${errorMessage(e)}');
    }
  }

  void _add(Iterable<PickedPage> ps) {
    setState(() {
      _error = null;
      _pages.addAll(ps);
      if (_pages.length > maxDocumentPages) {
        _pages.removeRange(maxDocumentPages, _pages.length);
        _error = 'At most $maxDocumentPages pages per document.';
      }
    });
  }

  Future<void> _camera() => _guard(() async {
        final p = await _picker.camera();
        if (p != null && mounted) _add([p]);
      });

  Future<void> _gallery() => _guard(() async {
        final ps = await _picker.gallery();
        if (mounted) _add(ps);
      });

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(context: context, initialDate: _date ?? now, firstDate: DateTime(1900), lastDate: now);
    if (d != null) setState(() => _date = d);
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final fields = <String, String>{
        'category': _category,
        if (_title.text.trim().isNotEmpty) 'title': _title.text.trim(),
        if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
        if (_date != null) 'documentDate': formatDate(_date),
        if (widget.encounterId != null) 'encounterId': widget.encounterId!,
      };
      await widget.api.upload(widget.patientId, fields: fields, pages: List.of(_pages));
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final categories = widget.canClinical ? [...clinicalCategories, 'administrative'] : const ['administrative'];
    return Scaffold(
      appBar: AppBar(title: const Text('Add document')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(
            child: FilledButton.icon(
              key: const ValueKey('doc-camera'),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : _camera,
              icon: const Icon(Icons.photo_camera_outlined),
              label: Text(_pages.isEmpty ? 'Take photo' : 'Add page'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: OutlinedButton.icon(
              key: const ValueKey('doc-gallery'),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(56)),
              onPressed: _busy ? null : _gallery,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('From gallery'),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        Text('JPEG, PNG or WebP photos, up to $maxDocumentPages pages. Drag to reorder.', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        if (_pages.isNotEmpty)
          ReorderableListView(
            key: const ValueKey('doc-pages'),
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: (from, to) => setState(() => _pages.insert(to, _pages.removeAt(from))),
            children: [
              for (final (i, p) in _pages.indexed)
                ListTile(
                  key: ObjectKey(p),
                  contentPadding: EdgeInsets.zero,
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.memory(Uint8List.fromList(p.bytes), width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox(width: 56, height: 56, child: Icon(Icons.image_outlined))),
                  ),
                  title: Text('Page ${i + 1}'),
                  subtitle: Text('${p.name} · ${formatBytes(p.bytes.length)}'),
                  trailing: IconButton(
                    key: ValueKey('remove-page-$i'),
                    tooltip: 'Remove page ${i + 1}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => setState(() => _pages.removeAt(i)),
                  ),
                ),
            ],
          ),
        const SizedBox(height: 16),
        DropdownButtonFormField<String>(
          key: const ValueKey('doc-category'),
          initialValue: _category,
          decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()),
          items: [for (final c in categories) DropdownMenuItem(value: c, child: Text(documentCategoryLabels[c] ?? c))],
          onChanged: _busy ? null : (v) => setState(() => _category = v ?? _category),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('doc-title'),
          controller: _title,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Title', hintText: 'e.g. CBC, chest X-ray', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 4),
        OutlinedButton.icon(
          key: const ValueKey('doc-date'),
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(52), alignment: Alignment.centerLeft),
          onPressed: _busy ? null : _pickDate,
          icon: const Icon(Icons.event_outlined),
          label: Text(_date == null ? 'Document date (optional)' : 'Document date: ${formatDate(_date)}'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('doc-notes'),
          controller: _notes,
          maxLength: 1000,
          maxLines: 3,
          decoration: const InputDecoration(labelText: 'Notes', border: OutlineInputBorder()),
        ),
        if (_error != null) ErrorBanner(_error),
        const SizedBox(height: 8),
        FilledButton(
          key: const ValueKey('doc-submit'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          onPressed: _busy || _pages.isEmpty ? null : _submit,
          child: _busy
              ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
              : Text('Upload ${_pages.length} ${_pages.length == 1 ? 'page' : 'pages'}'),
        ),
      ]),
    );
  }
}
