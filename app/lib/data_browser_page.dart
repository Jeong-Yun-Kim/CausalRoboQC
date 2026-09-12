import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'dashboard_theme.dart';
import 'data_browser_api.dart';
import 'data_browser_data.dart';
import 'data_browser_download.dart';
import 'metric_help.dart';
import 'quality_dashboard_data.dart';

class DataBrowserPage extends StatefulWidget {
  const DataBrowserPage({
    super.key,
    this.dataSource = const ApiDataBrowserDataSource(),
    this.onDownload = downloadCsv,
  });

  final DataBrowserDataSource dataSource;
  final void Function(Uri) onDownload;

  @override
  State<DataBrowserPage> createState() => _DataBrowserPageState();
}

class _DataBrowserPageState extends State<DataBrowserPage> {
  static const _pageSize = 25;
  final _productId = TextEditingController();
  final _horizontalScroll = ScrollController();
  late DataBrowserFilter _applied;
  DateTime? _startDate;
  DateTime? _endDate;
  String? _productGroup;
  QualityGrade? _grade;
  DataBrowserResult? _data;
  List<String> _groups = [];
  bool _loading = false;
  String? _error;
  int _offset = 0;

  DataBrowserFilter get _draft => DataBrowserFilter(
        startDate: _startDate,
        endDate: _endDate,
        productGroup: _productGroup,
        grade: _grade,
        productId: _productId.text,
      );
  bool get _dirty => !mapEquals(_draft.parameters, _applied.parameters);

  @override
  void initState() {
    super.initState();
    _applied = DataBrowserFilter.recent();
    _startDate = _applied.startDate;
    _endDate = _applied.endDate;
    _load(_applied);
  }

  @override
  void dispose() {
    _productId.dispose();
    _horizontalScroll.dispose();
    super.dispose();
  }

