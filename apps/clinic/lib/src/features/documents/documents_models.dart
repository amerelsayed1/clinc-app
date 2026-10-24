const documentCategoryLabels = <String, String>{
  'prescription': 'Prescription',
  'lab_result': 'Lab result',
  'imaging': 'Imaging',
  'report': 'Report',
  'administrative': 'Administrative',
  'other': 'Other',
};
const clinicalCategories = ['prescription', 'lab_result', 'imaging', 'report', 'other'];

class DocPage {
  const DocPage({required this.page, required this.mime, this.sizeBytes = 0});
  final int page;
  final String mime;
  final int sizeBytes;

  bool get isImage => mime.startsWith('image/');
  bool get isPdf => mime == 'application/pdf';

  factory DocPage.fromJson(Map<String, dynamic> j) =>
      DocPage(page: (j['page'] as num).toInt(), mime: (j['mime'] ?? '') as String, sizeBytes: ((j['sizeBytes'] ?? 0) as num).toInt());
}

class ClinicDoc {
  const ClinicDoc({
    required this.id,
    required this.source,
    required this.provenance,
    required this.category,
    required this.title,
    required this.notes,
    required this.pages,
    this.uploaderName,
    this.uploaderRole,
    this.documentDate,
    this.createdAt,
    this.encounterId,
    this.totalBytes = 0,
    this.published = false,
    this.reviewed = false,
  });

  final String id;

  /// 'clinician' | 'staff' | 'patient'
  final String source;
  final String provenance;
  final String category;
  final String title;
  final String notes;
  final List<DocPage> pages;
  final String? uploaderName;
  final String? uploaderRole;
  final String? documentDate;
  final String? createdAt;
  final String? encounterId;
  final int totalBytes;
  final bool published;
  final bool reviewed;

  bool get isPatientSubmitted => source == 'patient' || provenance == 'patient_submitted_unverified';
  bool get isAdministrative => category == 'administrative';
  String get categoryLabel => documentCategoryLabels[category] ?? category;

  factory ClinicDoc.fromJson(Map<String, dynamic> j) => ClinicDoc(
        id: j['id'] as String,
        source: (j['source'] ?? '') as String,
        provenance: (j['provenance'] ?? '') as String,
        category: (j['category'] ?? 'other') as String,
        title: (j['title'] ?? '') as String,
        notes: (j['notes'] ?? '') as String,
        pages: ((j['pages'] as List?) ?? const []).cast<Map<String, dynamic>>().map(DocPage.fromJson).toList(),
        uploaderName: j['uploaderName'] as String?,
        uploaderRole: j['uploaderRole'] as String?,
        documentDate: j['documentDate'] as String?,
        createdAt: j['createdAt'] as String?,
        encounterId: j['encounterId'] as String?,
        totalBytes: ((j['totalBytes'] ?? 0) as num).toInt(),
        published: (j['published'] ?? false) as bool,
        reviewed: (j['reviewed'] ?? false) as bool,
      );
}

class StorageUsage {
  const StorageUsage(this.usedBytes, this.quotaBytes);
  final int usedBytes;
  final int quotaBytes;
  double get fraction => quotaBytes <= 0 ? 0 : (usedBytes / quotaBytes).clamp(0, 1).toDouble();
}

/// One captured or picked page (an image) waiting to be uploaded.
class PickedPage {
  const PickedPage({required this.name, required this.bytes});
  final String name;
  final List<int> bytes;
}
