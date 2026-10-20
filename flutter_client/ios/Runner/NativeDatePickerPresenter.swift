import Flutter
import UIKit

/// A separate sheet keeps the established period-time picker untouched.
final class NativeDatePickerPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
  private weak var host: UIViewController?
  private var presented: UINavigationController?
  private var pendingResult: FlutterResult?
  private var pendingRequestID: Int?

  init(host: UIViewController) {
    self.host = host
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(code: "scene_closed", message: nil, details: nil))
        return
      }
      switch call.method {
      case "pickDate": self.pick(call.arguments, result: result)
      case "dismissDatePicker": self.dismiss(call.arguments, result: result)
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
      DispatchQueue.main.async { self.invalidate() }
    }
  }

  private func pick(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let year = args["initialYear"] as? Int, (2010...2100).contains(year),
          let month = args["initialMonth"] as? Int, (1...12).contains(month),
          let day = args["initialDay"] as? Int, (1...31).contains(day),
          let requestID = args["requestId"] as? Int, requestID > 0,
          NativeTermStartDateViewController.isValid(year: year, month: month, day: day) else {
      result(FlutterError(code: "invalid_date", message: nil, details: nil))
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

    let picker = NativeTermStartDateViewController(year: year, month: month, day: day)
    picker.onCancel = { [weak self] in self?.close(nil) }
    picker.onDone = { [weak self] selectedYear, selectedMonth, selectedDay in
      self?.close(["year": selectedYear, "month": selectedMonth, "day": selectedDay])
    }
    let navigation = UINavigationController(rootViewController: picker)
    if host.traitCollection.userInterfaceIdiom == .pad {
      navigation.modalPresentationStyle = .formSheet
      let intrinsic = picker.pickerSize
      navigation.preferredContentSize = CGSize(
        width: max(400, intrinsic.width + 48),
        height: max(520, intrinsic.height + 160)
      )
    } else {
      navigation.modalPresentationStyle = .pageSheet
      if let sheet = navigation.sheetPresentationController {
        // Inline calendars and large accessibility text need the full-height detent.
        sheet.detents = [.large()]
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

private final class NativeTermStartDateViewController: UIViewController {
  var onCancel: (() -> Void)?
  var onDone: ((Int, Int, Int) -> Void)?
  private let picker = UIDatePicker()
  private let fixedCalendar: Calendar

  var pickerSize: CGSize { picker.intrinsicContentSize }

  static func isValid(year: Int, month: Int, day: Int) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    components.hour = 12
    guard let date = calendar.date(from: components) else { return false }
    let actual = calendar.dateComponents([.year, .month, .day], from: date)
    var last = DateComponents()
    last.year = 2100
    last.month = 1
    last.day = 1
    last.hour = 23
    last.minute = 59
    guard let maximum = calendar.date(from: last) else { return false }
    return actual.year == year && actual.month == month && actual.day == day && date <= maximum
  }

  init(year: Int, month: Int, day: Int) {
    let zone = TimeZone(secondsFromGMT: 0)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    fixedCalendar = calendar
    super.init(nibName: nil, bundle: nil)
    title = "学期第一周"
    picker.datePickerMode = .date
    picker.preferredDatePickerStyle = .inline
    picker.calendar = calendar
    picker.timeZone = zone
    var initial = DateComponents()
    initial.year = year
    initial.month = month
    initial.day = day
    initial.hour = 12
    var lower = DateComponents()
    lower.year = 2010
    lower.month = 1
    lower.day = 1
    var upper = DateComponents()
    upper.year = 2100
    upper.month = 1
    upper.day = 1
    upper.hour = 23
    upper.minute = 59
    picker.minimumDate = calendar.date(from: lower)
    picker.maximumDate = calendar.date(from: upper)
    if let date = calendar.date(from: initial) { picker.setDate(date, animated: false) }
  }

  required init?(coder: NSCoder) { fatalError("Use init(year:month:day:)") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    navigationItem.leftBarButtonItem = UIBarButtonItem(
      title: "取消", style: .plain, target: self, action: #selector(cancelTapped)
    )
    navigationItem.rightBarButtonItem = UIBarButtonItem(
      title: "完成", style: .done, target: self, action: #selector(doneTapped)
    )
    let note = UILabel()
    note.text = "请选择星期一作为第一周的开始日期"
    note.font = .preferredFont(forTextStyle: .subheadline)
    note.textColor = .secondaryLabel
    note.textAlignment = .center
    note.numberOfLines = 0
    note.adjustsFontForContentSizeCategory = true
    picker.translatesAutoresizingMaskIntoConstraints = false
    let stack = UIStackView(arrangedSubviews: [note, picker])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    scroll.addSubview(stack)
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: safe.topAnchor),
      scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
      scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
      stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
      note.widthAnchor.constraint(equalTo: stack.widthAnchor),
      picker.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
    ])
  }

  @objc private func cancelTapped() { onCancel?() }

  @objc private func doneTapped() {
    let selected = fixedCalendar.dateComponents([.year, .month, .day], from: picker.date)
    guard let year = selected.year, let month = selected.month, let day = selected.day else { return }
    onDone?(year, month, day)
  }
}
