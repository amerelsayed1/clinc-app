import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';

import '../appointments/clinic_clock.dart';
import 'encounters_api.dart';
import 'patients_models.dart';

/// Prescription sheet for a signed encounter (port of the dashboard's printable view). There is no
/// printer on a phone, so the sheet can be copied as plain text to paste into a print or message app.
class PrescriptionPage extends StatefulWidget {
  const PrescriptionPage({super.key, required this.api, required this.encounterId, required this.clock});
  final EncountersApi api;
  final String encounterId;
  final ClinicClock clock;

  @override
  State<PrescriptionPage> createState() => _PrescriptionPageState();
}

class _PrescriptionPageState extends State<PrescriptionPage> {
  Prescription? _rx;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final r = await widget.api.prescription(widget.encounterId);
      if (mounted) setState(() => _rx = r);
    } catch (e) {
      if (mounted) setState(() => _error = errorMessage(e));
    }
  }

  String _text(Prescription r) {
    final b = StringBuffer()
      ..writeln(r.clinic ?? 'Clinic')
      ..writeln('Dr ${r.doctorName ?? ''}${r.licenseNumber == null ? '' : ' · Licence ${r.licenseNumber}'}')
      ..writeln('${r.patientName} · ${patientNo(r.patientNumber)}${r.dateOfBirth == null ? '' : ' · DOB ${r.dateOfBirth}'}')
      ..writeln(widget.clock.dateTime(r.date))
      ..writeln();
    for (var i = 0; i < r.items.length; i++) {
      final it = r.items[i];
      b.writeln('${i + 1}. ${[it.medication, it.dose, it.frequency, it.duration].where((x) => x.isNotEmpty).join(' · ')}');
      if (it.notes.isNotEmpty) b.writeln('   ${it.notes}');
    }
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final r = _rx;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prescription'),
        actions: [
          if (r != null) IconButton(key: const ValueKey('copy-rx'), tooltip: 'Copy as text', icon: const Icon(Icons.copy_outlined), onPressed: () => copyToClipboard(context, _text(r), label: 'Prescription copied')),
        ],
      ),
      body: _error != null
          ? ErrorView(message: _error!, onRetry: _load)
          : r == null
              ? const LoadingView()
              : ListView(padding: const EdgeInsets.all(20), children: [
                  Text(r.clinic ?? 'Clinic', style: t.headlineSmall),
                  Text('Dr ${r.doctorName ?? ''}${r.licenseNumber == null ? '' : ' · Licence ${r.licenseNumber}'}'),
                  const Divider(height: 28),
                  Text('${r.patientName} · ${patientNo(r.patientNumber)}${r.dateOfBirth == null ? '' : ' · DOB ${r.dateOfBirth}'}', style: t.titleMedium),
                  Text(widget.clock.dateTime(r.date)),
                  const SizedBox(height: 16),
                  for (var i = 0; i < r.items.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        SizedBox(width: 28, child: Text('${i + 1}.')),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(r.items[i].medication, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text([r.items[i].dose, r.items[i].frequency, r.items[i].duration].where((x) => x.isNotEmpty).join(' · ')),
                            if (r.items[i].notes.isNotEmpty) Text(r.items[i].notes, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
                          ]),
                        ),
                      ]),
                    ),
                ]),
    );
  }
}
