import Flutter
import ImageIO
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    // The storyboard creates one implicit-engine FlutterViewController. Retain it
    // for the lifetime of the scene and move it into this container only once.
    guard let flutter = window?.rootViewController as? FlutterViewController else {
      assertionFailure("Expected the storyboard FlutterViewController")
      return
    }
    window?.backgroundColor = .systemBackground
    window?.rootViewController = NativeTabHostController(flutter: flutter)
  }

  override func sceneDidDisconnect(_ scene: UIScene) {
    (window?.rootViewController as? NativeTabHostController)?.invalidateNativePickers()
    super.sceneDidDisconnect(scene)
  }
}

/// UIKit owns the tab control while one FlutterViewController owns all pages.
private final class NativeTabHostController: UIViewController, UITabBarDelegate {
  private let flutter: FlutterViewController
  private let tabBar = UITabBar()
  private var channel: FlutterMethodChannel!
  private var timeChannel: FlutterMethodChannel!
  private var timePickerPresenter: NativeTimePickerPresenter!
  private var dateChannel: FlutterMethodChannel!
  private var datePickerPresenter: NativeDatePickerPresenter!
  private var tabHeight: NSLayoutConstraint!
  private var wantsTabs = false
  private var detailOpen = false
  private var keyboardCoversBottom = false
  private var tabsShown = false
  private var bottomOcclusion: CGFloat = -1
  private var selectedIndex = 0
  private var appearanceMode: String?
  private let homeSymbol = UIImage(systemName: "house")
  private var avatarRequestID = 0

