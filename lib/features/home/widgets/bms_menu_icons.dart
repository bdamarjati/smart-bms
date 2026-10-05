import 'dart:math' as math;

import 'package:flutter/material.dart';

class AddDeviceIcon extends StatelessWidget {
  const AddDeviceIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    return SizedBox.square(
      dimension: iconTheme.size,
      child: CustomPaint(
        painter: _AddDevicePainter(iconTheme.color ?? Colors.white),
      ),
    );
  }
}

class BatteryIcon extends StatelessWidget {
  const BatteryIcon({super.key});

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    final width = iconTheme.size ?? 24;
    return SizedBox(
      width: width,
      height: width * 0.68,
      child: CustomPaint(
        painter: _BatteryPainter(iconTheme.color ?? Colors.white),
      ),
    );
  }
}

class _AddDevicePainter extends CustomPainter {
  const _AddDevicePainter(this.color);

  static const _dashCount = 12;
  static const _dashSweep = 0.34;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide * 0.44;
    final plusRadius = size.shortestSide * 0.17;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;

    for (var index = 0; index < _dashCount; index++) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        index * (2 * math.pi / _dashCount),
        _dashSweep,
        false,
        paint,
      );
    }

    canvas
      ..drawLine(
        center.translate(-plusRadius, 0),
        center.translate(plusRadius, 0),
        paint,
      )
      ..drawLine(
        center.translate(0, -plusRadius),
        center.translate(0, plusRadius),
        paint,
      );
  }

  @override
  bool shouldRepaint(covariant _AddDevicePainter oldDelegate) =>
      oldDelegate.color != color;
}

class _BatteryPainter extends CustomPainter {
  const _BatteryPainter(this.color);

  static const _segmentCount = 3;

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 41;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    final gap = 2.5 * unit;

    final body = RRect.fromRectAndRadius(
      Rect.fromLTWH(1, 2 * unit, size.width - 6 * unit, size.height - 4 * unit),
      Radius.circular(2 * unit),
    );
    final terminalHeight = size.height * 0.36;
    canvas
      ..drawRRect(body, stroke)
      ..drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.width - 4.5 * unit,
            (size.height - terminalHeight) / 2,
            3.5 * unit,
            terminalHeight,
          ),
          Radius.circular(unit),
        ),
        fill,
      );

    final inset = 5 * unit;
    final segmentWidth =
        (body.width - 2 * inset - gap * (_segmentCount - 1)) / _segmentCount;
    for (var index = 0; index < _segmentCount; index++) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            body.left + inset + index * (segmentWidth + gap),
            body.top + inset,
            segmentWidth,
            body.height - 2 * inset,
          ),
          Radius.circular(unit),
        ),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BatteryPainter oldDelegate) =>
      oldDelegate.color != color;
}
