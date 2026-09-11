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
    } catch (_) {
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
    } catch (error) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  String _timestamp(DateTime? date) => date == null
      ? '-'
      : '${_date(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}:${date.second.toString().padLeft(2, '0')}';

  Widget _dateField(bool start) {
    final value = start ? _startDate : _endDate;
    final label = start ? '시작일' : '종료일';
    return SizedBox(
        width: 210,
        child: Row(children: [
          Expanded(
              child: OutlinedButton.icon(
            onPressed: _loading ? null : () => _pickDate(start),
            icon: const Icon(Icons.calendar_today_outlined, size: 16),
            label: Text('$label\n${value == null ? '전체 기간' : _date(value)}'),
          )),
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
            icon: const Icon(Icons.close, size: 16),
          ),
        ]));
  }

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) {
        final data = _data;
        return ListView(
          padding: DashboardTheme.pagePadding(constraints.maxWidth),
          children: [
            const DashboardHeading(
                eyebrow: 'DATA BROWSER',
                title: '데이터 조회',
                description: '제품별 공정 이력을 조회하고 현재 필터 결과 전체를 CSV로 다운로드합니다.'),
            DashboardSection(
                title: '조회 조건',
                icon: Icons.filter_alt_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text('기간 · 완료 시각 기준'),
                    const SizedBox(height: 8),
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _dateField(true),
                          const Text('~'),
                          _dateField(false)
                        ]),
                    const SizedBox(height: 8),
                    Text('최근 7일 기본 조회 · 날짜와 시각은 기기 현지 시간 · 날짜를 지우면 전체 기간',
                        style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 20),
                    Wrap(spacing: 16, runSpacing: 16, children: [
                      SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('product-group-$_productGroup'),
                            initialValue: _productGroup ?? '',
                            decoration: const InputDecoration(
                                labelText: '제품군', border: OutlineInputBorder()),
                            items: [
                              const DropdownMenuItem(
                                  value: '', child: Text('전체')),
                              for (final group in {
                                ..._groups,
                                if (_productGroup != null) _productGroup!
                              })
                                DropdownMenuItem(
                                    value: group, child: Text(group))
                            ],
                            onChanged: _loading
                                ? null
                                : (value) => setState(() =>
                                    _productGroup = value == '' ? null : value),
                          )),
                      SizedBox(
                          width: 180,
                          child: DropdownButtonFormField<String>(
                            key: ValueKey('grade-$_grade'),
                            initialValue: _grade?.name ?? '',
                            decoration: const InputDecoration(
                                labelText: '등급', border: OutlineInputBorder()),
                            items: [
                              const DropdownMenuItem(
                                  value: '', child: Text('전체')),
                              for (final grade in QualityGrade.values)
                                DropdownMenuItem(
                                    value: grade.name, child: Text(grade.label))
                            ],
                            onChanged: _loading
                                ? null
                                : (value) => setState(() => _grade =
                                    QualityGrade.values
                                        .where((g) => g.name == value)
                                        .firstOrNull),
                          )),
                      SizedBox(
                          width: 260,
                          child: TextField(
                            controller: _productId,
                            enabled: !_loading,
                            maxLength: 200,
                            decoration: const InputDecoration(
                                labelText: '제품 ID',
                                hintText: '제품 ID 검색',
                                counterText: '',
                                border: OutlineInputBorder(),
                                prefixIcon: Icon(Icons.search)),
                            onChanged: (_) => setState(() {}),
                            onSubmitted: (_) => _load(_draft),
                          )),
                    ]),
                    const SizedBox(height: 20),
                    Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        spacing: 16,
                        runSpacing: 12,
                        children: [
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            FilledButton.icon(
                                onPressed:
                                    _loading ? null : () => _load(_draft),
                                icon: const Icon(Icons.search),
                                label: const Text('조회')),
                            const SizedBox(width: 8),
                            OutlinedButton(
                                onPressed: _loading ? null : _reset,
                                child: const Text('초기화')),
                          ]),
                          OutlinedButton.icon(
                            onPressed: _loading || _dirty || data == null
                                ? null
                                : _download,
                            icon: const Icon(Icons.download_outlined),
                            label: const Text('CSV 다운로드'),
                          ),
                        ]),
                    if (_dirty)
                      const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: Text('필터를 변경했습니다. 조회를 눌러 적용하세요.')),
                  ],
                )),
            const SizedBox(height: 20),
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
                                                  label: MetricLabel(title)),
                                          ],
                                          rows: [
                                            for (final row in data.items)
                                              DataRow(
                                                  key: ValueKey(row.id),
                                                  cells: [
                                                    DataCell(Text(
                                                        row.productId ?? '-')),
                                                    DataCell(Text(
                                                        row.productGroup ??
                                                            '-')),
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
    final color = switch (grade) {
      QualityGrade.normal => DashboardTheme.success,
      QualityGrade.review => DashboardTheme.warning,
      QualityGrade.priority => DashboardTheme.danger,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.09),
          borderRadius: BorderRadius.circular(8)),
      child: Text(grade.label,
          style: TextStyle(color: color, fontWeight: FontWeight.w700)),
    );
  }
}