  init(flutter: FlutterViewController) {
    self.flutter = flutter
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("Use init(flutter:)") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    addChild(flutter)
    flutter.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(flutter.view)
    flutter.didMove(toParent: self)

    tabBar.translatesAutoresizingMaskIntoConstraints = false
    tabBar.delegate = self
    // UIKit explicitly supports a nil title for an image-only item. Keep the
    // spoken names separate so they never occupy visual layout space.
    let tabs: [(symbol: String, name: String)] = [
      ("house", "今日"), ("calendar", "课程表"),
      ("chart.bar", "分析"), ("gearshape", "设置"),
    ]
    tabBar.items = tabs.enumerated().map { index, tab in
      let item = UITabBarItem(title: nil, image: UIImage(systemName: tab.symbol), tag: index)
      item.accessibilityLabel = tab.name
      return item
    }
    tabBar.selectedItem = tabBar.items?.first
    tabBar.isHidden = true
    tabBar.alpha = 0
    view.addSubview(tabBar)

    // Let UIKit measure its own bar; Flutter always renders to the window's
    // bottom edge, including behind the translucent bar and home indicator.
    let initialHeight = tabBar.sizeThatFits(
      CGSize(width: view.bounds.width, height: 0)
    ).height
    tabHeight = tabBar.heightAnchor.constraint(equalToConstant: initialHeight)
    NSLayoutConstraint.activate([
      flutter.view.topAnchor.constraint(equalTo: view.topAnchor),
      flutter.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      flutter.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      flutter.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tabHeight,
    ])

    channel = FlutterMethodChannel(name: "hand_helper/native_tab", binaryMessenger: flutter.binaryMessenger)
    timePickerPresenter = NativeTimePickerPresenter(host: self)
    timeChannel = FlutterMethodChannel(
      name: "hand_helper/native_period_time", binaryMessenger: flutter.binaryMessenger
    )
    timeChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "scene_closed", message: nil, details: nil))
        return
      }
      self.timePickerPresenter.handle(call, result: result)
    }
    datePickerPresenter = NativeDatePickerPresenter(host: self)
    dateChannel = FlutterMethodChannel(
      name: "hand_helper/native_term_start_date", binaryMessenger: flutter.binaryMessenger
    )
    dateChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "scene_closed", message: nil, details: nil))
        return
      }
      self.datePickerPresenter.handle(call, result: result)
    }
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterError(code: "scene_closed", message: nil, details: nil))
        return
      }
      switch call.method {
      case "sync":
        guard let state = call.arguments as? [String: Any],
              let visible = state["visible"] as? Bool,
              let index = state["selected"] as? Int,
              let detail = state["detailOpen"] as? Bool,
              (0..<4).contains(index) else {
          result(FlutterError(code: "invalid_tab_state", message: nil, details: nil))
          return
        }
        self.wantsTabs = visible
        self.detailOpen = detail
        if index != self.selectedIndex {
          self.selectedIndex = index
          self.tabBar.selectedItem = self.tabBar.items?[index]
        }
        if let appearance = state["appearance"] as? String,
           appearance != self.appearanceMode {
          self.applyAppearance(appearance)
        }
        self.updateVisibility()
        result(nil)
      case "getMetrics":
        result(self.bottomOcclusion >= 0 ? Double(self.bottomOcclusion) : 0.0)
      case "setAppearance":
        guard let appearance = call.arguments as? String else {
          result(FlutterError(code: "invalid_appearance", message: nil, details: nil))
          return
        }
        if appearance != self.appearanceMode { self.applyAppearance(appearance) }
        result(nil)
      case "setAvatar":
        self.avatarRequestID += 1
        let requestID = self.avatarRequestID
        // Drop the previous user's image before asynchronous decoding starts.
        self.applyHomeAvatar(nil)
        guard let typedData = call.arguments as? FlutterStandardTypedData,
              typedData.data.count <= 256_000 else {
          result(nil)
          return
        }
        let data = typedData.data
        DispatchQueue.global(qos: .userInitiated).async {
          let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
          let decoded = CGImageSourceCreateWithData(data as CFData, options)
            .flatMap { CGImageSourceCreateImageAtIndex($0, 0, options) }
          DispatchQueue.main.async { [weak self] in
            guard let self, self.avatarRequestID == requestID,
                  let decoded else { return }
            // Use the 24-point avatar canvas from the original native tab.
            // A symbol's intrinsic image height is smaller than the size
            // UIKit may render it at inside the tab bar.
            let diameter: CGFloat = 24
            // Restore the circular UIKit rendering used by the first native
            // tab implementation. The transparent renderer also protects the
            // shape if an avatar arrives without an alpha channel.
            let size = CGSize(width: diameter, height: diameter)
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            format.scale = CGFloat(decoded.height) / diameter
            let source = UIImage(cgImage: decoded)
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
              UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
              let scale = max(size.width / source.size.width,
                              size.height / source.size.height)
              let drawn = CGSize(width: source.size.width * scale,
                                 height: source.size.height * scale)
              source.draw(in: CGRect(x: (size.width - drawn.width) / 2,
                                   y: (size.height - drawn.height) / 2,
                                   width: drawn.width, height: drawn.height))
            }.withRenderingMode(.alwaysOriginal)
            self.applyHomeAvatar(image)
          }
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
      name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
      name: UIResponder.keyboardWillHideNotification, object: nil)
    channel.invokeMethod("requestState", arguments: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
    channel?.setMethodCallHandler(nil)
    timeChannel?.setMethodCallHandler(nil)
    timePickerPresenter?.invalidate()
    dateChannel?.setMethodCallHandler(nil)
    datePickerPresenter?.invalidate()
  }

  func invalidateNativePickers() {
    timePickerPresenter?.invalidate()
    datePickerPresenter?.invalidate()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let measured = tabBar.sizeThatFits(
      CGSize(width: view.bounds.width, height: 0)
    ).height
    if measured > 0 && abs(tabHeight.constant - measured) > 0.5 {
      tabHeight.constant = measured
      return // Report the resulting frame after Auto Layout places the bar.
    }
    let occlusion = max(0, view.bounds.maxY - tabBar.frame.minY)
    if abs(bottomOcclusion - occlusion) > 0.5 {
      bottomOcclusion = occlusion
      channel.invokeMethod("tabMetrics", arguments: Double(occlusion))
    }
  }

  private func updateVisibility() {
    let show = wantsTabs && !detailOpen && !keyboardCoversBottom
    if show == tabsShown { return }
    tabsShown = show
    tabBar.isUserInteractionEnabled = show
    if show { tabBar.isHidden = false }
    let duration = UIAccessibility.isReduceMotionEnabled ? 0 : 0.2
    UIView.animate(withDuration: duration, delay: 0,
      options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.tabBar.alpha = show ? 1 : 0
      } completion: { _ in
        if !self.tabsShown { self.tabBar.isHidden = true }
      }
  }

  private func applyAppearance(_ mode: String) {
    appearanceMode = mode
    let style: UIUserInterfaceStyle
    switch mode {
    case "light": style = .light
    case "dark": style = .dark
    default: style = .unspecified
    }
    // Keep UIKit's dynamic material and the window's home-indicator region in
    // the same appearance as Flutter's user-selected ThemeMode.
    overrideUserInterfaceStyle = style
    view.window?.overrideUserInterfaceStyle = style
  }

  private func applyHomeAvatar(_ avatar: UIImage?) {
    guard let item = tabBar.items?.first else { return }
    item.image = avatar ?? homeSymbol
    item.selectedImage = avatar
  }

  @objc private func keyboardChanged(_ notification: Notification) {
    guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
          let window = view.window else { return }
    let windowFrame = window.convert(endFrame, from: window.screen.coordinateSpace)
    let frame = view.convert(windowFrame, from: window)
    let overlap = view.bounds.intersection(frame)
    // A small floating iPad keyboard does not cover the bottom tab bar.
    keyboardCoversBottom = !overlap.isNull && overlap.width > view.bounds.width / 2 &&
      overlap.maxY >= view.bounds.maxY - 1 && overlap.height > 0
    updateVisibility()
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard wantsTabs && !detailOpen && !keyboardCoversBottom else { return }
    selectedIndex = item.tag
    channel.invokeMethod("selectTab", arguments: item.tag)
  }

}
