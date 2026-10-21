import Flutter
import UIKit

/// A system segmented control. Flutter owns and persists the selected ThemeMode.
final class AppearanceModePlatformViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    let initialIndex = (args as? [String: Any])?["selectedIndex"] as? Int ?? 2
    return AppearanceModePlatformView(
      frame: frame,
      viewId: viewId,
      initialIndex: initialIndex,
      messenger: messenger
    )
  }
}

private final class AppearanceModePlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let control: UISegmentedControl
  private let channel: FlutterMethodChannel
  private var lastEmittedIndex: Int

  init(frame: CGRect, viewId: Int64, initialIndex: Int, messenger: FlutterBinaryMessenger) {
    let segments: [(symbol: String, label: String)] = [
      ("sun.max", "浅色模式"),
      ("moon", "深色模式"),
      ("iphone", "跟随系统"),
    ]
    let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)
    let actions = segments.map { segment in
      let image = UIImage(systemName: segment.symbol, withConfiguration: symbolConfiguration) ?? UIImage()
      // Images take visual priority; both public labels describe each segment.
      image.accessibilityLabel = segment.label
      return UIAction(title: segment.label, image: image) { _ in }
    }
    let safeIndex = (0..<segments.count).contains(initialIndex) ? initialIndex : 2
    container = UIView(frame: frame)
    control = UISegmentedControl(frame: .zero, actions: actions)
    channel = FlutterMethodChannel(
      name: "hand_helper/appearance_mode/\(viewId)",
      binaryMessenger: messenger
    )
    lastEmittedIndex = safeIndex
    super.init()

    // The Flutter settings card is translucent, but a transparent UIKit
    // platform-view root can expose the compositor's dark backing beneath a
    // Flutter modal barrier. Match the card's resolved color instead of
    // painting an independent dark rectangle behind the system control.
    container.backgroundColor = UIColor { trait in
      if trait.userInterfaceStyle == .dark {
        // 0xe5222630 composited over black, preserving Flutter's fractional
        // Color.alphaBlend components instead of rounding to 8-bit RGB.
        let cardAlpha: CGFloat = 229.0 / 255.0
        return UIColor(red: (34.0 / 255.0) * cardAlpha,
                       green: (38.0 / 255.0) * cardAlpha,
                       blue: (48.0 / 255.0) * cardAlpha, alpha: 1)
      }
      // 0xf5ffffff over the settings page's 0xfff4f7fb background.
      let cardAlpha: CGFloat = 245.0 / 255.0
      let pageWeight = 1.0 - cardAlpha
      return UIColor(red: cardAlpha + (244.0 / 255.0) * pageWeight,
                     green: cardAlpha + (247.0 / 255.0) * pageWeight,
                     blue: cardAlpha + (251.0 / 255.0) * pageWeight, alpha: 1)
    }
    container.isOpaque = true
    control.accessibilityIdentifier = "appearance-mode-control"
    control.selectedSegmentIndex = safeIndex
    control.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(control)
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      control.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      control.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      control.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
      control.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor),
      control.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
    ])
    control.addTarget(self, action: #selector(selectionChanged), for: .valueChanged)

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "view_closed", message: nil, details: nil))
        return
      }
      guard call.method == "setSelected", let index = call.arguments as? Int,
            (0..<self.control.numberOfSegments).contains(index) else {
        result(FlutterMethodNotImplemented)
        return
      }
      if self.control.selectedSegmentIndex != index {
        self.control.selectedSegmentIndex = index
      }
      self.lastEmittedIndex = index
      result(nil)
    }
  }

  func view() -> UIView { container }

  @objc private func selectionChanged() {
    let index = control.selectedSegmentIndex
    guard index != lastEmittedIndex else { return }
    lastEmittedIndex = index
    channel.invokeMethod("selectionChanged", arguments: index)
  }
}
