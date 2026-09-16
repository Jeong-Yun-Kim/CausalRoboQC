import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'copilot_api.dart';
import 'copilot_chart.dart';
import 'dashboard_theme.dart';

class CopilotOverlay extends StatefulWidget {
  const CopilotOverlay(
      {super.key,
      required this.child,
      this.dataSource = const ApiCopilotDataSource()});
  final Widget child;
  final CopilotDataSource dataSource;

  @override
  State<CopilotOverlay> createState() => _CopilotOverlayState();
}

class _Entry {
  _Entry(this.question);
  final String question;
  CopilotResponse? response;
}

class _CopilotOverlayState extends State<CopilotOverlay> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _inputFocus = FocusNode();
  final _toggleFocus = FocusNode();
  final _entries = <_Entry>[];
  bool _open = false;
  bool _sending = false;

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _inputFocus.dispose();
    _toggleFocus.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (!_open) {
      _inputFocus.unfocus();
      _toggleFocus.requestFocus();
    }
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _send() async {
    final question = _input.text.trim();
    if (question.isEmpty || _sending) return;
    final entry = _Entry(question);
    setState(() {
      _sending = true;
      _entries.add(entry);
      _input.clear();
    });
    _scrollToEnd();
    CopilotResponse response;
    try {
      response = await widget.dataSource.ask(question);
    } catch (_) {
      response = const CopilotResponse(answer: copilotUnavailable);
    }
    if (!mounted) return;
    setState(() {
      entry.response = response;
      _sending = false;
    });
    // Keep the beginning of the new answer in view, even with a long table.
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final mobile = constraints.maxWidth < 600;
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      final safe = MediaQuery.paddingOf(context);
      final margin = mobile ? 8.0 : 24.0;
      final buttonBottom =
          24.0 + safe.bottom + (constraints.maxWidth < 900 ? 80.0 : 0.0);
      final panelBottom =
          mobile ? keyboard + safe.bottom + 8 : buttonBottom + 60;
      final available =
          math.max(0.0, constraints.maxHeight - panelBottom - safe.top - 12);
      final panelHeight =
          math.min(available, mobile ? constraints.maxHeight * .82 : 640.0);
      return Stack(fit: StackFit.expand, children: [
        widget.child,
        Positioned(
          right: margin,
          bottom: buttonBottom,
          child: Material(
            color: Colors.white,
            shape: const CircleBorder(
                side: BorderSide(color: DashboardTheme.border)),
            child: SizedBox.square(
              dimension: 48,
              child: IconButton(
                key: const ValueKey('copilot-toggle'),
                focusNode: _toggleFocus,
                tooltip: 'AI 코파일럿',
                onPressed: _toggle,
                style: IconButton.styleFrom(shape: const CircleBorder()),
                icon: const Icon(Icons.chat_bubble_outline, size: 21),
              ),
            ),
          ),
        ),
        if (_open)
          Positioned(
            right: margin,
            bottom: panelBottom,
            width: mobile ? constraints.maxWidth - margin * 2 : 420,
            height: panelHeight,
            child: Semantics(
              container: true,
              explicitChildNodes: true,
              label: 'AI 코파일럿',
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.escape): _toggle
                },
                child: Material(
                  key: const ValueKey('copilot-panel'),
                  color: Colors.white,
                  elevation: 2,
                  shadowColor: const Color(0x18000000),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(DashboardTheme.radius),
                    side: const BorderSide(color: DashboardTheme.border),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 16, right: 4),
                      child: Row(children: [
                        const Expanded(
                            child: Text('AI 코파일럿',
                                style: TextStyle(fontWeight: FontWeight.w600))),
                        IconButton(
                            key: const ValueKey('copilot-close'),
                            tooltip: '코파일럿 닫기',
                            constraints: const BoxConstraints.tightFor(
                                width: 48, height: 48),
                            onPressed: _toggle,
                            icon: const Icon(Icons.close, size: 20)),
                      ]),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView(
                        controller: _scroll,
                        padding: const EdgeInsets.all(16),
                        children: _entries.isEmpty
                            ? _welcome()
                            : [for (final entry in _entries) _message(entry)],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Semantics(
                                container: true,
                                child: TextField(
                                  key: const ValueKey('copilot-input'),
                                  controller: _input,
                                  focusNode: _inputFocus,
                                  maxLength: 1000,
                                  minLines: 1,
                                  maxLines: 3,
                                  textInputAction: TextInputAction.send,
                                  decoration: const InputDecoration(
                                      hintText: '질문을 입력하세요',
                                      counterText: '',
                                      contentPadding: EdgeInsets.all(12)),
                                  onSubmitted: (_) => _send(),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              height: 48,
                              child: FilledButton(
                                  key: const ValueKey('copilot-send'),
                                  onPressed: _sending ? null : _send,
                                  child: const Text('전송')),
                            ),
                          ]),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  List<Widget> _welcome() => [
        const Text('제품 및 공정 데이터에 대해 질문할 수 있습니다.'),
        const SizedBox(height: 12),
        Wrap(spacing: 4, runSpacing: 4, children: [
          for (final example in const [
            ('최근 우선검사 제품', '최근 우선검사 제품 알려줘'),
            ('판정 사유', 'RPF-014가 왜 확인 필요야?'),
            ('제품 비교', 'RPF-001과 RPF-002 비교해줘'),
            ('점검 순서', 'RPF-014 점검 순서 알려줘'),
            ('보고서 초안', 'RPF-014 품질보고서 초안 작성해줘'),
            ('공정 이상 추세', '최근 20개 제품 공정 이상도 그래프로 보여줘'),
            ('사용 방법', '데이터 조회는 어떻게 사용해?'),
          ])
            TextButton(
              onPressed: () {
                _input.text = example.$2;
                _inputFocus.requestFocus();
              },
              child: Text(example.$1, style: const TextStyle(fontSize: 12)),
            ),
        ]),
      ];

  Widget _message(_Entry entry) {
    final response = entry.response;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.all(10),
          color: DashboardTheme.background,
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('나', style: Theme.of(context).textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(entry.question),
          ]),
        ),
        const SizedBox(height: 12),
        Text('코파일럿', style: Theme.of(context).textTheme.labelSmall),
        const SizedBox(height: 6),
        if (response == null)
          Semantics(liveRegion: true, child: const Text('답변을 준비하고 있습니다…'))
        else ...[
          Semantics(
              container: true, liveRegion: true, child: Text(response.answer)),
          if (response.chart != null) ...[
            const SizedBox(height: 16),
            CopilotChartView(chart: response.chart!),
          ],
          if (response.table != null) ...[
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                key: const ValueKey('copilot-table'),
                horizontalMargin: 8,
                columnSpacing: 16,
                headingRowHeight: 36,
                dataRowMinHeight: 36,
                dataRowMaxHeight: 48,
                columns: [
                  for (final column in response.table!.columns)
                    DataColumn(label: Text(column)),
                ],
                rows: [
                  for (final row in response.table!.rows)
                    DataRow(cells: [
                      for (final value in row)
                        DataCell(Text(value?.toString() ?? '—')),
                    ]),
                ],
              ),
            ),
          ],
        ],
      ]),
    );
  }
}