  Future<void> _load(DataBrowserFilter filter, {int offset = 0}) async {
    if (_loading) return;
    if (filter.startDate != null &&
        filter.endDate != null &&
        filter.startDate!.isAfter(filter.endDate!)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('종료일은 시작일 이후로 선택해 주세요.')),
      );
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await widget.dataSource
          .load(filter, limit: _pageSize, offset: offset);
      if (!mounted) return;
      setState(() {
        _data = data;
        _groups = data.productGroups;
        _applied = filter;
        _offset = offset;
      });
    } catch (error, stack) {
      debugPrint('Data browser load failed: $error\n$stack');
      if (!mounted) return;
      setState(() {
        _data = null;
        _error = '데이터를 불러오지 못했습니다. 서버 연결을 확인하고 다시 조회해 주세요.';
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _reset() {
    final recent = DataBrowserFilter.recent();
    setState(() {
      _startDate = recent.startDate;
      _endDate = recent.endDate;
      _productGroup = null;
      _grade = null;
      _productId.clear();
    });
    _load(_draft);
  }

  Future<void> _pickDate(bool start) async {
    final date = await showDatePicker(
      context: context,
      initialDate: (start ? _startDate : _endDate) ?? DateTime.now(),
      firstDate: DateTime(1970),
      lastDate: DateTime(9999, 12, 31),
      helpText: start ? '시작일 선택' : '종료일 선택',
      cancelText: '취소',
      confirmText: '선택',
    );
    if (date == null || !mounted) return;
    setState(() {
      if (start) {
        _startDate = date;
      } else {
        _endDate = date;
      }
    });
  }

  void _download() {
    try {
      widget.onDownload(widget.dataSource.csvUri(_applied));
    } catch (error, stack) {
      debugPrint('CSV download failed: $error\n$stack');
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('CSV를 다운로드하지 못했습니다.')));
    }
  }

  String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _timestamp(DateTime? date) => date == null
      ? '-'
      : '${_date(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';

  Widget _dateField(bool start, double width) {
    final value = start ? _startDate : _endDate;
    final label = start ? '시작일' : '종료일';
    return SizedBox(
      width: width,
      height: 48,
      child: InputDecorator(
        decoration: InputDecoration(
            labelText: label, contentPadding: const EdgeInsets.only(left: 12)),
        child: Row(children: [
          Expanded(
            child: InkWell(
                onTap: _loading ? null : () => _pickDate(start),
                child: SizedBox(
                    height: DashboardTheme.controlHeight,
                    child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(value == null ? '전체 기간' : _date(value),
                            style: const TextStyle(fontSize: 12))))),
          ),
          IconButton(
              tooltip: '$label 지우기',
              onPressed: _loading || value == null
                  ? null
                  : () => setState(() {
                        if (start) {
                          _startDate = null;
                        } else {
                          _endDate = null;
                        }
                      }),
              icon: const Icon(Icons.close, size: 16)),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final data = _data;
        final contentWidth = constraints.maxWidth -
            DashboardTheme.pagePadding(constraints.maxWidth).horizontal;
        final fieldWidth = contentWidth < 600 ? (contentWidth - 12) / 2 : 160.0;
        return ListView(
          padding: DashboardTheme.pagePadding(constraints.maxWidth),
          children: [
            DashboardHeading(
                title: '데이터 조회',
                trailing: OutlinedButton.icon(
                    onPressed:
                        _loading || _dirty || data == null ? null : _download,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('CSV 다운로드'))),
            Wrap(
                spacing: 12,
                runSpacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  _dateField(true, fieldWidth),
                  _dateField(false, fieldWidth),
                  SizedBox(
                      width: fieldWidth,
                      height: 48,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('product-group-$_productGroup'),
                        isExpanded: true,
                        initialValue: _productGroup ?? '',
                        decoration: const InputDecoration(labelText: '제품군'),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('전체')),
                          for (final group in {
                            ..._groups,
                            if (_productGroup != null) _productGroup!
                          })
                            DropdownMenuItem(value: group, child: Text(group))
                        ],
                        onChanged: _loading
                            ? null
                            : (value) => setState(() =>
                                _productGroup = value == '' ? null : value),
                      )),
                  SizedBox(
                      width: fieldWidth,
                      height: 48,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey('grade-$_grade'),
                        isExpanded: true,
                        initialValue: _grade?.name ?? '',
                        decoration: const InputDecoration(labelText: '등급'),
                        items: [
                          const DropdownMenuItem(value: '', child: Text('전체')),
                          for (final grade in QualityGrade.values)
                            DropdownMenuItem(
                                value: grade.name, child: Text(grade.label))
                        ],
                        onChanged: _loading
                            ? null
                            : (value) => setState(() => _grade = QualityGrade
                                .values
                                .where((g) => g.name == value)
                                .firstOrNull),
                      )),
                  SizedBox(
                      width: contentWidth < 600 ? contentWidth : 200,
                      height: 48,
                      child: TextField(
                        controller: _productId,
                        enabled: !_loading,
                        maxLength: 200,
                        decoration: const InputDecoration(
                            labelText: '제품 ID',
                            hintText: '제품 ID 검색',
                            counterText: '',
                            prefixIcon: Icon(Icons.search, size: 18)),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _load(_draft),
                      )),
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    FilledButton(
                        onPressed: _loading ? null : () => _load(_draft),
                        child: const Text('조회')),
                    const SizedBox(width: 8),
                    OutlinedButton(
                        onPressed: _loading ? null : _reset,
                        child: const Text('초기화')),
                  ]),
                ]),
            const SizedBox(height: 12),
            Text(_dirty ? '필터를 변경했습니다. 조회를 눌러 적용하세요.' : '완료 시각 기준 · 기기 현지 시간',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: DashboardTheme.sectionSpacing),
            if (_loading) const LinearProgressIndicator(),
            DashboardSection(
                title: data == null ? '조회 결과' : '조회 결과 · 총 ${data.total}건',
                icon: Icons.table_chart_outlined,
                child: _error != null
                    ? Text(_error!,
                        style: const TextStyle(color: DashboardTheme.danger))
                    : data == null
                        ? const SizedBox(height: 120)
                        : data.items.isEmpty
                            ? const DashboardEmptyState(
                                icon: Icons.search_off,
                                title: '조건에 맞는 데이터가 없습니다.')
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                    Scrollbar(
                                      controller: _horizontalScroll,
                                      thumbVisibility: true,
                                      child: SingleChildScrollView(
                                        controller: _horizontalScroll,
                                        scrollDirection: Axis.horizontal,
                                        padding:
                                            const EdgeInsets.only(bottom: 16),
                                        child: DataTable(
                                          columnSpacing: 24,
                                          headingRowColor:
                                              const WidgetStatePropertyAll(
                                                  DashboardTheme.background),
                                          columns: [
                                            for (final title in [
                                              '제품 ID',
                                              '제품군',
                                              '완료 시각',
                                              '등급',
                                              '작업시간',
                                              '재시도',
                                              '오류',
                                              '작업자 개입',
                                              '공정 이상도',
                                              '검사 위험도',
                                              '공정 단계 시간 이상도'
                                            ])
                                              DataColumn(
                                                  numeric: ![
                                                    '제품 ID',
                                                    '제품군',
                                                    '완료 시각',
                                                    '등급'
                                                  ].contains(title),
                                                  label: MetricLabel(title)),
                                          ],
                                          rows: [
                                            for (final row in data.items)
                                              DataRow(
                                                  key: ValueKey(row.id),
                                                  cells: [
                                                    DataCell(SizedBox(
                                                        width: 140,
                                                        child: Text(
                                                            row.productId ??
                                                                '-',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis))),
                                                    DataCell(SizedBox(
                                                        width: 100,
                                                        child: Text(
                                                            row.productGroup ??
                                                                '-',
                                                            maxLines: 1,
                                                            overflow:
                                                                TextOverflow
                                                                    .ellipsis))),
                                                    DataCell(Text(_timestamp(
                                                        row.finishedAt))),
                                                    DataCell(
                                                        _gradeBadge(row.grade)),
                                                    DataCell(Text(row
                                                                .workTimeMs ==
                                                            null
                                                        ? '-'
                                                        : '${(row.workTimeMs! / 1000).toStringAsFixed(2)}초')),
                                                    DataCell(Text(
                                                        '${row.retryCount ?? '-'}')),
                                                    DataCell(Text(
                                                        '${row.errorCount ?? '-'}')),
                                                    DataCell(Text(
                                                        '${row.operatorInterventions ?? '-'}')),
                                                    for (final score in [
                                                      row.anomalyScore,
                                                      row.inspectionRiskScore,
                                                      row.timeseriesAnomalyScore
                                                    ])
                                                      DataCell(Text(score ==
                                                              null
                                                          ? '-'
                                                          : '${(score * 100).toStringAsFixed(1)}%')),
                                                  ])
                                          ],
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 12),
                                    Wrap(
                                        alignment: WrapAlignment.spaceBetween,
                                        runSpacing: 8,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                              '${_offset + 1}–${_offset + data.items.length} / ${data.total}건'),
                                          Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                OutlinedButton(
                                                    onPressed: _loading ||
                                                            _dirty ||
                                                            _offset == 0
                                                        ? null
                                                        : () => _load(_applied,
                                                            offset: _offset -
                                                                _pageSize),
                                                    child: const Text('이전')),
                                                const SizedBox(width: 8),
                                                OutlinedButton(
                                                    onPressed: _loading ||
                                                            _dirty ||
                                                            _offset +
                                                                    _pageSize >=
                                                                data.total
                                                        ? null
                                                        : () => _load(_applied,
                                                            offset: _offset +
                                                                _pageSize),
                                                    child: const Text('다음')),
                                              ]),
                                        ]),
                                  ])),
          ],
        );
      });

  Widget _gradeBadge(QualityGrade? grade) {
    if (grade == null) return const Text('-');
    return DashboardStatusBadge(grade.label,
        color: switch (grade) {
          QualityGrade.normal => DashboardTheme.success,
          QualityGrade.review => DashboardTheme.warning,
          QualityGrade.priority => DashboardTheme.danger,
        });
  }
}
