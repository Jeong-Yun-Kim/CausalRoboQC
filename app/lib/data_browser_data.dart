import 'quality_dashboard_data.dart';

final class DataBrowserFilter {
  const DataBrowserFilter({
    this.startDate,
    this.endDate,
    this.productGroup,
    this.grade,
    this.productId = '',
  });

  factory DataBrowserFilter.recent() {
    final now = DateTime.now();
    return DataBrowserFilter(
      startDate: DateTime(now.year, now.month, now.day - 6),
      endDate: DateTime(now.year, now.month, now.day),
    );
  }

  final DateTime? startDate;
  final DateTime? endDate;
  final String? productGroup;
  final QualityGrade? grade;
  final String productId;

  Map<String, String> get parameters => {
        if (startDate != null)
          'from_at': DateTime(
            startDate!.year,
            startDate!.month,
            startDate!.day,
          ).toUtc().toIso8601String(),
        // Construct the next local calendar day, including daylight-saving changes.
        if (endDate != null)
          'to_at': DateTime(
            endDate!.year,
            endDate!.month,
            endDate!.day + 1,
          ).toUtc().toIso8601String(),
        if (productGroup != null) 'product_group': productGroup!,
        if (grade != null) 'grade': grade!.name,
        if (productId.trim().isNotEmpty) 'product_id': productId.trim(),
      };
}

final class DataBrowserResult {
  const DataBrowserResult(
      {required this.items, required this.total, required this.productGroups});

  factory DataBrowserResult.fromJson(Map<String, dynamic> json) =>
      DataBrowserResult(
        items: (json['items'] as List)
            .map((item) => DataBrowserRecord.fromJson(
                Map<String, dynamic>.from(item as Map)))
            .toList(),
        total: json['total'] as int,
        productGroups: (json['product_groups'] as List).cast<String>(),
      );

  final List<DataBrowserRecord> items;
  final int total;
  final List<String> productGroups;
}

final class DataBrowserRecord {
  DataBrowserRecord.fromJson(Map<String, dynamic> json)
      : id = json['id'] as int,
        productId = json['product_id'] as String?,
        productGroup = json['product_group'] as String?,
        finishedAt =
            DateTime.tryParse(json['finished_at']?.toString() ?? '')?.toLocal(),
        grade = QualityGrade.values
            .where((g) => g.name == json['grade'])
            .firstOrNull,
        workTimeMs = json['work_time_ms'] as num?,
        retryCount = json['retry_count'] as int?,
        errorCount = json['error_count'] as int?,
        operatorInterventions = json['operator_interventions'] as int?,
        anomalyScore = json['anomaly_score'] as num?,
        inspectionRiskScore = json['inspection_risk_score'] as num?,
        timeseriesAnomalyScore = json['timeseries_anomaly_score'] as num?;

  final int id;
  final String? productId;
  final String? productGroup;
  final DateTime? finishedAt;
  final QualityGrade? grade;
  final num? workTimeMs;
  final int? retryCount;
  final int? errorCount;
  final int? operatorInterventions;
  final num? anomalyScore;
  final num? inspectionRiskScore;
  final num? timeseriesAnomalyScore;
}

abstract interface class DataBrowserDataSource {
  Future<DataBrowserResult> load(DataBrowserFilter filter,
      {required int limit, required int offset});
  Uri csvUri(DataBrowserFilter filter);
}
