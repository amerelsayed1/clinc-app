import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import 'document_upload_page.dart';
import 'document_viewer.dart';
import 'documents_api.dart';
import 'documents_models.dart';
import 'format.dart';

/// Documents tab of the patient page (port of DocumentsSection.tsx).
///
/// The server filters what each role sees (front desk: clinic-uploaded administrative files only); the
/// app only decides which buttons to offer from the membership's permissions.
class DocumentsTab extends StatefulWidget {
  const DocumentsTab({super.key, required this.session, required this.patientId, this.encounterId, this.ended = false, this.picker, this.apiOverride});
  final ClinicSession session;

  /// The care-relationship id used by every `/patients/:id/...` route.
  final String patientId;
  final String? encounterId;

  /// The relationship has ended: read-only.
  final bool ended;
  final PagePicker? picker;
  final DocumentsApi? apiOverride;

  @override
  State<DocumentsTab> createState() => _DocumentsTabState();
}

class _DocumentsTabState extends State<DocumentsTab> {
  late final DocumentsApi _api = widget.apiOverride ?? DocumentsApi(widget.session.api);
  List<ClinicDoc>? _docs;
  StorageUsage? _storage;
  String? _error;
  String? _actionError;
  bool _loading = true;
  final Set<String> _busy = {};

  ClinicSession get _s => widget.session;
  bool get _canUpload => _s.can(Perm.documentsUpload) && !widget.ended;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = _docs == null;
      _error = null;
    });
    try {
      final docs = await _api.list(widget.patientId, encounterId: widget.encounterId);
      StorageUsage? storage;
      if (_s.can(Perm.documentsUpload)) {
        try {
          storage = await _api.storage();
        } catch (_) {} // the quota line is a nicety; the list is what matters
      }
      if (!mounted) return;
      setState(() {
        _docs = docs;
        _storage = storage;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = errorMessage(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _act(String id, Future<void> Function() fn, {String? done}) async {
    setState(() {
      _busy.add(id);
      _actionError = null;
    });
    try {
      await fn();
      if (done != null && mounted) showSnack(context, done);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _add() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DocumentUploadPage(
          api: _api,
          patientId: widget.patientId,
          canClinical: _s.can(Perm.documentsUploadClinical),
          encounterId: widget.encounterId,
          picker: widget.picker,
        ),
      ),
    );
    if (ok == true) {
      if (mounted) showSnack(context, 'Document uploaded');
      _load();
    }
  }

  void _view(ClinicDoc d) => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DocumentViewerPage(title: d.title, pages: d.pages, linkFor: (p) => _api.pageLink(d.id, p), api: _s.api),
        ),
      );

  Future<void> _togglePublish(ClinicDoc d) async {
    if (!d.published) {
      final ok = await _confirm(
        context,
        title: 'Show to patient?',
        message: 'The patient will be able to see "${d.title.isEmpty ? 'this document' : d.title}" in their app and is notified that a document is available.',
        confirmLabel: 'Show to patient',
      );
      if (!ok) return;
    }
    await _act(d.id, () => d.published ? _api.unpublish(d.id) : _api.publish(d.id), done: d.published ? 'Hidden from patient' : 'Shown to patient');
  }

  Future<void> _delete(ClinicDoc d) async {
    final reason = await showDialog<String>(context: context, builder: (_) => const _DeleteDialog());
    if (reason == null) return;
    await _act(d.id, () => _api.delete(d.id, reason), done: 'Document deleted');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _canUpload
          ? FloatingActionButton.extended(key: const ValueKey('add-document'), onPressed: _add, icon: const Icon(Icons.add_a_photo_outlined), label: const Text('Add document'))
          : null,
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null && _docs == null) return ErrorView(message: _error!, onRetry: _load);
    final docs = _docs ?? const [];
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
        children: [
          if (_storage != null) _StorageBar(_storage!),
          if (_actionError != null) ErrorBanner(_actionError),
          if (_error != null) ErrorBanner(_error),
          if (docs.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 48), child: Center(child: Text('No documents yet.')))
          else
            for (final d in docs) _DocCard(doc: d, session: _s, busy: _busy.contains(d.id), ended: widget.ended, onView: () => _view(d), onReview: () => _act(d.id, () => _api.review(d.id), done: 'Marked as reviewed'), onPublish: () => _togglePublish(d), onDelete: () => _delete(d)),
        ],
      ),
    );
  }
}

