import Flutter
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
    window?.rootViewController = NativeTabHostController(flutter: flutter)
  }
}

/// UIKit owns the tab control while one FlutterViewController owns all pages.
private final class NativeTabHostController: UIViewController, UITabBarDelegate {
  private let flutter: FlutterViewController
  private let tabBar = UITabBar()
  private var channel: FlutterMethodChannel!
  private var flutterBottomToBar: NSLayoutConstraint!
  private var flutterBottomToView: NSLayoutConstraint!
  private var tabHeight: NSLayoutConstraint!
  private var wantsTabs = false
  private var detailOpen = false
  private var keyboardCoversBottom = false

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
    tabBar.items = [
      UITabBarItem(title: "今日", image: UIImage(systemName: "house"), tag: 0),
      UITabBarItem(title: "课程表", image: UIImage(systemName: "calendar"), tag: 1),
      UITabBarItem(title: "分析", image: UIImage(systemName: "chart.bar"), tag: 2),
      UITabBarItem(title: "设置", image: UIImage(systemName: "gearshape"), tag: 3),
    ]
    tabBar.selectedItem = tabBar.items?.first
    tabBar.isHidden = true
    view.addSubview(tabBar)

    flutterBottomToBar = flutter.view.bottomAnchor.constraint(equalTo: tabBar.topAnchor)
    flutterBottomToView = flutter.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
    tabHeight = tabBar.heightAnchor.constraint(equalToConstant: 49)
    NSLayoutConstraint.activate([
      flutter.view.topAnchor.constraint(equalTo: view.topAnchor),
      flutter.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      flutter.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      flutterBottomToView,
      tabBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      tabBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      tabBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      tabHeight,
    ])

    channel = FlutterMethodChannel(name: "hand_helper/native_tab", binaryMessenger: flutter.binaryMessenger)
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
        self.tabBar.selectedItem = self.tabBar.items?[index]
        if let dark = state["dark"] as? Bool {
          self.tabBar.overrideUserInterfaceStyle = dark ? .dark : .light
        }
        self.updateVisibility()
        result(nil)
      case "setAvatar":
        self.setAvatar(call.arguments as? String)
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
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    let fitted = tabBar.sizeThatFits(CGSize(width: view.bounds.width, height: 0)).height
    let height = max(fitted, 49 + view.safeAreaInsets.bottom)
    if abs(tabHeight.constant - height) > 0.5 { tabHeight.constant = height }
  }

  private func updateVisibility() {
    let show = wantsTabs && !detailOpen && !keyboardCoversBottom
    if show == !tabBar.isHidden { return }
    flutterBottomToView.isActive = !show
    flutterBottomToBar.isActive = show
    tabBar.isHidden = !show
    tabBar.isUserInteractionEnabled = show
    view.setNeedsLayout()
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
    channel.invokeMethod("selectTab", arguments: item.tag)
  }

  private func setAvatar(_ dataURL: String?) {
    guard let item = tabBar.items?.first else { return }
    guard let dataURL,
          let encoded = dataURL.split(separator: ",", maxSplits: 1).last,
          let data = Data(base64Encoded: String(encoded)),
          let image = UIImage(data: data) else {
      item.image = UIImage(systemName: "house")
      item.selectedImage = nil
      return
    }
    let size = CGSize(width: 24, height: 24)
    let avatar = UIGraphicsImageRenderer(size: size).image { _ in
      UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).addClip()
      let scale = max(size.width / image.size.width, size.height / image.size.height)
      let drawn = CGSize(width: image.size.width * scale, height: image.size.height * scale)
      image.draw(in: CGRect(x: (size.width - drawn.width) / 2,
                            y: (size.height - drawn.height) / 2,
                            width: drawn.width, height: drawn.height))
    }.withRenderingMode(.alwaysOriginal)
    item.image = avatar
    item.selectedImage = avatar
  }
}
