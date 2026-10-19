import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

const _labels = ['今日', '课程表', '分析', '设置'];
const _outlineIcons = [
  CupertinoIcons.house,
  Icons.calendar_month_outlined,
  Icons.school_outlined,
  Icons.settings_outlined,
];
const _filledIcons = [
  CupertinoIcons.house_fill,
  Icons.calendar_month,
  Icons.school,
  Icons.settings,
];

/// The dock owns its pointer and animation state so a drag never rebuilds the
/// page shell underneath it.
class FloatingTabBar extends StatefulWidget {
  const FloatingTabBar({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
    this.avatar,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final ImageProvider? avatar;

  @override
  State<FloatingTabBar> createState() => _FloatingTabBarState();
}

class _FloatingTabBarState extends State<FloatingTabBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController lens = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );
  int? pointer;
  int? hoveredIndex;
  Offset? pressStart;
  VelocityTracker? velocityTracker;
  bool dragging = false;
  int? lensTarget;

  @override
  void didUpdateWidget(covariant FloatingTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex && pointer == null) {
      settle(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    lens.dispose();
    super.dispose();
  }

  int indexAt(double dx, double width) =>
      (dx / (width / _labels.length)).floor().clamp(0, _labels.length - 1);

  double positionAt(double dx, double width) =>
      (dx / (width / _labels.length) - .5).clamp(
        0.0,
        (_labels.length - 1).toDouble(),
      );

  void settle(int index, {double velocity = 0}) {
    if (lensTarget == index && lens.isAnimating) return;
    if (!lens.isAnimating && (lens.value - index).abs() < .001) return;
    lensTarget = index;
    lens.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 285, damping: 25),
        lens.value,
        index.toDouble(),
        velocity,
      ),
    );
  }

  void pointerDown(PointerDownEvent event, double width) {
    if (pointer != null || event.buttons & kPrimaryButton == 0) return;
    pointer = event.pointer;
    pressStart = event.localPosition;
    velocityTracker = VelocityTracker.withKind(event.kind)
      ..addPosition(event.timeStamp, event.localPosition);
    dragging = false;
    setState(() => hoveredIndex = widget.selectedIndex);
  }

  void pointerMove(PointerMoveEvent event, double width) {
    if (event.pointer != pointer) return;
    velocityTracker?.addPosition(event.timeStamp, event.localPosition);
    final start = pressStart;
    if (start == null) return;
    if (!dragging) {
      if ((event.localPosition.dx - start.dx).abs() < kTouchSlop) return;
      dragging = true;
    }
    lensTarget = null;
    lens.value = positionAt(event.localPosition.dx, width);
    final next = indexAt(event.localPosition.dx, width);
    if (next != hoveredIndex) {
      HapticFeedback.selectionClick();
      setState(() => hoveredIndex = next);
    }
  }

  void pointerEnd(PointerEvent event, double width) {
    if (event.pointer != pointer) return;
    final speed = velocityTracker?.getVelocity().pixelsPerSecond.dx ?? 0;
    final previous = dragging
        ? hoveredIndex ?? widget.selectedIndex
        : indexAt(event.localPosition.dx, width);
    final commit = event is PointerUpEvent;
    pointer = null;
    pressStart = null;
    velocityTracker = null;
    var next = previous;
    if (commit && dragging && speed.abs() > 400) {
      final projected = (lens.value + speed / (width / _labels.length) * .1)
          .round();
      next = projected
          .clamp(previous - 1, previous + 1)
          .clamp(0, _labels.length - 1);
    }
    if (commit && next != previous ||
        commit && !dragging && next != widget.selectedIndex) {
      HapticFeedback.selectionClick();
    }
    setState(() {
      hoveredIndex = null;
      dragging = false;
    });
    settle(commit ? next : widget.selectedIndex);
    if (commit && next != widget.selectedIndex) widget.onSelected(next);
  }

  void selectTab(int index) {
    if (index == widget.selectedIndex) return;
    HapticFeedback.selectionClick();
    settle(index);
    widget.onSelected(index);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = dark
        ? const Color(0xff69adff)
        : const Color(0xff1768ff);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 296),
            child: RepaintBoundary(
              child: Container(
                key: const Key('tab-bar-surface'),
                height: 56,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xb31c1c1e)
                      : const Color(0xbbeef2f7),
                  borderRadius: BorderRadius.circular(23),
                  border: Border.all(
                    color: dark
                        ? const Color(0x20ffffff)
                        : const Color(0xaaffffff),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x240f172a),
                      blurRadius: 22,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: LayoutBuilder(
                      builder: (context, box) {
                        final width = box.maxWidth;
                        final itemWidth = width / _labels.length;
                        return Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerDown: (event) => pointerDown(event, width),
                          onPointerMove: (event) => pointerMove(event, width),
                          onPointerUp: (event) => pointerEnd(event, width),
                          onPointerCancel: (event) => pointerEnd(event, width),
                          child: Stack(
                            children: [
                              AnimatedBuilder(
                                animation: lens,
                                builder: (context, child) => Positioned(
                                  left: lens.value * itemWidth,
                                  top: 0,
                                  bottom: 0,
                                  width: itemWidth,
                                  child: child!,
                                ),
                                child: AnimatedScale(
                                  scale: pointer == null ? 1 : 1.06,
                                  duration: const Duration(milliseconds: 180),
                                  curve: Curves.easeOutCubic,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: dark
                                            ? [
                                                const Color(0x33ffffff),
                                                const Color(0x161d2330),
                                              ]
                                            : [
                                                const Color(0xf2ffffff),
                                                const Color(0xc8ffffff),
                                              ],
                                      ),
                                      border: Border.all(
                                        color: dark
                                            ? const Color(0x1affffff)
                                            : const Color(0x8affffff),
                                      ),
                                      borderRadius: BorderRadius.circular(17),
                                      boxShadow: const [
                                        BoxShadow(
                                          color: Color(0x150f172a),
                                          blurRadius: 8,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  for (
                                    var index = 0;
                                    index < _labels.length;
                                    index++
                                  )
                                    Expanded(
                                      child: Semantics(
                                        key: Key('tab-$index'),
                                        button: true,
                                        selected: widget.selectedIndex == index,
                                        label: _labels[index],
                                        onTap: () => selectTab(index),
                                        child: ExcludeSemantics(
                                          child: _TabContent(
                                            index: index,
                                            active: pointer == null
                                                ? widget.selectedIndex == index
                                                : hoveredIndex == index,
                                            activeColor: activeColor,
                                            avatar: widget.avatar,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TabContent extends StatelessWidget {
  const _TabContent({
    required this.index,
    required this.active,
    required this.activeColor,
    required this.avatar,
  });

  final int index;
  final bool active;
  final Color activeColor;
  final ImageProvider? avatar;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final icon = index == 0 && avatar != null
        ? AnimatedScale(
            scale: active ? 1.12 : 1,
            duration: const Duration(milliseconds: 240),
            child: Container(
              width: 24,
              height: 24,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: active ? activeColor : const Color(0xff94a3b8),
                ),
              ),
              child: Image(image: avatar!, fit: BoxFit.cover),
            ),
          )
        : AnimatedSwitcher(
            duration: const Duration(milliseconds: 240),
            transitionBuilder: (child, animation) => FadeTransition(
              opacity: animation,
              child: ScaleTransition(
                scale: Tween(begin: .86, end: 1.0).animate(animation),
                child: child,
              ),
            ),
            child: Icon(
              active ? _filledIcons[index] : _outlineIcons[index],
              key: ValueKey(active),
              size: 24,
              color: active ? activeColor : muted,
            ),
          );
    return Center(child: icon);
  }
}
