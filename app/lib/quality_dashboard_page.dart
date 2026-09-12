import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dashboard_theme.dart';
import 'metric_help.dart';
import 'quality_dashboard_api.dart';
import 'quality_dashboard_data.dart';
import 'rpf_analysis_panel.dart';

class QualityDashboardPage extends StatefulWidget {
  const QualityDashboardPage({
    super.key,
    this.dataSource = const ApiQualityDashboardDataSource(),
  });

  final QualityDashboardDataSource dataSource;

  @override
  State<QualityDashboardPage> createState() => _QualityDashboardPageState();
}

class _QualityDashboardPageState extends State<QualityDashboardPage> {
  DashboardData? _data;
  String? _selectedProductId;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final data = await widget.dataSource.load();
      if (!mounted) return;
      final selectedStillExists = data.products.any(
        (product) => product.id == _selectedProductId,
      );
      final firstInspection = data.sortedProducts
          .cast<ProductRpf?>()
          .firstWhere(
            (product) => product?.grade != QualityGrade.normal,
            orElse: () =>
                data.sortedProducts.isEmpty ? null : data.sortedProducts.first,
          );
      setState(() {
        _data = data;
        _selectedProductId =
            selectedStillExists ? _selectedProductId : firstInspection?.id;
        _loadError = null;
      });
    } catch (error, stack) {
      debugPrint('Quality data load failed: $error\n$stack');
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final data = _data;
        if (data == null) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: DashboardTheme.pagePadding(constraints.maxWidth),
            children: [
              _buildPageHeading(),
              ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: math.max(240, constraints.maxHeight - 200),
                ),
                child: Center(
                  child: _loadError == null
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const DashboardEmptyState(
                              icon: Icons.cloud_off_outlined,
                              title: '품질 데이터를 불러오지 못했습니다',
                              description: '서버 연결을 확인하고 다시 시도해 주세요.',
                            ),
                            const SizedBox(
                                height: DashboardTheme.sectionSpacing),
                            OutlinedButton(
                              onPressed: _loadData,
                              child: const Text('다시 시도'),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          );
        }

        final wide = constraints.maxWidth >= 1050;
        return RefreshIndicator(
          onRefresh: _loadData,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: DashboardTheme.pagePadding(constraints.maxWidth),
            children: [
              _buildPageHeading(),
              if (_loadError != null)
                const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: Text('새로고침하지 못했습니다. 이전 조회 결과를 표시합니다.')),
              _buildKpiSection(
                '최근 제품 현황',
                [
                  _KpiItem(
                    '처리 제품',
                    '${data.processedProducts}건',
                    onTap: () => _showProductList(
                      data,
                      title: '처리 제품',
                      products: data.sortedProducts,
                    ),
                  ),
                  _KpiItem(
                    '정상 제품',
                    '${data.normalProducts}건',
                    tone: _QualityTone.good,
                    onTap: () => _showProductList(
                      data,
                      title: '정상 제품',
                      products: data.sortedProducts
                          .where(
                            (product) => product.grade == QualityGrade.normal,
                          )
                          .toList(growable: false),
                    ),
                  ),
                  _KpiItem(
                    '확인 필요',
                    '${data.reviewProducts}건',
                    tone: _QualityTone.warning,
                    onTap: () => _showProductList(
                      data,
                      title: '확인 필요 제품',
                      products: data.sortedProducts
                          .where(
                            (product) => product.grade == QualityGrade.review,
                          )
                          .toList(growable: false),
                    ),
                  ),
                  _KpiItem(
                    '우선검사',
                    '${data.priorityProducts}건',
                    tone: _QualityTone.danger,
                    onTap: () => _showProductList(
                      data,
                      title: '우선검사 제품',
                      products: data.sortedProducts
                          .where(
                            (product) => product.grade == QualityGrade.priority,
                          )
                          .toList(growable: false),
                    ),
                  ),
                ],
              ),
              _buildKpiSection(
                '공정 상태',
                [
                  _KpiItem(
                    '평균 작업시간',
                    '${data.averageWorkTimeSeconds.toStringAsFixed(1)}초',
                    tone: _QualityTone.warning,
                    onTap: () {
                      final products = [...data.products]..sort(
                          (left, right) => right.workTimeSeconds
                              .compareTo(left.workTimeSeconds),
                        );
                      _showProductList(
                        data,
                        title: '평균 작업시간',
                        summary:
                            '평균 ${data.averageWorkTimeSeconds.toStringAsFixed(1)} s · 작업시간 긴 순',
                        products: products,
                      );
                    },
                  ),
                  _KpiItem(
                    '평균 재시도',
                    '${data.averageRetries.toStringAsFixed(2)} 회/제품',
                    onTap: () {
                      final products = data.products
                          .where((product) => product.retries > 0)
                          .toList()
                        ..sort(
                          (left, right) =>
                              right.retries.compareTo(left.retries),
                        );
                      _showProductList(
                        data,
                        title: '평균 재시도',
                        summary:
                            '평균 ${data.averageRetries.toStringAsFixed(2)} 회/제품 · 재시도 많은 순',
                        products: products,
                      );
                    },
                  ),
                  _KpiItem(
                    '공정 이탈률',
                    '${data.processDeviationRate.toStringAsFixed(1)}%',
                    tone: _QualityTone.warning,
                    onTap: () => _showProductList(
                      data,
                      title: '공정 이탈 제품',
                      products: data.sortedProducts
                          .where(
                            (product) => product.grade != QualityGrade.normal,
                          )
                          .toList(growable: false),
                    ),
                  ),
                  _KpiItem(
                    '작업자 개입',
                    '${data.operatorInterventions}건',
                    onTap: () => _showProductList(
                      data,
                      title: '작업자 개입 제품',
                      products: data.sortedProducts
                          .where(
                            (product) => product.operatorInterventions > 0,
                          )
                          .toList(growable: false),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: DashboardTheme.sectionSpacing),
              _buildProductTable(data),
              const SizedBox(height: DashboardTheme.sectionSpacing),
              if (wide)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: _buildWorkTimeTrend(data)),
                  const SizedBox(width: DashboardTheme.sectionSpacing),
                  Expanded(child: _buildAbnormalEvents(data)),
                ])
              else ...[
                _buildWorkTimeTrend(data),
                const SizedBox(height: DashboardTheme.sectionSpacing),
                _buildAbnormalEvents(data),
              ],
              const SizedBox(height: 8),
              if (data.isMock)
                Text(
                  '예시 데이터',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPageHeading() => DashboardHeading(
        title: '품질관리',
        trailing: TextButton(
          onPressed: _loadData,
          child: const Text('새로고침'),
        ),
      );

  Widget _buildKpiSection(String title, List<_KpiItem> items) => Wrap(
        spacing: 28,
        runSpacing: 4,
        children: items
            .map((item) => DashboardMetric(
                  label: item.label,
                  value: item.value,
                  helpTerm: metricDescriptions.containsKey(item.label)
                      ? item.label
                      : null,
                  color: title == '공정 상태'
                      ? DashboardTheme.ink
                      : _toneColor(item.tone),
                  onTap: item.onTap,
                ))
            .toList(growable: false),
      );

  Widget _buildWorkTimeTrend(DashboardData data) {
    return _section(
      '제품별 작업시간 추이',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              _legendItem(
                Theme.of(context).colorScheme.primary,
                '실제 작업시간',
              ),
              _legendItem(
                DashboardTheme.muted,
                '평균 ${data.averageWorkTimeSeconds.toStringAsFixed(1)}초',
                dashed: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: data.workTimeTrend.isEmpty ? null : 210,
            child: data.workTimeTrend.isEmpty
                ? const DashboardEmptyState(
                    icon: Icons.show_chart_rounded, title: '작업시간 기록이 없습니다')
                : CustomPaint(
                    painter: _WorkTimeChartPainter(
                      points: data.workTimeTrend,
                      standard: data.averageWorkTimeSeconds,
                      lineColor: Theme.of(context).colorScheme.primary,
                      standardColor: DashboardTheme.muted,
                      gridColor: Theme.of(context).dividerColor,
                      textColor: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _legendItem(Color color, String label, {bool dashed = false}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 20,
          child: dashed
              ? Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(width: 7, height: 2, color: color),
                    Container(width: 7, height: 2, color: color),
                  ],
                )
              : Container(height: 3, color: color),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }

  Widget _buildAbnormalEvents(DashboardData data) {
    return _section(
      '이상 이벤트 발생 비율',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '전체 처리 제품 중 각 이상이 관측된 제품의 비율입니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          if (data.abnormalEvents.isEmpty)
            const DashboardEmptyState(
                icon: Icons.check_circle_outline, title: '관측된 이상 이벤트가 없습니다')
          else
            ...data.abnormalEvents.map(
              (event) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _buildAbnormalEventRow(data, event),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAbnormalEventRow(DashboardData data, AbnormalEvent event) =>
      Column(children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(event.name),
          trailing: Text('${event.count}건 · ${event.rate.toStringAsFixed(1)}%'),
          onTap: () => _showProductList(data,
              title: event.name,
              products: data.sortedProducts
                  .where((product) => product.observations.contains(event.name))
                  .toList()),
        ),
        const Divider(height: 1),
      ]);

  Widget _buildProductTable(DashboardData data) {
    final products = data.sortedProducts;
    return _section(
      '제품 목록 · 최근 최대 50건',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (products.isEmpty)
            const DashboardEmptyState(
                icon: Icons.inventory_2_outlined, title: '수집된 제품 기록이 없습니다')
          else
            LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minWidth: constraints.maxWidth),
                        child: DataTable(
                          showCheckboxColumn: false,
                          columnSpacing: 24,
                          columns: const [
                            DataColumn(label: Text('제품 ID')),
                            DataColumn(label: MetricLabel('등급')),
                            DataColumn(label: Text('작업시간'), numeric: true),
                            DataColumn(label: Text('재시도'), numeric: true),
                            DataColumn(label: Text('판정 근거')),
                            DataColumn(label: Text('상태')),
                          ],
                          rows: products.map((product) {
                            final selected = product.id == _selectedProductId;
                            final gradeReasons = product.observations.isEmpty
                                ? '-'
                                : product.observations.join(', ');
                            return DataRow(
                              selected: selected,
                              onSelectChanged: (_) {
                                setState(() => _selectedProductId = product.id);
                                _showProductDetail(data, product);
                              },
                              cells: [
                                DataCell(
                                  Text(
                                    product.id,
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w600),
                                  ),
                                ),
                                DataCell(
                                    _gradeBadge(product.grade, compact: true)),
                                DataCell(Text(
                                    '${product.workTimeSeconds.toStringAsFixed(1)}초')),
                                DataCell(Text('${product.retries}회')),
                                DataCell(SizedBox(
                                    width: 220,
                                    child: Text(gradeReasons,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis))),
                                DataCell(Text(product.status)),
                              ],
                            );
                          }).toList(growable: false),
                        ),
                      ),
                    )),
        ],
      ),
    );
  }

  Future<void> _showProductList(
    DashboardData data, {
    required String title,
    required List<ProductRpf> products,
    String? summary,
  }) async {
    ProductRpf? selectedProduct;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final media = MediaQuery.sizeOf(dialogContext);
        return Dialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: media.width < 700 ? 12 : 40,
            vertical: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: DashboardTheme.dialogWidth,
              maxHeight: media.height * 0.88,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              title,
                              style: Theme.of(dialogContext)
                                  .textTheme
                                  .titleLarge
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              summary ?? '제품 ${products.length}건',
                              style:
                                  Theme.of(dialogContext).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                if (products.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(20),
                    child: Text('해당하는 제품이 없습니다.'),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      padding: const EdgeInsets.all(12),
                      itemCount: products.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final product = products[index];
                        final reasons = product.observations.isEmpty
                            ? '-'
                            : product.observations.join(', ');
                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              selectedProduct = product;
                              Navigator.pop(dialogContext);
                            },
                            child: Padding(
                              padding: const EdgeInsets.all(13),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          product.id,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      _gradeBadge(product.grade, compact: true),
                                    ],
                                  ),
                                  const SizedBox(height: 7),
                                  Text(
                                    '작업시간 ${product.workTimeSeconds.toStringAsFixed(1)}초 · '
                                    '재시도 ${product.retries}회',
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '판정 근거: $reasons',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (!mounted || selectedProduct == null) return;
    setState(() => _selectedProductId = selectedProduct!.id);
    await _showProductDetail(data, selectedProduct!);
  }

  Future<void> _showProductDetail(
      DashboardData data, ProductRpf product) async {
    await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final media = MediaQuery.sizeOf(dialogContext);
          return Dialog(
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxWidth: DashboardTheme.dialogWidth,
                  maxHeight: media.height - 48),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 12),
                    child: Row(children: [
                      Expanded(
                          child: MetricLabel('제품 상세',
                              term: 'RPF',
                              style: Theme.of(context).textTheme.titleLarge)),
                      IconButton(
                          tooltip: '닫기',
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close)),
                    ])),
                const Divider(height: 1),
                Flexible(
                    child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(product.id,
                            style: Theme.of(context).textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Wrap(spacing: 20, runSpacing: 6, children: [
                          Text('제품군 · ${product.productGroup ?? '-'}'),
                          Text('완료 시각 · ${_finishedAt(product.finishedAt)}'),
                        ]),
                        const SizedBox(height: DashboardTheme.sectionSpacing),
                        Row(children: [
                          const MetricLabel('규칙 기반 등급', term: '등급'),
                          const SizedBox(width: 12),
                          _gradeBadge(product.grade),
                        ]),
                        const SizedBox(height: 12),
                        Text('판정 근거',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 6),
                        if (product.observations.isEmpty)
                          const Text('공정 이상 없음')
                        else
                          ...product.observations.map((reason) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 3),
                              child: Text(reason))),
                        const Divider(height: 24),
                        Text('공정 데이터',
                            style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 12),
                        _buildProductSummary(data, product),
                        const Divider(height: 24),
                        RpfAnalysisPanel(
                            product: product,
                            source: widget.dataSource is RpfAnalysisDataSource
                                ? widget.dataSource as RpfAnalysisDataSource
                                : null),
                        if (product.timeline.isNotEmpty) ...[
                          const Divider(height: 24),
                          Text('작업 이력',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 12),
                          _buildRpfTimeline(product),
                        ],
                        if (product.recommendations.isNotEmpty) ...[
                          const Divider(height: 24),
                          Text('권장 점검',
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 8),
                          ...product.recommendations.map((text) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Text(text))),
                        ],
                      ]),
                )),
              ]),
            ),
          );
        });
  }

  String _finishedAt(DateTime? value) {
    if (value == null) return '-';
    final local = value.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Widget _buildRpfTimeline(ProductRpf product) => Column(
        children: product.timeline
            .where((step) => step.name != '판정 근거')
            .map((step) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(step.name)),
                        const SizedBox(width: 12),
                        Flexible(
                            child: Text(
                                step.detail.startsWith('cycle ')
                                    ? ''
                                    : step.detail,
                                textAlign: TextAlign.end,
                                style: Theme.of(context).textTheme.bodySmall)),
                      ]),
                ))
            .toList(),
      );

  Widget _buildProductSummary(DashboardData data, ProductRpf product) => Column(
        children: [
          for (final entry in [
            ('총 작업시간', '${product.workTimeSeconds.toStringAsFixed(1)}초'),
            ('재시도', '${product.retries}회'),
            ('오류', '${product.errorEvents}건'),
            ('작업자 개입', '${product.operatorInterventions}회'),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(children: [
                Expanded(child: Text(entry.$1)),
                Text(entry.$2),
              ]),
            ),
        ],
      );

  Widget _gradeBadge(QualityGrade grade, {bool compact = false}) =>
      DashboardStatusBadge(grade.label, color: _gradeColor(grade));

  Widget _section(String title, Widget child) =>
      DashboardSection(title: title, child: child);

  Color _gradeColor(QualityGrade grade) {
    return switch (grade) {
      QualityGrade.normal => DashboardTheme.success,
      QualityGrade.review => DashboardTheme.warning,
      QualityGrade.priority => Theme.of(context).colorScheme.error,
    };
  }

  Color _toneColor(_QualityTone tone) {
    return switch (tone) {
      _QualityTone.neutral => Theme.of(context).colorScheme.primary,
      _QualityTone.good => DashboardTheme.success,
      _QualityTone.warning => DashboardTheme.warning,
      _QualityTone.danger => Theme.of(context).colorScheme.error,
    };
  }
}