Future<bool> _confirm(BuildContext context, {required String title, required String message, required String confirmLabel}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(confirmLabel)),
      ],
    ),
  );
  return r == true;
}

class _StorageBar extends StatelessWidget {
  const _StorageBar(this.u);
  final StorageUsage u;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${formatBytes(u.usedBytes)} of ${formatBytes(u.quotaBytes)} used', style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: u.fraction, minHeight: 6, borderRadius: BorderRadius.circular(3)),
        ]),
      );
}

class _DocCard extends StatelessWidget {
  const _DocCard({required this.doc, required this.session, required this.busy, required this.ended, required this.onView, required this.onReview, required this.onPublish, required this.onDelete});
  final ClinicDoc doc;
  final ClinicSession session;
  final bool busy;
  final bool ended;
  final VoidCallback onView;
  final VoidCallback onReview;
  final VoidCallback onPublish;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final d = doc;
    final cs = Theme.of(context).colorScheme;
    final canWrite = session.can(Perm.clinicalWrite);
    final showReview = d.isPatientSubmitted && !d.reviewed && canWrite;
    final showPublish = !d.isPatientSubmitted && !d.isAdministrative && canWrite;
    final showDelete = !d.isPatientSubmitted && session.can(Perm.documentsUpload) && !ended;
    final date = d.documentDate ?? formatTs(d.createdAt);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        key: ValueKey('doc-${d.id}'),
        onTap: onView,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(d.title.isEmpty ? '(untitled)' : d.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              Chip(label: Text(d.categoryLabel), visualDensity: VisualDensity.compact),
              if (d.isPatientSubmitted)
                Chip(
                  label: Text(d.reviewed ? 'Patient-submitted · reviewed' : 'Patient-submitted · unverified'),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: d.reviewed ? null : cs.tertiaryContainer,
                ),
              if (d.published) const Chip(label: Text('Shown to patient'), visualDensity: VisualDensity.compact),
            ]),
            const SizedBox(height: 6),
            Text(
              '$date · ${d.pages.length} ${d.pages.length == 1 ? 'page' : 'pages'} · ${formatBytes(d.totalBytes)} · ${d.uploaderName ?? 'Patient'}${d.uploaderRole == null ? '' : ' (${d.uploaderRole})'}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (d.notes.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(d.notes)),
            if (showReview || showPublish || showDelete)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, runSpacing: 4, children: [
                  if (showReview) OutlinedButton(key: ValueKey('review-${d.id}'), onPressed: busy ? null : onReview, child: const Text('Mark reviewed')),
                  if (showPublish)
                    OutlinedButton(key: ValueKey('publish-${d.id}'), onPressed: busy ? null : onPublish, child: Text(d.published ? 'Hide from patient' : 'Show to patient')),
                  if (showDelete)
                    TextButton(key: ValueKey('delete-${d.id}'), style: TextButton.styleFrom(foregroundColor: cs.error), onPressed: busy ? null : onDelete, child: const Text('Delete')),
                ]),
              ),
          ]),
        ),
      ),
    );
  }
}

class _DeleteDialog extends StatefulWidget {
  const _DeleteDialog();
  @override
  State<_DeleteDialog> createState() => _DeleteDialogState();
}

class _DeleteDialogState extends State<_DeleteDialog> {
  final _c = TextEditingController();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('The patient will no longer see it. A reason is recorded in the audit log.'),
          const SizedBox(height: 12),
          TextField(key: const ValueKey('delete-reason'), controller: _c, maxLength: 300, autofocus: true, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Reason (at least 3 characters)', border: OutlineInputBorder())),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            key: const ValueKey('delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: _c.text.trim().length >= 3 ? () => Navigator.pop(context, _c.text.trim()) : null,
            child: const Text('Delete'),
          ),
        ],
      );
}
