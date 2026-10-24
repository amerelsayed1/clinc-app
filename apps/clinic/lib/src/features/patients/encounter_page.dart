import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../../permissions.dart';
import '../../session.dart';
import '../appointments/clinic_clock.dart';
import 'amend_page.dart';
import 'encounter_draft.dart';
import 'encounter_form.dart';
import 'encounters_api.dart';
import 'patients_models.dart';
import 'prescription_page.dart';
import 'ui_bits.dart';
import 'vitals_card.dart';

/// Opens an encounter full screen.
Future<void> openEncounter(BuildContext context, ClinicSession session, String encounterId) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => EncounterPage(session: session, encounterId: encounterId)));

const _fieldLabels = {
  'chiefComplaint': 'Chief complaint',
  'history': 'History',
  'diagnosis': 'Diagnosis',
  'plan': 'Plan',
  'privateNotes': 'Private notes',
  'prescriptions': 'Prescription',
};

class EncounterPage extends StatefulWidget {
  const EncounterPage({super.key, required this.session, required this.encounterId});
  final ClinicSession session;
  final String encounterId;

  @override
  State<EncounterPage> createState() => _EncounterPageState();
}

class _EncounterPageState extends State<EncounterPage> {
  late final EncountersApi _api = EncountersApi(widget.session.api);
  GlobalKey<DraftEditorState> _editorKey = GlobalKey<DraftEditorState>();
  ClinicClock _clock = ClinicClock();
  Encounter? _enc;
  String? _error;
  String? _actionError;
  bool _busy = false;

  ClinicSession get s => widget.session;
  bool get _showPrivate => s.isDoctor;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool remountEditor = false}) async {
    try {
      final clockF = ClinicClock.load(s.api);
      final e = await _api.get(widget.encounterId);
      final clock = await clockF;
      if (!mounted) return;
      setState(() {
        _enc = e;
        _clock = clock;
        _error = null;
        if (remountEditor) _editorKey = GlobalKey<DraftEditorState>();
      });
    } catch (e) {
      if (mounted && _enc == null) setState(() => _error = errorMessage(e));
    }
  }

  bool get _isAuthor => _enc != null && _enc!.authorId == s.me?.id && s.can(Perm.clinicalWrite);

  Future<void> _run(Future<Encounter> Function() action) async {
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final e = await action();
      if (mounted) setState(() => _enc = e);
    } catch (e) {
      if (mounted) setState(() => _actionError = errorMessage(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onPop(bool didPop) async {
    if (didPop) return;
    final editor = _editorKey.currentState;
    if (editor == null || !editor.hasUnsaved) {
      Navigator.of(context).pop();
      return;
    }
    if (await editor.save()) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    if (!mounted) return;
    final leave = await confirmAction(context,
        title: 'Leave without saving?', message: 'Your latest edits could not be saved. If you leave now they are lost.', confirmLabel: 'Leave', destructive: true);
    if (leave && mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final e = _enc;
    final guard = e != null && e.isDraft && _isAuthor;
    return PopScope(
      canPop: !guard,
      onPopInvokedWithResult: (didPop, _) => _onPop(didPop),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Encounter'),
          actions: [
            if (e != null && e.isSigned && e.content.prescriptions.isNotEmpty)
              IconButton(
                key: const ValueKey('open-prescription'),
                tooltip: 'Prescription',
                icon: const Icon(Icons.medication_outlined),
                onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PrescriptionPage(api: _api, encounterId: e.id, clock: _clock))),
              ),
          ],
        ),
        body: _body(),
      ),
    );
  }

  Widget _body() {
    final e = _enc;
    if (_error != null && e == null) return ErrorView(message: _error!, onRetry: _load);
    if (e == null) return const LoadingView();
    final readOnlyDoctor = s.isDoctor && !s.can(Perm.clinicalWrite);
    return RefreshIndicator(
      onRefresh: () async {
        if (_editorKey.currentState?.hasUnsaved ?? false) return; // never replace what is being typed
        await _load();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          if (readOnlyDoctor)
            const InfoBanner(
              'Read-only: your licence verification or two-step sign-in is not complete, so you cannot edit or sign clinical notes yet.',
              icon: Icons.lock_outline,
            ),
          Text(e.patientName, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('${patientNo(e.patientNumber)} · ${_clock.dateTime(e.encounterDate)}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            StatusPill(e.isSigned ? 'Signed · v${e.currentVersion}' : 'Draft', tone: e.isSigned ? PillTone.good : PillTone.warn),
            if (e.publishedVersion != null) StatusPill('Published v${e.publishedVersion}'),
            Text('by ${e.authorName ?? 'unknown'}', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ]),
          const SizedBox(height: 12),
          VitalsCard(encounter: e, session: s, api: _api, clock: _clock, onChanged: () => _load()),
          const SizedBox(height: 16),
          if (e.isDraft)
            _isAuthor
                ? DraftEditor(
                    key: _editorKey,
                    encounter: e,
                    api: _api,
                    showPrivate: _showPrivate,
                    onSigned: (signed) => setState(() => _enc = signed),
                    onDiscarded: () => Navigator.of(context).pop(),
                    onReload: () => _load(remountEditor: true),
                  )
                : _readOnlyDraft(e)
          else
            SignedView(
              key: ValueKey('signed-${e.id}-${e.currentVersion}'),
              encounter: e,
              api: _api,
              clock: _clock,
              isAuthor: _isAuthor,
              canPublish: s.can(Perm.clinicalWrite),
              showPrivate: _showPrivate,
              busy: _busy,
              error: _actionError,
              onPublish: () => _run(() => _api.publish(e.id)),
              onUnpublish: () => _run(() => _api.unpublish(e.id)),
              onAmend: () async {
                final amended = await Navigator.of(context).push<Encounter>(MaterialPageRoute(builder: (_) => AmendPage(encounter: e, api: _api, showPrivate: _showPrivate)));
                if (amended != null && mounted) setState(() => _enc = amended);
              },
            ),
        ],
      ),
    );
  }

  Widget _readOnlyDraft(Encounter e) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InfoBanner(
          s.can(Perm.clinicalWrite)
              ? 'This draft belongs to ${e.authorName ?? 'another clinician'}. Only the author can edit or sign it.'
              : 'Draft notes are read-only for your role.${s.can(Perm.vitalsWrite) ? ' You can still record vitals above.' : ''}',
          icon: Icons.visibility_outlined,
        ),
        EncounterContentForm(key: ValueKey('ro-${e.id}-${e.revision}'), initial: e.content, onChanged: (_) {}, showPrivate: _showPrivate && e.content.privateNotes != null, readOnly: true),
      ]);
}

