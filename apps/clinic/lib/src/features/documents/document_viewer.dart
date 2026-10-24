import 'dart:typed_data';

import 'package:clinic_core/clinic_core.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'documents_models.dart';

/// Shows the pages of one document. Each page asks [linkFor] for a short-lived signed path, then fetches
/// the bytes. Images are shown inline (pinch to zoom); a PDF is opened in the system viewer through the
/// same signed link (fallback: copy the link).
class DocumentViewerPage extends StatelessWidget {
  const DocumentViewerPage({super.key, required this.title, required this.pages, required this.linkFor, required this.api});
  final String title;
  final List<DocPage> pages;
  final Future<String> Function(int page) linkFor;
  final ApiClient api;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title.isEmpty ? 'Document' : title)),
        body: pages.isEmpty
            ? const Center(child: Text('This document has no pages.'))
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: pages.length,
                separatorBuilder: (_, _) => const SizedBox(height: 16),
                itemBuilder: (_, i) => DocumentPageView(key: ValueKey('doc-page-${pages[i].page}'), page: pages[i], total: pages.length, linkFor: linkFor, api: api),
              ),
      );
}

class DocumentPageView extends StatefulWidget {
  const DocumentPageView({super.key, required this.page, required this.total, required this.linkFor, required this.api});
  final DocPage page;
  final int total;
  final Future<String> Function(int page) linkFor;
  final ApiClient api;

  @override
  State<DocumentPageView> createState() => _DocumentPageViewState();
}

class _DocumentPageViewState extends State<DocumentPageView> {
  Uint8List? _bytes;
  String? _path;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final path = await widget.linkFor(widget.page.page);
      Uint8List? bytes;
      if (!widget.page.isPdf) bytes = Uint8List.fromList(await widget.api.getBytes(path));
      if (!mounted) return;
      setState(() {
        _path = path;
        _bytes = bytes;
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

  Future<void> _openPdf() async {
    final url = '${widget.api.baseUrl}$_path';
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication).catchError((_) => false);
    if (!ok && mounted) {
      await copyToClipboard(context, url, label: 'Could not open a viewer; link copied (expires shortly)');
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.total > 1 ? 'Page ${widget.page.page} of ${widget.total}' : 'Page 1';
    Widget body;
    if (_loading) {
      body = const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
    } else if (_error != null) {
      body = SizedBox(height: 200, child: ErrorView(message: _error!, onRetry: _load));
    } else if (widget.page.isPdf) {
      body = SizedBox(
        height: 120,
        child: Center(
          child: FilledButton.icon(onPressed: _openPdf, icon: const Icon(Icons.picture_as_pdf_outlined), label: const Text('Open PDF')),
        ),
      );
    } else {
      body = InteractiveViewer(
        maxScale: 5,
        child: Image.memory(_bytes!, fit: BoxFit.contain, errorBuilder: (_, _, _) => const Padding(padding: EdgeInsets.all(24), child: Text('This page cannot be displayed.'))),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.labelLarge),
      const SizedBox(height: 6),
      body,
    ]);
  }
}
