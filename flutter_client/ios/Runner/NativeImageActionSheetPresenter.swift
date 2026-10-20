import Flutter
import UIKit

/// Presents only the image action menu. Flutter still owns picking and editing.
final class NativeImageActionSheetPresenter: NSObject, UIAdaptivePresentationControllerDelegate {
  private weak var host: UIViewController?
  private weak var sourceView: UIView?
  private var presented: UIAlertController?
  private var pendingResult: FlutterResult?
  private var pendingRequestID: Int?
  private var selectedValue: String?
  private var closing = false
  private var presenting = false
  private var dismissalLink: CADisplayLink?
  private var dismissalRequestID: Int?

  init(host: UIViewController, sourceView: UIView) {
    self.host = host
    self.sourceView = sourceView
    super.init()
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    DispatchQueue.main.async { [weak self] in
      guard let self else {
        result(FlutterError(code: "scene_closed", message: nil, details: nil))
        return
      }
      switch call.method {
      case "showImageActions": self.show(call.arguments, result: result)
      case "dismissImageActions": self.dismiss(call.arguments, result: result)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  func invalidate() {
    if !Thread.isMainThread {
      DispatchQueue.main.async { self.invalidate() }
      return
    }
    let alert = presented
    finish(nil)
    alert?.dismiss(animated: false)
  }

  private func number(_ value: Any?) -> CGFloat? {
    guard let value = value as? NSNumber else { return nil }
    let number = CGFloat(value.doubleValue)
    return number.isFinite ? number : nil
  }

  private func show(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any],
          let requestID = args["requestId"] as? Int, requestID > 0,
          let title = args["title"] as? String, !title.isEmpty, title.count <= 40,
          let canRemove = args["canRemove"] as? Bool,
          let anchor = args["anchor"] as? [String: Any],
          let viewSize = args["flutterViewSize"] as? [String: Any],
          let x = number(anchor["x"]), let y = number(anchor["y"]),
          let width = number(anchor["width"]), let height = number(anchor["height"]),
          let viewWidth = number(viewSize["width"]),
          let viewHeight = number(viewSize["height"]),
          width > 0, height > 0, viewWidth > 0, viewHeight > 0 else {
      result(FlutterError(code: "invalid_image_action", message: nil, details: nil))
      return
    }
    guard pendingResult == nil else {
      result(FlutterError(code: "menu_busy", message: nil, details: nil))
      return
    }
    guard let host, let sourceView,
          let window = host.viewIfLoaded?.window,
          sourceView.window === window,
          window.windowScene?.activationState == .foregroundActive,
          host.presentedViewController == nil else {
      result(FlutterError(code: "scene_unavailable", message: nil, details: nil))
      return
    }
    let bounds = sourceView.bounds
    // The Flutter root overlay uses logical pixels, matching this full-window
    // FlutterViewController's UIKit point bounds. Reject stale rotation/layout.
    guard abs(bounds.width - viewWidth) < 1,
          abs(bounds.height - viewHeight) < 1,
          x >= 0, y >= 0,
          x + width <= bounds.width + 0.5,
          y + height <= bounds.height + 0.5 else {
      result(FlutterError(code: "invalid_anchor", message: nil, details: nil))
      return
    }

    let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: "从相册选择并自定义裁剪", style: .default) { [weak self, weak alert] _ in
      self?.close("choose", for: alert, requestID: requestID, actionSelected: true)
    })
    if canRemove {
      alert.addAction(UIAlertAction(title: "移除图片", style: .destructive) { [weak self, weak alert] _ in
        self?.close("remove", for: alert, requestID: requestID, actionSelected: true)
      })
    }
    alert.addAction(UIAlertAction(title: "取消", style: .cancel) { [weak self, weak alert] _ in
      self?.close(nil, for: alert, requestID: requestID, actionSelected: true)
    })
    guard let popover = alert.popoverPresentationController else {
      result(FlutterError(code: "presentation_failed", message: nil, details: nil))
      return
    }
    popover.sourceView = sourceView
    popover.sourceRect = CGRect(x: x, y: y, width: width, height: height)
    pendingResult = result
    pendingRequestID = requestID
    selectedValue = nil
    closing = false
    presenting = true
    presented = alert
    alert.presentationController?.delegate = self
    host.present(alert, animated: true) { [weak self, weak alert] in
      guard let self else { return }
      if self.pendingRequestID != requestID {
        alert?.dismiss(animated: true)
        return
      }
      self.presenting = false
      guard let alert, alert.presentingViewController != nil else {
        self.finish(self.closing ? nil : FlutterError(
          code: "presentation_failed", message: nil, details: nil
        ))
        return
      }
      alert.presentationController?.delegate = self
      if self.closing {
        self.dismissPresentedAlert(alert, requestID: requestID)
      }
    }
  }

  private func dismiss(_ arguments: Any?, result: FlutterResult) {
    guard let args = arguments as? [String: Any],
          let requestID = args["requestId"] as? Int, requestID > 0 else {
      result(FlutterError(code: "invalid_request", message: nil, details: nil))
      return
    }
    if requestID == pendingRequestID {
      close(nil, for: presented, requestID: requestID, actionSelected: false)
    }
    result(nil)
  }

  private func close(
    _ value: String?, for alert: UIAlertController?, requestID: Int, actionSelected: Bool
  ) {
    guard pendingResult != nil, let alert, presented === alert,
          pendingRequestID == requestID else { return }
    if closing {
      // A page exit overrides a choice that is still in its dismissal animation.
      if value == nil { selectedValue = nil }
      return
    }
    closing = true
    selectedValue = value
    // UIAlertController owns the dismissal after an action tap. Observe the
    // actual removal from the presentation hierarchy before returning a choice
    // that may immediately open the system photo picker.
    watchDismissal(requestID: requestID)
    if !actionSelected && !presenting {
      dismissPresentedAlert(alert, requestID: requestID)
    }
  }

  private func dismissPresentedAlert(_ alert: UIAlertController, requestID: Int) {
    guard presented === alert, pendingRequestID == requestID,
          !alert.isBeingDismissed else { return }
    alert.dismiss(animated: true) { [weak self, weak alert] in
      self?.finishIfDismissed(for: alert, requestID: requestID)
    }
  }

  private func watchDismissal(requestID: Int) {
    dismissalLink?.invalidate()
    dismissalRequestID = requestID
    let link = CADisplayLink(target: self, selector: #selector(checkDismissal(_:)))
    dismissalLink = link
    link.add(to: .main, forMode: .common)
  }

  @objc private func checkDismissal(_ link: CADisplayLink) {
    guard link === dismissalLink, let alert = presented,
          let requestID = dismissalRequestID else { return }
    finishIfDismissed(for: alert, requestID: requestID)
  }

  private func finishIfDismissed(for alert: UIAlertController?, requestID: Int) {
    guard let alert, presented === alert, pendingRequestID == requestID,
          alert.viewIfLoaded?.window == nil,
          alert.presentingViewController == nil else { return }
    finish(selectedValue)
  }

  private func finish(_ value: Any?) {
    guard let callback = pendingResult else { return }
    dismissalLink?.invalidate()
    dismissalLink = nil
    dismissalRequestID = nil
    pendingResult = nil
    pendingRequestID = nil
    presented = nil
    selectedValue = nil
    closing = false
    presenting = false
    callback(value)
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    guard presentationController.presentedViewController === presented,
          let requestID = pendingRequestID else { return }
    if !closing {
      closing = true
      selectedValue = nil
      watchDismissal(requestID: requestID)
    }
    finishIfDismissed(for: presented, requestID: requestID)
  }
}
