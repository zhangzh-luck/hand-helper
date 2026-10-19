import 'package:flutter/material.dart';

/// Reversible first-frame bridge for the Android system splash preview.
/// The native splash remains visible until Flutter renders this matching icon;
/// the overlay then fades as soon as local routing is known, without waiting
/// for a network request or imposing an artificial startup delay.
class LaunchPreview extends StatefulWidget {
  const LaunchPreview({super.key, required this.childBuilder});

  final Widget Function(VoidCallback onLocalRouteReady) childBuilder;

  @override
  State<LaunchPreview> createState() => _LaunchPreviewState();
}

class _LaunchPreviewState extends State<LaunchPreview> {
  bool _firstFrameRendered = false;
  bool _localRouteReady = false;
  bool _fading = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _firstFrameRendered = true;
      _beginIfReady();
    });
  }

  void _onLocalRouteReady() {
    if (_localRouteReady) return;
    _localRouteReady = true;
    _beginIfReady();
  }

  void _beginIfReady() {
    if (!_firstFrameRendered || !_localRouteReady || _fading || !mounted) {
      return;
    }
    setState(() => _fading = true);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Stack(
      children: [
        widget.childBuilder(_onLocalRouteReady),
        if (!_finished)
          Positioned.fill(
            child: AbsorbPointer(
              child: AnimatedOpacity(
                opacity: _fading ? 0 : 1,
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOut,
                onEnd: () {
                  if (_fading && mounted) setState(() => _finished = true);
                },
                child: ColoredBox(
                  color: dark ? Colors.black : Colors.white,
                  child: Center(
                    child: ExcludeSemantics(
                      child: AnimatedScale(
                        scale: _fading ? 1.06 : 1,
                        duration: const Duration(milliseconds: 350),
                        curve: Curves.easeOutCubic,
                        child: Image.asset(
                          'assets/icon/splash_mark.png',
                          width: 100,
                          height: 100,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
