import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class ServerCameraPreview extends StatefulWidget {
  const ServerCameraPreview({super.key, required this.apiBase, this.loadFrame});
  final String apiBase;
  final Future<Uint8List> Function()? loadFrame;

  @override
  State<ServerCameraPreview> createState() => _ServerCameraPreviewState();
}

class _ServerCameraPreviewState extends State<ServerCameraPreview> {
  Uint8List? _frame;
  bool _failed = false;
  Timer? _timer;
  final _client = http.Client();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      Uint8List bytes;
      if (widget.loadFrame != null) {
        bytes = await widget.loadFrame!();
      } else {
        final base = widget.apiBase.replaceFirst(RegExp(r'/$'), '');
        final path =
            '/api/camera/snapshot?t=${DateTime.now().millisecondsSinceEpoch}';
        final response = await _client
            .get(
                base.isEmpty ? Uri.base.resolve(path) : Uri.parse('$base$path'))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode != 200) throw Exception('Camera unavailable');
        bytes = response.bodyBytes;
      }
      if (mounted) {
        setState(() {
          _frame = bytes;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _frame = null;
        });
      }
    }
    if (mounted) {
      _timer = Timer(Duration(milliseconds: _failed ? 2000 : 250), _refresh);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('카메라'),
                const SizedBox(height: 8),
                if (_failed)
                  const Text('카메라에 연결할 수 없습니다. 연결 상태를 확인해 주세요.')
                else if (_frame == null)
                  const Text('카메라 연결 중…')
                else
                  ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Image.memory(_frame!,
                          gaplessPlayback: true,
                          semanticLabel: '서버 카메라 영상',
                          errorBuilder: (context, error, stack) =>
                              const Text('카메라 영상을 표시할 수 없습니다.'))),
              ],
            )),
      );
}
