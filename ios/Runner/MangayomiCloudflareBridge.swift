import Flutter
import UIKit
import WebKit

final class MangayomiCloudflareBridge: NSObject {
  private static let userAgentKey = "mangayomi.cloudflare.userAgent"

  private var pendingResult: FlutterResult?
  private weak var solveController: MangayomiCloudflareViewController?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "imageCookie":
      guard
        let arguments = call.arguments as? [String: Any],
        let value = arguments["url"] as? String,
        let url = URL(string: value),
        url.host != nil
      else {
        result(FlutterError(code: "BAD_ARGS", message: "url required", details: nil))
        return
      }

      WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
        let matching = cookies.filter { Self.cookie($0, appliesTo: url) }
        var headers: [String: String] = [:]
        if !matching.isEmpty {
          headers["Cookie"] = matching
            .sorted { $0.path.count > $1.path.count }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        }
        if let userAgent = UserDefaults.standard.string(forKey: Self.userAgentKey) {
          headers["User-Agent"] = userAgent
        }
        DispatchQueue.main.async { result(headers) }
      }

    case "solveMangayomiCloudflare":
      guard
        let arguments = call.arguments as? [String: Any],
        let value = arguments["url"] as? String,
        let url = URL(string: value),
        ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
        url.host != nil
      else {
        result(FlutterError(code: "BAD_ARGS", message: "valid url required", details: nil))
        return
      }
      DispatchQueue.main.async { self.presentSolver(for: url, result: result) }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    guard host == domain || host.hasSuffix(".\(domain)") else { return false }
    guard !cookie.isSecure || url.scheme?.lowercased() == "https" else { return false }
    if let expires = cookie.expiresDate, expires <= Date() { return false }

    let requestPath = url.path.isEmpty ? "/" : url.path
    let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
    return requestPath == cookiePath ||
      requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : "\(cookiePath)/")
  }

  private func presentSolver(for url: URL, result: @escaping FlutterResult) {
    guard pendingResult == nil else {
      result(FlutterError(code: "SOLVE_IN_PROGRESS", message: "A challenge is already open", details: nil))
      return
    }
    guard let presenter = Self.topViewController() else {
      result(FlutterError(code: "NO_VIEW", message: "Could not open the challenge", details: nil))
      return
    }

    pendingResult = result
    let controller = MangayomiCloudflareViewController(
      url: url,
      onUserAgent: { userAgent in
        UserDefaults.standard.set(userAgent, forKey: Self.userAgentKey)
      },
      onClose: { [weak self] in self?.finishSolver() }
    )
    solveController = controller
    controller.modalPresentationStyle = .fullScreen
    presenter.present(controller, animated: true)
  }

  private func finishSolver() {
    let result = pendingResult
    pendingResult = nil
    solveController = nil
    result?(nil)
  }

  private static func topViewController() -> UIViewController? {
    let root = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap(\.windows)
      .first(where: \.isKeyWindow)?.rootViewController
    var top = root
    while let presented = top?.presentedViewController { top = presented }
    if let navigation = top as? UINavigationController { return navigation.visibleViewController }
    if let tabs = top as? UITabBarController { return tabs.selectedViewController }
    return top
  }
}

private final class MangayomiCloudflareViewController: UIViewController,
  WKNavigationDelegate, WKHTTPCookieStoreObserver {
  private let url: URL
  private let dataStore = WKWebsiteDataStore.default()
  private let onUserAgent: (String) -> Void
  private let onClose: () -> Void
  private var webView: WKWebView!
  private var didClose = false

  init(url: URL, onUserAgent: @escaping (String) -> Void, onClose: @escaping () -> Void) {
    self.url = url
    self.onUserAgent = onUserAgent
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let navigationBar = UINavigationBar()
    navigationBar.translatesAutoresizingMaskIntoConstraints = false
    let item = UINavigationItem(title: "Cloudflare verification")
    item.leftBarButtonItem = UIBarButtonItem(
      barButtonSystemItem: .close,
      target: self,
      action: #selector(closeTapped)
    )
    navigationBar.setItems([item], animated: false)

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = dataStore
    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.translatesAutoresizingMaskIntoConstraints = false
    webView.navigationDelegate = self

    view.addSubview(navigationBar)
    view.addSubview(webView)
    NSLayoutConstraint.activate([
      navigationBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      navigationBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      navigationBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.topAnchor.constraint(equalTo: navigationBar.bottomAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
    ])

    dataStore.httpCookieStore.add(self)
    webView.load(URLRequest(url: url))
  }

  deinit { dataStore.httpCookieStore.remove(self) }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in
      if let userAgent = value as? String { self?.onUserAgent(userAgent) }
      self?.checkForClearance()
    }
  }

  func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
    checkForClearance()
  }

  private func checkForClearance() {
    dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
      guard let self,
            cookies.contains(where: {
              $0.name == "cf_clearance" && MangayomiCloudflareBridge.cookie($0, appliesTo: self.url)
            }) else { return }
      DispatchQueue.main.async { self.close() }
    }
  }

  @objc private func closeTapped() { close() }

  private func close() {
    guard !didClose else { return }
    didClose = true
    dismiss(animated: true, completion: onClose)
  }
}
