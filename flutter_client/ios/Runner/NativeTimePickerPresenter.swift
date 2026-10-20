import Flutter
import UIKit

/// Presents a system time picker from the current scene's host controller.
final class NativeTimePickerPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
  private weak var host: UIViewController?
  private var presented: UINavigationController?
  private var pendingResult: FlutterResult?
  private var pendingRequestID: Int?

  init(host: UIViewController) {
    self.host = host
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // Flutter's channel uses the platform thread, and UIKit must stay on main.
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(code: "scene_closed", message: nil, details: nil))
        return
      }
      switch call.method {
      case "pickTime": self.pick(call.arguments, result: result)
      case "dismissTimePicker": self.dismiss(call.arguments, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  func invalidate() {
    if Thread.isMainThread {
      let navigation = presented
      finish(nil)
      navigation?.dismiss(animated: false)
    } else {
      // Retain the presenter until its pending FlutterResult is completed.
      DispatchQueue.main.async { self.invalidate() }
    }
  }

  private func pick(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let hour = args["initialHour"] as? Int, (0...23).contains(hour),
          let minute = args["initialMinute"] as? Int, (0...59).contains(minute),
          let title = args["title"] as? String, !title.isEmpty, title.count <= 30,
          let requestID = args["requestId"] as? Int, requestID > 0 else {
      result(FlutterError(code: "invalid_time", message: nil, details: nil))
      return
    }
    guard pendingResult == nil else {
      result(FlutterError(code: "picker_busy", message: nil, details: nil))
      return
    }
    guard let host, let window = host.viewIfLoaded?.window,
          window.windowScene?.activationState == .foregroundActive,
          host.presentedViewController == nil else {
      result(FlutterError(code: "scene_unavailable", message: nil, details: nil))
      return
    }

    let picker = NativePeriodTimeViewController(hour: hour, minute: minute, title: title)
    picker.onCancel = { [weak self] in self?.close(nil) }
    picker.onDone = { [weak self] selectedHour, selectedMinute in
      self?.close(["hour": selectedHour, "minute": selectedMinute])
    }
    let navigation = UINavigationController(rootViewController: picker)
    if host.traitCollection.userInterfaceIdiom == .pad {
      navigation.modalPresentationStyle = .formSheet
      let intrinsic = picker.pickerSize
      navigation.preferredContentSize = CGSize(
        width: max(350, intrinsic.width + 32),
        height: max(360, intrinsic.height + 120)
      )
    } else {
      navigation.modalPresentationStyle = .pageSheet
      if let sheet = navigation.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.selectedDetentIdentifier = .medium
        sheet.prefersGrabberVisible = true
      }
    }
    pendingResult = result
    pendingRequestID = requestID
    presented = navigation
    navigation.presentationController?.delegate = self
    host.present(navigation, animated: true) { [weak self, weak navigation] in
      guard let self else { return }
      if self.pendingRequestID != requestID {
        // A back action can cancel the request while presentation is animating.
        navigation?.dismiss(animated: true)
        return
      }
      guard let navigation, navigation.presentingViewController != nil else {
        self.finish(FlutterError(code: "presentation_failed", message: nil, details: nil))
        return
      }
      navigation.presentationController?.delegate = self
    }
  }

  private func dismiss(_ arguments: Any?, result: FlutterResult) {
    guard let args = arguments as? [String: Any],
          let requestID = args["requestId"] as? Int, requestID > 0 else {
      result(FlutterError(code: "invalid_request", message: nil, details: nil))
      return
    }
    if requestID == pendingRequestID { close(nil) }
    result(nil)
  }

  private func close(_ value: Any?) {
    guard pendingResult != nil else { return }
    let navigation = presented
    finish(value)
    navigation?.dismiss(animated: true)
  }

  private func finish(_ value: Any?) {
    guard let callback = pendingResult else { return }
    pendingResult = nil
    pendingRequestID = nil
    presented = nil
    callback(value)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard presentationController.presentedViewController === presented else { return }
    finish(nil)
  }
}

private final class NativePeriodTimeViewController: UIViewController {
  var onCancel: (() -> Void)?
  var onDone: ((Int, Int) -> Void)?
  private let picker = UIDatePicker()
  private let fixedCalendar: Calendar

  var pickerSize: CGSize { picker.intrinsicContentSize }

  init(hour: Int, minute: Int, title: String) {
    let zone = TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    fixedCalendar = calendar
    super.init(nibName: nil, bundle: nil)
    self.title = title
    picker.datePickerMode = .time
    picker.preferredDatePickerStyle = .wheels
    picker.minuteInterval = 1
    picker.calendar = calendar
    picker.timeZone = zone
    var components = DateComponents()
    components.year = 2001
    components.month = 1
    components.day = 15
    components.hour = hour
    components.minute = minute
    if let date = calendar.date(from: components) { picker.setDate(date, animated: false) }
  }

  required init?(coder: NSCoder) { fatalError("Use init(hour:minute:title:)") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "取消", style: .plain, target: self, action: #selector(cancelTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "完成", style: .done, target: self, action: #selector(doneTapped)
    )
    picker.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(picker)
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      picker.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
      picker.centerYAnchor.constraint(equalTo: safe.centerYAnchor),
      picker.widthAnchor.constraint(lessThanOrEqualTo: safe.widthAnchor),
      picker.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor),
      picker.bottomAnchor.constraint(lessThanOrEqualTo: safe.bottomAnchor),
    ])
  }

  @objc private func cancelTapped() { onCancel?() }

  @objc private func doneTapped() {
    let components = fixedCalendar.dateComponents([.hour, .minute], from: picker.date)
    guard let hour = components.hour, let minute = components.minute else { return }
    onDone?(hour, minute)
  }
}
