import 'dart:js_interop';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:web/web.dart' as web;

import 'dashboard_theme.dart';

/// Local browser preview only: no audio, recording, uploads or robot commands.
class CameraPreview extends StatefulWidget {
  const CameraPreview({super.key});

  @override
  State<CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<CameraPreview>
    with AutomaticKeepAliveClientMixin {
  web.MediaStream? _stream;
  web.HTMLVideoElement? _video;
  List<web.MediaDeviceInfo> _devices = [];
  String? _deviceId;
  bool _starting = false;
  bool _unavailable = false;
  int _request = 0;

  // Scrolling down to the robot controls must not dispose an active preview.
  @override
  bool get wantKeepAlive => true;

  static void _stopTracks(web.MediaStream stream) {
    for (final track in stream.getTracks().toDart) {
      track.onended = null;
      track.stop();
    }
  }

  void _release() {
    final stream = _stream;
    _stream = null;
    if (stream != null) _stopTracks(stream);
    _video?.pause();
    _video?.srcObject = null;
    _video = null;
  }

  void _stop({bool unavailable = false}) {
    ++_request;
    _release();
    setState(() {
      _starting = false;
      _unavailable = unavailable;
    });
  }

  Future<void> _start([String? deviceId]) async {
    final target = deviceId ?? _deviceId;
    final request = ++_request;
    _release();
    setState(() {
      _starting = true;
      _unavailable = false;
    });
    try {
      final stream = await web.window.navigator.mediaDevices
          .getUserMedia(web.MediaStreamConstraints(
            audio: false.toJS,
            video: target == null
                ? true.toJS
                : web.MediaTrackConstraints(
                    deviceId:
                        web.ConstrainDOMStringParameters(exact: target.toJS)),
          ))
          .toDart;
      // A permission prompt may resolve after stop, tab change or disposal.
      if (!mounted || request != _request) {
        _stopTracks(stream);
        return;
      }
      _stream = stream;
      for (final track in stream.getVideoTracks().toDart) {
        track.onended = ((web.Event _) {
          if (mounted && request == _request) _stop(unavailable: true);
        }).toJS;
      }
      setState(() {
        _starting = false;
        _deviceId = stream.getVideoTracks().toDart.first.getSettings().deviceId;
      });
      // Device labels become available after permission. Enumeration failure
      // does not prevent an otherwise working video preview.
      try {
        final devices =
            await web.window.navigator.mediaDevices.enumerateDevices().toDart;
        if (!mounted || request != _request) return;
        setState(() => _devices = devices.toDart
            .where((device) => device.kind == 'videoinput')
            .toList());
      } catch (_) {
        // Keep the current stream when the optional selector is unavailable.
      }
    } catch (_) {
      if (mounted && request == _request) _stop(unavailable: true);
    }
  }

  Future<void> _attachVideo(
      Object element, web.MediaStream stream, int request) async {
    if (!mounted || request != _request) return;
    final video = element as web.HTMLVideoElement;
    _video = video;
    video
      ..id = 'robot-camera-preview'
      ..autoplay = true
      ..muted = true
      ..playsInline = true
      ..srcObject = stream;
    video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain'
      ..pointerEvents = 'none';
    try {
      await video.play().toDart;
    } catch (_) {
      if (mounted && request == _request) _stop(unavailable: true);
    }
  }

  @override
  void dispose() {
    ++_request;
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final stream = _stream;
    final request = _request;
    final selected = _devices.any((device) => device.deviceId == _deviceId)
        ? _deviceId
        : null;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('카메라', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Wrap(spacing: 12, runSpacing: 8, children: [
              OutlinedButton(
                onPressed: () {
                  if (_starting || stream != null) {
                    _stop();
                  } else {
                    _start();
                  }
                },
                child: Text(_starting || stream != null ? '카메라 정지' : '카메라 시작'),
              ),
              if (_devices.length > 1)
                SizedBox(
                  width: 240,
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: selected,
                    hint: const Text('카메라 선택'),
                    onChanged: _starting
                        ? null
                        : (id) {
                            if (id == null) return;
                            if (_stream != null) {
                              _start(id);
                            } else {
                              setState(() => _deviceId = id);
                            }
                          },
                    items: [
                      for (var i = 0; i < _devices.length; i++)
                        DropdownMenuItem(
                          value: _devices[i].deviceId,
                          child: Text(
                            _devices[i].label.isEmpty
                                ? '카메라 ${i + 1}'
                                : _devices[i].label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
            ]),
            if (_unavailable) ...[
              const SizedBox(height: 8),
              const Text('카메라를 사용할 수 없습니다.'),
            ],
            if (stream != null) ...[
              const SizedBox(height: 12),
              Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: DashboardTheme.background,
                  border: Border.all(color: DashboardTheme.border),
                  borderRadius: BorderRadius.circular(DashboardTheme.radius),
                ),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: HtmlElementView.fromTagName(
                    key: ValueKey(request),
                    tagName: 'video',
                    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
                    onElementCreated: (element) =>
                        _attachVideo(element, stream, request),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
