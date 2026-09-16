import 'package:flutter/material.dart';

import 'copilot_api.dart';
import 'copilot_chart.dart';
import 'dashboard_theme.dart';
import 'quality_dashboard_data.dart';

/// Every summary and chart point comes from the API's saved analysis_results.
class RpfAnalysisOverview extends StatelessWidget {
  const RpfAnalysisOverview({super.key, required this.products});
  final List<ProductRpf> products;

  @override
  Widget build(BuildContext context) {
    final ordered = products.reversed.toList();
    final metrics = <(String, double? Function(ProductRpf))>[
      ('공정 이상도', (p) => p.analysis?.anomalyScore),
      ('검사 위험도', (p) => p.analysis?.inspectionRiskScore),
      ('공정 단계 시간 이상도', (p) => p.analysis?.timeseriesAnomalyScore),
    ];
    final analyzed = products.where((p) => p.analysis != null).length;
    String score(double? value) =>
        value == null ? '—' : '${(value * 100).toStringAsFixed(1)}%';
    return DashboardSection(
      title: '공정 분석 · 최근 제품',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('분석 결과 $analyzed / ${products.length}건'),
        const SizedBox(height: 8),
        Wrap(spacing: 24, runSpacing: 8, children: [
          for (final metric in metrics)
            Builder(builder: (context) {
              final values =
                  products.map(metric.$2).whereType<double>().toList();
              return DashboardMetric(
                  label: '${metric.$1} 평균',
                  helpTerm: metric.$1,
                  value: values.isEmpty
                      ? '—'
                      : score(values.reduce((a, b) => a + b) / values.length));
            }),
        ]),
        Text('각 평균은 해당 점수가 저장된 제품 기준입니다. 규칙 기반 등급은 별도로 유지됩니다.',
            style: Theme.of(context).textTheme.bodySmall),
        if (analyzed > 0) ...[
          const SizedBox(height: 16),
          CopilotChartView(
              chart: CopilotChart(
            type: 'line',
            title: '제품별 분석 점수 추세',
            labels: ordered.map((p) => p.id).toList(),
            series: metrics
                .map((metric) => CopilotSeries(
                    metric.$1,
                    ordered
                        .map((p) =>
                            metric.$2(p) == null ? null : metric.$2(p)! * 100)
                        .toList()))
                .toList(),
            unit: '%',
          )),
          ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('분석값 표 보기'),
              children: [
                SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(columns: [
                      const DataColumn(label: Text('제품 ID')),
                      for (final metric in metrics)
                        DataColumn(label: Text(metric.$1), numeric: true),
                    ], rows: [
                      for (final product in ordered)
                        DataRow(cells: [
                          DataCell(Text(product.id)),
                          for (final metric in metrics)
                            DataCell(Text(score(metric.$2(product)))),
                        ]),
                    ]))
              ]),
        ],
      ]),
    );
  }
}
