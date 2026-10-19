import 'package:flutter/material.dart';

/// Paints a closed surface as it expands into a detail surface.
///
/// The parent owns the animation controller, source measurement, navigation,
/// and interaction state. This widget only draws the current transition frame.
class ContainerMorphTransition extends StatelessWidget {
  const ContainerMorphTransition({
    super.key,
    required this.progress,
    required this.isClosing,
    required this.detailInteractive,
    required this.startRect,
    required this.endSize,
    this.endRect,
    required this.startBorderRadius,
    this.endBorderRadius = BorderRadius.zero,
    this.detailSafeArea = true,
    required this.closedColor,
    required this.openColor,
    required this.sourceContent,
    required this.detailHeader,
    required this.detailBody,
    this.surfaceContentBuilder,
    this.surfaceKey,
    this.sourceLayerKey,
    this.detailHeaderLayerKey,
    this.detailBodyLayerKey,
    this.courseDetailTextHandoff = false,
  });

  static const duration = Duration(milliseconds: 300);

  final double progress;
  final bool isClosing;
  final bool detailInteractive;
  final Rect startRect;
  final Size endSize;

  /// Defaults to the full-size surface at the parent's origin.
  final Rect? endRect;
  final BorderRadius startBorderRadius;
  final BorderRadius endBorderRadius;
  final bool detailSafeArea;
  final Color closedColor;
  final Color openColor;
  final Widget sourceContent;
  final Widget detailHeader;
  final Widget detailBody;

  /// Optional single, continuously laid-out surface content. The existing
  /// source/header/body transition is unchanged when this is omitted.
  final Widget Function(BuildContext context, double curvedProgress)?
  surfaceContentBuilder;
  final Key? surfaceKey;
  final Key? sourceLayerKey;
  final Key? detailHeaderLayerKey;
  final Key? detailBodyLayerKey;

  /// Timetable-only text timing. Other morphs retain their existing phases.
  final bool courseDetailTextHandoff;

  double _phase(double value, double begin, double end) =>
      ((value - begin) / (end - begin)).clamp(0.0, 1.0);

  @override
  Widget build(BuildContext context) {
    final end = endRect ?? (Offset.zero & endSize);
    final curve = isClosing
        ? Curves.fastOutSlowIn.flipped
        : Curves.fastOutSlowIn;
    final curved = curve.transform(progress);
    final rect = Rect.lerp(startRect, end, curved)!;
    final radius = BorderRadius.lerp(
      startBorderRadius,
      endBorderRadius,
      curved,
    )!;
    final headerOpacity = courseDetailTextHandoff
        ? _phase(progress, .26, .41)
        : isClosing
        ? _phase(progress, .32, .64)
        : _phase(progress, .28, .44);
    final bodyOpacity = courseDetailTextHandoff
        ? _phase(progress, .30, .45)
        : isClosing
        ? _phase(progress, .36, .68)
        : _phase(progress, .34, .50);
    final tileOpacity =
        1 -
        (courseDetailTextHandoff
            ? _phase(progress, .18, .34)
            : isClosing
            ? _phase(progress, .20, .35)
            : _phase(progress, .16, .31));
    final bodyOffset = 14 * (1 - bodyOpacity);

    return Positioned.fromRect(
      rect: rect,
      child: RepaintBoundary(
        key: surfaceKey,
        child: ClipRRect(
          borderRadius: radius,
          child: Material(
            color: Color.lerp(
              closedColor,
              openColor,
              _phase(progress, .16, .44),
            ),
            child: surfaceContentBuilder != null
                ? surfaceContentBuilder!(context, curved)
                : Stack(
                    children: [
                      Opacity(
                        key: sourceLayerKey,
                        opacity: tileOpacity,
                        child: SizedBox(
                          width: startRect.width,
                          height: startRect.height,
                          child: sourceContent,
                        ),
                      ),
                      Positioned(
                        left: 0,
                        top: 0,
                        width: endSize.width,
                        height: endSize.height,
                        child: IgnorePointer(
                          ignoring: !detailInteractive,
                          child: ExcludeFocus(
                            excluding: !detailInteractive,
                            child: ExcludeSemantics(
                              excluding: !detailInteractive,
                              child: Builder(
                                builder: (context) {
                                  final content = Column(
                                    children: [
                                      Opacity(
                                        key: detailHeaderLayerKey,
                                        opacity: headerOpacity,
                                        child: detailHeader,
                                      ),
                                      Expanded(
                                        child: Opacity(
                                          key: detailBodyLayerKey,
                                          opacity: bodyOpacity,
                                          child: Transform.translate(
                                            offset: Offset(0, bodyOffset),
                                            child: detailBody,
                                          ),
                                        ),
                                      ),
                                    ],
                                  );
                                  return detailSafeArea
                                      ? SafeArea(bottom: false, child: content)
                                      : content;
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
