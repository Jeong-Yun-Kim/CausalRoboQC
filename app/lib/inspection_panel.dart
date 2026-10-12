import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

abstract interface class InspectionSource {
  Future<Map<String, dynamic>?> loadInspection(int rpfId);
  Future<Map<String, dynamic>> saveInspection(
      int rpfId, Map<String, dynamic> value);
}

class ApiInspectionSource implements InspectionSource {
  const ApiInspectionSource(
      {this.apiBase = const String.fromEnvironment('API_BASE_URL',
          defaultValue: 'http://127.0.0.1:8000')});
  final String apiBase;
  Uri _uri(String path) {
    final base = apiBase.replaceFirst(RegExp(r'/$'), '');
    return base.isEmpty ? Uri.base.resolve(path) : Uri.parse('$base$path');
  }

  @override
  Future<Map<String, dynamic>?> loadInspection(int rpfId) async {
    final response = await http
        .get(_uri('/api/rpf/$rpfId'))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) throw Exception('검사 결과를 불러오지 못했습니다.');
    return (jsonDecode(utf8.decode(response.bodyBytes))
        as Map<String, dynamic>)['inspection'] as Map<String, dynamic>?;
  }

  @override
  Future<Map<String, dynamic>> saveInspection(
      int rpfId, Map<String, dynamic> value) async {
    final response = await http
        .put(_uri('/api/rpf/$rpfId/inspection'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(value))
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) throw Exception('검사 결과를 저장하지 못했습니다.');
    return jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
  }
}

class InspectionPanel extends StatefulWidget {
  const InspectionPanel(
      {super.key,
      required this.rpfId,
      this.source = const ApiInspectionSource()});
  final int rpfId;
  final InspectionSource source;
  @override
  State<InspectionPanel> createState() => _InspectionPanelState();
}

class _InspectionPanelState extends State<InspectionPanel> {
  final _causes = TextEditingController();
  final _action = TextEditingController();
  final _note = TextEditingController();
  String _result = 'PASS';
  String? _message;
  String? _inspectedAt;
  bool _busy = true;
  bool _loaded = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final value = await widget.source.loadInspection(widget.rpfId);
      if (!mounted) return;
      if (value != null) {
        _result = value['result'] as String;
        _causes.text = (value['confirmed_causes'] as List).join(', ');
        _action.text = value['action'] as String;
        _note.text = value['note'] as String;
        _inspectedAt = value['inspected_at'] as String?;
      }
      _loaded = true;
    } catch (_) {
      _message = '검사 결과를 불러오지 못했습니다.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final saved = await widget.source.saveInspection(widget.rpfId, {
        'result': _result,
        'confirmed_causes': _causes.text
            .split(',')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList(),
        'action': _action.text.trim(),
        'note': _note.text.trim(),
      });
      if (!mounted) return;
      _inspectedAt = saved['inspected_at'] as String?;
      _message = '검사 결과를 저장했습니다.';
    } catch (_) {
      _message = '검사 결과를 저장하지 못했습니다. 다시 시도해 주세요.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  void dispose() {
    _causes.dispose();
    _action.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('실제 검사 결과', style: Theme.of(context).textTheme.titleMedium),
          const Text('검사 결과는 규칙 기반 등급과 별도로 저장됩니다.'),
          if (_inspectedAt != null) Text('검사 시각 · $_inspectedAt'),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
              initialValue: _result,
              key: ValueKey(_result),
              decoration: const InputDecoration(labelText: '검사 판정'),
              items: const [
                DropdownMenuItem(value: 'PASS', child: Text('PASS')),
                DropdownMenuItem(value: 'FAIL', child: Text('FAIL'))
              ],
              onChanged: _busy || !_loaded
                  ? null
                  : (value) => setState(() => _result = value!)),
          TextField(
              controller: _causes,
              enabled: !_busy && _loaded,
              maxLength: 1000,
              decoration: const InputDecoration(labelText: '확인된 원인 (쉼표 구분)')),
          TextField(
              controller: _action,
              enabled: !_busy && _loaded,
              maxLength: 2000,
              decoration: const InputDecoration(labelText: '조치')),
          TextField(
              controller: _note,
              enabled: !_busy && _loaded,
              maxLength: 4000,
              decoration: const InputDecoration(labelText: '메모')),
          const SizedBox(height: 8),
          if (_message != null) Text(_message!),
          Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                  onPressed: _busy
                      ? null
                      : _loaded
                          ? _save
                          : _load,
                  child: Text(_loaded ? '검사 결과 저장' : '검사 결과 다시 불러오기'))),
        ],
      );
}