enum _QualityTone { neutral, good, warning, danger }

class _KpiItem {
  const _KpiItem(
    this.label,
    this.value, {
    this.tone = _QualityTone.neutral,
    required this.onTap,
  });

  final String label;
  final String value;
  final _QualityTone tone;
  final VoidCallback onTap;
}

class _WorkTimeChartPainter extends CustomPainter {
  const _WorkTimeChartPainter({
    required this.points,
    required this.standard,
    required this.lineColor,
    required this.standardColor,
    required this.gridColor,
    required this.textColor,
  });

  final List<WorkTimePoint> points;
  final double standard;
  final Color lineColor;
  final Color standardColor;
  final Color gridColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 80 || size.height <= 80) return;
    const left = 42.0;
    const right = 14.0;
    const top = 14.0;
    const bottom = 34.0;
    final plot =
        Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final values = [...points.map((point) => point.seconds), standard];
    final minimum = math.max(0.0, values.reduce(math.min).floorToDouble() - 1);
    final maximum = values.reduce(math.max).ceilToDouble() + 1;
    final range = math.max(1.0, maximum - minimum);

    double y(double value) =>
        plot.bottom - ((value - minimum) / range) * plot.height;
    double x(int index) => points.length == 1
        ? plot.center.dx
        : plot.left + (index / (points.length - 1)) * plot.width;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final value = minimum + range * index / 4;
      final lineY = y(value);
      canvas.drawLine(
          Offset(plot.left, lineY), Offset(plot.right, lineY), gridPaint);
      _paintText(
        canvas,
        value.toStringAsFixed(0),
        Offset(0, lineY - 7),
        width: left - 7,
        color: textColor,
        align: TextAlign.right,
      );
    }

    final standardY = y(standard);
    final standardPaint = Paint()
      ..color = standardColor
      ..strokeWidth = 1.6;
    for (double start = plot.left; start < plot.right; start += 9) {
      canvas.drawLine(
        Offset(start, standardY),
        Offset(math.min(start + 5, plot.right), standardY),
        standardPaint,
      );
    }

    final path = Path();
    for (var index = 0; index < points.length; index++) {
      final point = Offset(x(index), y(points[index].seconds));
      if (index == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    final area = Path.from(path)
      ..lineTo(x(points.length - 1), plot.bottom)
      ..lineTo(x(0), plot.bottom)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            lineColor.withValues(alpha: 0.18),
            lineColor.withValues(alpha: 0.01)
          ],
        ).createShader(plot),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..strokeWidth = 2.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (var index = 0; index < points.length; index++) {
      final point = Offset(x(index), y(points[index].seconds));
      canvas.drawCircle(
        point,
        3.5,
        Paint()
          ..color =
              points[index].seconds > standard ? standardColor : lineColor,
      );
    }

    final labelIndexes = <int>{
      0,
      points.length ~/ 4,
      points.length ~/ 2,
      (points.length * 3) ~/ 4,
      points.length - 1,
    };
    for (final index in labelIndexes) {
      _paintText(
        canvas,
        points[index].productId,
        Offset(x(index) - 28, plot.bottom + 8),
        width: 56,
        color: textColor,
        align: TextAlign.center,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WorkTimeChartPainter oldDelegate) {
    return oldDelegate.points != points ||
        oldDelegate.standard != standard ||
        oldDelegate.lineColor != lineColor ||
        oldDelegate.standardColor != standardColor ||
        oldDelegate.gridColor != gridColor ||
        oldDelegate.textColor != textColor;
  }
}

void _paintText(
  Canvas canvas,
  String text,
  Offset offset, {
  required double width,
  required Color color,
  TextAlign align = TextAlign.left,
  int maxLines = 1,
}) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: 10),
    ),
    textAlign: align,
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
    ellipsis: '…',
  )..layout(maxWidth: width);
  painter.paint(canvas, offset);
}
