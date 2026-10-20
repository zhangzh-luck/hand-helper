import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'native_appearance_mode_selector.dart';

/// A tap-only counterpart to the floating tab bar's glass selection surface.
class AppearanceModeSelector extends StatelessWidget {
  const AppearanceModeSelector({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final ThemeMode selected;
  final ValueChanged<ThemeMode> onSelected;

  static const _modes = [ThemeMode.light, ThemeMode.dark, ThemeMode.system];
  static const _labels = ['浅色', '深色', '系统'];
  static const _icons = [
    Icons.light_mode_outlined,
    Icons.dark_mode_outlined,
    Icons.phone_android_outlined,
  ];

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return NativeAppearanceModeSelector(
        selected: selected,
        onSelected: onSelected,
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    final activeColor = dark
        ? const Color(0xff69adff)
        : const Color(0xff1768ff);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final selectedIndex = _modes.indexOf(selected);

    return SizedBox(
      width: double.infinity,
      child: RepaintBoundary(
          child: Container(
            key: const Key('appearance-mode-surface'),
            height: 56,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: dark ? const Color(0xb31c1c1e) : const Color(0xbbeef2f7),
              borderRadius: BorderRadius.circular(23),
              border: Border.all(
                color: dark ? const Color(0x20ffffff) : const Color(0xaaffffff),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final itemWidth = box.maxWidth / _modes.length;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 170),
                          curve: Curves.easeOutCubic,
                          left: selectedIndex * itemWidth,
                          top: 0,
                          bottom: 0,
                          width: itemWidth,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: dark
                                    ? const [
                                        Color(0x33ffffff),
                                        Color(0x161d2330),
                                      ]
                                    : const [
                                        Color(0xf2ffffff),
                                        Color(0xc8ffffff),
                                      ],
                              ),
                              border: Border.all(
                                color: dark
                                    ? const Color(0x1affffff)
                                    : const Color(0x8affffff),
                              ),
                              borderRadius: BorderRadius.circular(17),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            for (var index = 0; index < _modes.length; index++)
                              Expanded(
                                child: Semantics(
                                  key: Key('appearance-mode-$index'),
                                  button: true,
                                  selected: selectedIndex == index,
                                  label: '${_labels[index]}模式',
                                  onTap: () {
                                    if (selected != _modes[index]) {
                                      onSelected(_modes[index]);
                                    }
                                  },
                                  child: ExcludeSemantics(
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTap: () {
                                        if (selected != _modes[index]) {
                                          onSelected(_modes[index]);
                                        }
                                      },
                                      child: Center(
                                        child: FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                _icons[index],
                                                size: 18,
                                                color: selectedIndex == index
                                                    ? activeColor
                                                    : muted,
                                              ),
                                              const SizedBox(width: 5),
                                              Text(
                                                _labels[index],
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: FontWeight.w600,
                                                  color: selectedIndex == index
                                                      ? activeColor
                                                      : muted,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
      ),
    );
  }
}