/// A signed encounter: version picker, amendment banner, publish/unpublish, amend.
class SignedView extends StatefulWidget {
  const SignedView({
    super.key,
    required this.encounter,
    required this.api,
    required this.clock,
    required this.isAuthor,
    required this.canPublish,
    required this.showPrivate,
    required this.busy,
    required this.onPublish,
    required this.onUnpublish,
    required this.onAmend,
    this.error,
  });
  final Encounter encounter;
  final EncountersApi api;
  final ClinicClock clock;
  final bool isAuthor;
  final bool canPublish;
  final bool showPrivate;
  final bool busy;
  final String? error;
  final VoidCallback onPublish;
  final VoidCallback onUnpublish;
  final VoidCallback onAmend;

  @override
  State<SignedView> createState() => _SignedViewState();
}

class _SignedViewState extends State<SignedView> {
  List<EncVersion>? _versions;
  int? _viewing;

  @override
  void initState() {
    super.initState();
    widget.api.versions(widget.encounter.id).then((v) {
      if (mounted) setState(() => _versions = v);
    }).catchError((Object _) {});
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.encounter;
    final versions = _versions;
    final shown = versions?.where((v) => v.meta.version == (_viewing ?? e.currentVersion)).firstOrNull;
    final content = shown?.content ?? e.content;
    final meta = shown?.meta;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (versions != null && versions.length > 1)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: DropdownButtonFormField<int>(
            key: const ValueKey('version-picker'),
            initialValue: _viewing ?? e.currentVersion,
            decoration: const InputDecoration(labelText: 'Version', border: OutlineInputBorder()),
            items: [
              for (final v in versions)
                DropdownMenuItem(value: v.meta.version, child: Text('v${v.meta.version}${v.meta.version == e.currentVersion ? ' (current)' : ''} · ${widget.clock.dateTime(v.meta.createdAt)}')),
            ],
            onChanged: (v) => setState(() => _viewing = v),
          ),
        ),
      if (meta != null && meta.version > 1)
        InfoBanner('v${meta.version} amended by ${meta.authorName ?? 'unknown'}: "${meta.amendmentReason ?? ''}" - changed ${meta.changedFields.map((f) => _fieldLabels[f] ?? f).join(', ')}.'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (widget.canPublish)
          e.currentIsPublished
              ? OutlinedButton.icon(
                  key: const ValueKey('unpublish'),
                  onPressed: widget.busy ? null : widget.onUnpublish,
                  icon: const Icon(Icons.visibility_off_outlined),
                  label: const Text('Unpublish from patient'),
                  style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
                )
              : FilledButton.icon(
                  key: const ValueKey('publish'),
                  onPressed: widget.busy ? null : widget.onPublish,
                  icon: const Icon(Icons.send_outlined),
                  label: Text(e.publishedVersion != null ? 'Publish latest version to patient' : 'Publish to patient'),
                  style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
                ),
        if (widget.isAuthor)
          OutlinedButton.icon(
            key: const ValueKey('amend'),
            onPressed: widget.onAmend,
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Amend'),
            style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
          ),
      ]),
      if (widget.error != null) Padding(padding: const EdgeInsets.only(top: 12), child: ErrorBanner(widget.error)),
      const SizedBox(height: 16),
      EncounterContentForm(
        key: ValueKey('view-${e.id}-${_viewing ?? e.currentVersion}-${versions?.length}'),
        initial: content,
        onChanged: (_) {},
        showPrivate: widget.showPrivate && content.privateNotes != null,
        readOnly: true,
      ),
    ]);
  }
}
