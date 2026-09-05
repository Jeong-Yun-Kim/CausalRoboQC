import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'quality_dashboard_api.dart';
import 'quality_dashboard_data.dart';

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
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  ProductRpf? _selectedProduct(DashboardData data) {
    for (final product in data.products) {
      if (product.id == _selectedProductId) return product;
    }
    return data.sortedProducts.isEmpty ? null : data.sortedProducts.first;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final data = _data;
        if (data == null) {
          return ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              SizedBox(
                height: math.max(240, constraints.maxHeight - 32),
                child: Center(
                  child: _loadError == null
                      ? const CircularProgressIndicator()
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline, size: 40),
                            const SizedBox(height: 10),
                            Text('품질 데이터를 불러오지 못했습니다.\n$_loadError'),
                            const SizedBox(height: 12),
                            OutlinedButton.icon(
                              onPressed: _loadData,
                              icon: const Icon(Icons.refresh),
                              label: const Text('다시 시도'),
                            ),
                          ],
                        ),
                ),
              ),
            ],
          );
        }

        final selected = _selectedProduct(data);
        final wide = constraints.maxWidth >= 1050;
        return RefreshIndicator(
          onRefresh: _loadData,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              _buildOverviewBanner(data),
              const SizedBox(height: 12),
              _buildKpiSection(
                '현재 전체 품질 상태',
                [
                  _KpiItem(
                    '금일 처리 제품',
                    '${data.processedProducts} EA',
                    Icons.inventory_2_outlined,
                  ),
                  _KpiItem(
                    '정상 제품 비율',
                    '${_percentage(data.normalProducts, data.processedProducts)}%',
                    Icons.verified_outlined,
                    note: '${data.normalProducts} / ${data.processedProducts}',
                    tone: _QualityTone.good,
                  ),
                  _KpiItem(
                    '확인 필요',
                    '${data.reviewProducts}건',
                    Icons.manage_search_outlined,
                    tone: _QualityTone.warning,
                  ),
                  _KpiItem(
                    '우선검사',
                    '${data.priorityProducts}건',
                    Icons.priority_high,
                    tone: _QualityTone.danger,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _buildKpiSection(
                '공정 상태',
                [
                  _KpiItem(
                    '평균 작업시간',
                    '${data.averageWorkTimeSeconds.toStringAsFixed(1)} s',
                    Icons.timer_outlined,
                    note:
                        '표준 ${data.standardWorkTimeSeconds.toStringAsFixed(1)} s · 표준 대비 ${_signed(data.averageWorkTimeSeconds - data.standardWorkTimeSeconds)} s',
                    tone: _QualityTone.warning,
                  ),
                  _KpiItem(
                    '평균 재시도',
                    '${data.averageRetries.toStringAsFixed(2)} 회/제품',
                    Icons.replay_outlined,
                  ),
                  _KpiItem(
                    '공정 이탈률',
                    '${data.processDeviationRate.toStringAsFixed(1)}%',
                    Icons.alt_route_outlined,
                    tone: _QualityTone.warning,
                  ),
                  _KpiItem(
                    '작업자 개입',
                    '${data.operatorInterventions}건',
                    Icons.front_hand_outlined,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 4, child: _buildClassification(data)),
                    const SizedBox(width: 12),
                    Expanded(flex: 7, child: _buildWorkTimeTrend(data)),
                  ],
                )
              else ...[
                _buildClassification(data),
                const SizedBox(height: 12),
                _buildWorkTimeTrend(data),
              ],
              const SizedBox(height: 12),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: _buildPareto(data)),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 5,
                      child: _buildCauseAnalysis(data, selected),
                    ),
                  ],
                )
              else ...[
                _buildPareto(data),
                const SizedBox(height: 12),
                _buildCauseAnalysis(data, selected),
              ],
              const SizedBox(height: 12),
              _buildProductTable(data),
              const SizedBox(height: 8),
              if (data.isMock)
                Text(
                  '현재 품질 KPI, 작업시간 추이, 이상 이벤트 및 원인 후보는 예시 데이터입니다.',
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

  Widget _buildOverviewBanner(DashboardData data) {
    final inspectionCount = data.reviewProducts + data.priorityProducts;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xff17263a),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 8,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final heading = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'RPF QUALITY OVERVIEW',
                    style: TextStyle(
                      color: Color(0xff92a6bd),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  if (data.isMock) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Text(
                        '예시 데이터',
                        style: TextStyle(
                          color: Color(0xffb9c5d2),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 7),
              Text(
                '금일 확인 대상 $inspectionCount건 · 우선검사 ${data.priorityProducts}건',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 5),
              const Text(
                '제품별 Robot-Process Fingerprint를 기준으로 검사 우선순위와 원인 후보를 확인합니다.',
                style: TextStyle(color: Color(0xffb9c5d2)),
              ),
            ],
          );
          final metrics = Wrap(
            spacing: 24,
            runSpacing: 12,
            children: [
              _darkMetric('처리 제품', '${data.processedProducts} EA'),
              _darkMetric(
                '정상 비율',
                '${_percentage(data.normalProducts, data.processedProducts)}%',
              ),
              _darkMetric('우선검사', '${data.priorityProducts}건'),
            ],
          );
          if (constraints.maxWidth < 760) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [heading, const SizedBox(height: 18), metrics],
            );
          }
          return Row(
            children: [
              Expanded(child: heading),
              const SizedBox(width: 24),
              metrics,
            ],
          );
        },
      ),
    );
  }

  Widget _darkMetric(String label, String value) {
    return SizedBox(
      width: 86,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(color: Color(0xff8296ac), fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildKpiSection(String title, List<_KpiItem> items) {
    return _section(
      title,
      LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 700
              ? 4
              : constraints.maxWidth >= 430
                  ? 2
                  : 1;
          final width = (constraints.maxWidth - (12 * (columns - 1))) / columns;
          return Wrap(
            spacing: 12,
            runSpacing: 12,
            children: items
                .map((item) => _buildKpiTile(item, width))
                .toList(growable: false),
          );
        },
      ),
    );
  }

  Widget _buildKpiTile(_KpiItem item, double width) {
    final color = _toneColor(item.tone);
    return Container(
      width: width,
      constraints: const BoxConstraints(minHeight: 92),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerLowest,
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: color.withValues(alpha: 0.1),
            foregroundColor: color,
            child: Icon(item.icon, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.label,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: 2),
                Text(
                  item.value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                if (item.note != null)
                  Text(
                    item.note!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildClassification(DashboardData data) {
    final groups = [
      (
        label: '정상',
        count: data.normalProducts,
        color: Colors.green.shade700,
      ),
      (
        label: '확인 필요',
        count: data.reviewProducts,
        color: Colors.orange.shade800,
      ),
      (
        label: '우선검사',
        count: data.priorityProducts,
        color: Theme.of(context).colorScheme.error,
      ),
    ];
    return _section(
      '제품 분류 현황',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '전체 ${data.processedProducts} EA',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child: SizedBox(
              height: 34,
              child: Row(
                children: groups
                    .map(
                      (group) => Expanded(
                        flex: math.max(1, group.count),
                        child: Tooltip(
                          message:
                              '${group.label} ${group.count}건 · ${_percentage(group.count, data.processedProducts)}%',
                          child: ColoredBox(color: group.color),
                        ),
                      ),
                    )
                    .toList(growable: false),
              ),
            ),
          ),
          const SizedBox(height: 16),
          ...groups.map(
            (group) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: group.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(group.label)),
                  Text(
                    '${group.count}건',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${_percentage(group.count, data.processedProducts)}%',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

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
                Colors.orange.shade800,
                '표준 ${data.standardWorkTimeSeconds.toStringAsFixed(1)}초',
                dashed: true,
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 270,
            child: CustomPaint(
              painter: _WorkTimeChartPainter(
                points: data.workTimeTrend,
                standard: data.standardWorkTimeSeconds,
                lineColor: Theme.of(context).colorScheme.primary,
                standardColor: Colors.orange.shade800,
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

  Widget _buildPareto(DashboardData data) {
    return _section(
      '이상 이벤트 현황',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: [
              _legendItem(
                Theme.of(context).colorScheme.primary,
                '발생 건수',
              ),
              _legendItem(
                Colors.orange.shade800,
                '누적 비율',
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 245,
            child: CustomPaint(
              painter: _ParetoChartPainter(
                events: data.abnormalEvents,
                barColor: Theme.of(context).colorScheme.primary,
                lineColor: Colors.orange.shade800,
                gridColor: Theme.of(context).dividerColor,
                textColor: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const Divider(),
          ...data.abnormalEvents.map(
            (event) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(child: Text(event.name)),
                  Text(
                    '${event.count}건',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(width: 14),
                  SizedBox(
                    width: 66,
                    child: Text(
                      '누적 ${event.cumulativeRatio.toStringAsFixed(1)}%',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCauseAnalysis(DashboardData data, ProductRpf? product) {
    return _section(
      '원인 후보 분석',
      product == null
          ? const SizedBox(
              height: 240,
              child: Center(child: Text('선택할 제품이 없습니다.')),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '선택 제품',
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                          Text(
                            product.id,
                            style: Theme.of(context)
                                .textTheme
                                .headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                    _gradeBadge(product.grade),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  '관측 이벤트',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 6),
                if (product.observations.isEmpty)
                  const Text('특이 관측 이벤트 없음')
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: product.observations
                        .map((observation) => Chip(label: Text(observation)))
                        .toList(growable: false),
                  ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade800.withValues(alpha: 0.06),
                    border: Border.all(
                      color: Colors.orange.shade800.withValues(alpha: 0.18),
                    ),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '분석 결과는 확정 원인이 아니라 RPF 관측값을 바탕으로 한 원인 후보입니다.',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                _causeCandidateBars(product.causeCandidates),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: OutlinedButton.icon(
                    onPressed: () => _showProductDetail(data, product),
                    icon: const Icon(Icons.timeline),
                    label: const Text('RPF 상세 보기'),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _causeCandidateBars(List<CauseCandidate> values) {
    final candidates = [...values]
      ..sort((left, right) => right.probability.compareTo(left.probability));
    if (candidates.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Text('표시할 원인 후보가 없습니다.'),
      );
    }
    return Column(
      children: candidates
          .map(
            (candidate) => Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: Text(candidate.name)),
                      Text(
                        '${candidate.probability.toStringAsFixed(0)}%',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  LinearProgressIndicator(
                    value: candidate.probability / 100,
                    minHeight: 7,
                    borderRadius: BorderRadius.circular(7),
                  ),
                ],
              ),
            ),
          )
          .toList(growable: false),
    );
  }

  Widget _buildProductTable(DashboardData data) {
    final products = data.sortedProducts;
    return _section(
      '검사 대상 제품 목록',
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '우선검사 → 확인 필요 → 정상 순서 · 제품을 선택하면 상세 RPF가 열립니다.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          if (products.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('표시할 RPF가 없습니다.')),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                showCheckboxColumn: false,
                headingTextStyle: Theme.of(context).textTheme.labelLarge,
                dataRowMinHeight: 56,
                dataRowMaxHeight: 64,
                columnSpacing: 24,
                columns: const [
                  DataColumn(label: Text('제품 ID')),
                  DataColumn(label: Text('등급')),
                  DataColumn(label: Text('작업시간'), numeric: true),
                  DataColumn(label: Text('재시도'), numeric: true),
                  DataColumn(label: Text('주요 이상')),
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
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      DataCell(_gradeBadge(product.grade, compact: true)),
                      DataCell(Text(
                          '${product.workTimeSeconds.toStringAsFixed(1)}s')),
                      DataCell(Text('${product.retries}회')),
                      DataCell(Text(product.majorAbnormality)),
                      DataCell(Text(gradeReasons)),
                      DataCell(Text(product.status)),
                    ],
                  );
                }).toList(growable: false),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showProductDetail(
    DashboardData data,
    ProductRpf product,
  ) async {
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
              maxWidth: 920,
              maxHeight: media.height * 0.9,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 10, 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${product.id} · RPF 상세',
                          style: Theme.of(dialogContext)
                              .textTheme
                              .titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                      _gradeBadge(product.grade),
                      const SizedBox(width: 6),
                      IconButton(
                        tooltip: '닫기',
                        onPressed: () => Navigator.pop(dialogContext),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'RPF 타임라인',
                          style: Theme.of(dialogContext).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        _buildRpfTimeline(product),
                        const SizedBox(height: 22),
                        Text(
                          '요약 정보',
                          style: Theme.of(dialogContext).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 10),
                        _buildProductSummary(data, product),
                        const SizedBox(height: 22),
                        Text(
                          '원인 후보',
                          style: Theme.of(dialogContext).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '확정된 불량 원인이 아닌 분석 후보입니다.',
                          style: Theme.of(dialogContext).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 10),
                        _causeCandidateBars(product.causeCandidates),
                        const SizedBox(height: 14),
                        Text(
                          '권장 점검 순서',
                          style: Theme.of(dialogContext).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        if (product.recommendations.isEmpty)
                          const Text('추가 점검 권장사항 없음')
                        else
                          ...List.generate(product.recommendations.length, (
                            index,
                          ) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 13,
                                    backgroundColor: Theme.of(
                                      dialogContext,
                                    ).colorScheme.primary,
                                    foregroundColor: Theme.of(
                                      dialogContext,
                                    ).colorScheme.onPrimary,
                                    child: Text(
                                      '${index + 1}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                  const SizedBox(width: 9),
                                  Expanded(
                                    child: Text(product.recommendations[index]),
                                  ),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRpfTimeline(ProductRpf product) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: List.generate(product.timeline.length, (index) {
          final step = product.timeline[index];
          final color =
              step.isIssue ? Colors.orange.shade800 : Colors.green.shade700;
          return Row(
            children: [
              Container(
                width: 138,
                constraints: const BoxConstraints(minHeight: 86),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.06),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          step.isIssue
                              ? Icons.warning_amber
                              : Icons.check_circle,
                          size: 17,
                          color: color,
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            step.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    if (step.detail.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        step.detail,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
              if (index < product.timeline.length - 1)
                const SizedBox(
                  width: 24,
                  child: Icon(Icons.arrow_forward, size: 16),
                ),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildProductSummary(DashboardData data, ProductRpf product) {
    final delta = product.workTimeSeconds - data.standardWorkTimeSeconds;
    final entries = [
      ('총 작업시간', '${product.workTimeSeconds.toStringAsFixed(1)} s'),
      ('표준 작업시간', '${data.standardWorkTimeSeconds.toStringAsFixed(1)} s'),
      ('표준 대비', '${_signed(delta)} s'),
      ('재시도', '${product.retries}회'),
      ('작업자 개입', '${product.operatorInterventions}회'),
      ('오류 이벤트', '${product.errorEvents}건'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 650 ? 3 : 2;
        final width = (constraints.maxWidth - (10 * (columns - 1))) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: entries
              .map(
                (entry) => Container(
                  width: width,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerLowest,
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.$1,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        entry.$2,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              )
              .toList(growable: false),
        );
      },
    );
  }

  Widget _gradeBadge(QualityGrade grade, {bool compact = false}) {
    final color = _gradeColor(grade);
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 4 : 6,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        grade.label,
        style: TextStyle(
          color: color,
          fontSize: compact ? 11 : 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _section(String title, Widget child) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }

  Color _gradeColor(QualityGrade grade) {
    return switch (grade) {
      QualityGrade.normal => Colors.green.shade700,
      QualityGrade.review => Colors.orange.shade800,
      QualityGrade.priority => Theme.of(context).colorScheme.error,
    };
  }

  Color _toneColor(_QualityTone tone) {
    return switch (tone) {
      _QualityTone.neutral => Theme.of(context).colorScheme.primary,
      _QualityTone.good => Colors.green.shade700,
      _QualityTone.warning => Colors.orange.shade800,
      _QualityTone.danger => Theme.of(context).colorScheme.error,
    };
  }

  String _percentage(int value, int total) {
    if (total == 0) return '0.0';
    return (value * 100 / total).toStringAsFixed(1);
  }

  String _signed(double value) {
    return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}';
  }
}

enum _QualityTone { neutral, good, warning, danger }

class _KpiItem {
  const _KpiItem(
    this.label,
    this.value,
    this.icon, {
    this.note,
    this.tone = _QualityTone.neutral,
  });

  final String label;
  final String value;
  final IconData icon;
  final String? note;
  final _QualityTone tone;
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
        oldDelegate.standardColor != standardColor;
  }
}

class _ParetoChartPainter extends CustomPainter {
  const _ParetoChartPainter({
    required this.events,
    required this.barColor,
    required this.lineColor,
    required this.gridColor,
    required this.textColor,
  });

  final List<AbnormalEvent> events;
  final Color barColor;
  final Color lineColor;
  final Color gridColor;
  final Color textColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (events.isEmpty || size.width <= 100 || size.height <= 100) return;
    const left = 34.0;
    const right = 38.0;
    const top = 16.0;
    const bottom = 46.0;
    final plot =
        Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final maximumCount =
        math.max(1, events.map((event) => event.count).reduce(math.max));
    final groupWidth = plot.width / events.length;

    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var index = 0; index <= 4; index++) {
      final lineY = plot.bottom - plot.height * index / 4;
      canvas.drawLine(
          Offset(plot.left, lineY), Offset(plot.right, lineY), gridPaint);
      _paintText(
        canvas,
        '${(maximumCount * index / 4).round()}',
        Offset(0, lineY - 7),
        width: left - 6,
        color: textColor,
        align: TextAlign.right,
      );
      _paintText(
        canvas,
        '${index * 25}%',
        Offset(plot.right + 4, lineY - 7),
        width: right - 4,
        color: textColor,
      );
    }

    final cumulativePath = Path();
    for (var index = 0; index < events.length; index++) {
      final event = events[index];
      final centerX = plot.left + groupWidth * (index + 0.5);
      final barHeight = plot.height * event.count / maximumCount;
      final barRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          centerX - groupWidth * 0.27,
          plot.bottom - barHeight,
          groupWidth * 0.54,
          barHeight,
        ),
        const Radius.circular(4),
      );
      canvas.drawRRect(
        barRect,
        Paint()..color = barColor.withValues(alpha: 0.82),
      );
      _paintText(
        canvas,
        '${event.count}',
        Offset(centerX - groupWidth / 2, plot.bottom - barHeight - 18),
        width: groupWidth,
        color: textColor,
        align: TextAlign.center,
      );

      final cumulativePoint = Offset(
        centerX,
        plot.bottom - plot.height * event.cumulativeRatio / 100,
      );
      if (index == 0) {
        cumulativePath.moveTo(cumulativePoint.dx, cumulativePoint.dy);
      } else {
        cumulativePath.lineTo(cumulativePoint.dx, cumulativePoint.dy);
      }
      _paintText(
        canvas,
        event.name,
        Offset(centerX - groupWidth / 2 + 2, plot.bottom + 7),
        width: groupWidth - 4,
        color: textColor,
        align: TextAlign.center,
        maxLines: 2,
      );
    }
    canvas.drawPath(
      cumulativePath,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    for (var index = 0; index < events.length; index++) {
      final point = Offset(
        plot.left + groupWidth * (index + 0.5),
        plot.bottom - plot.height * events[index].cumulativeRatio / 100,
      );
      canvas.drawCircle(point, 3.5, Paint()..color = lineColor);
    }
  }

  @override
  bool shouldRepaint(covariant _ParetoChartPainter oldDelegate) {
    return oldDelegate.events != events ||
        oldDelegate.barColor != barColor ||
        oldDelegate.lineColor != lineColor;
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
