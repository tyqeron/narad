import Flutter
import UIKit
import MessageUI
import Contacts
import ContactsUI
import Security
import AVFoundation
import Darwin
import UniformTypeIdentifiers
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var mobile: NaradMobileBridge?
  override func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
    let started = super.application(application, didFinishLaunchingWithOptions: options)
    UNUserNotificationCenter.current().delegate = self
    return started
  }
  override func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.alert, .badge])
  }
  func didInitializeImplicitFlutterEngine(_ bridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: bridge.pluginRegistry)
    if let registrar = bridge.pluginRegistry.registrar(forPlugin: "NaradMobile") {
      mobile = NaradMobileBridge(messenger: registrar.messenger())
    }
  }
}

private struct NaradFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Foreground-only iOS host. Identity lives in non-migrating Keychain storage.
final class NaradMobileBridge: NSObject, UIDocumentPickerDelegate, MFMessageComposeViewControllerDelegate, CNContactViewControllerDelegate {
  static weak var active: NaradMobileBridge?
  private let queue = DispatchQueue(label: "dev.narad.ios.backend")
  private let channel: FlutterMethodChannel
  private var findPlayer: AVAudioPlayer?
  private var exportResult: FlutterResult?
  private var folderResult: FlutterResult?
  private let storageQueue = DispatchQueue(label: "dev.narad.ios.storage")
  private var storageBusy = false
  private var phoneTimer: Timer?
  private var backgroundObserver: NSObjectProtocol?
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dev.narad/ios", binaryMessenger: messenger)
    super.init()
    Self.active = self
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.background() }
    phoneTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      guard UIApplication.shared.applicationState == .active else { return }
      let smsAvailable = MFMessageComposeViewController.canSendText()
      self?.queue.async { self?.pollPhone(smsAvailable: smsAvailable) }
      if let bridge = self, !bridge.storageBusy {
        bridge.storageBusy = true
        bridge.storageQueue.async {
          bridge.pollStorage()
          DispatchQueue.main.async { bridge.storageBusy = false }
        }
      }
    }
    channel.setMethodCallHandler { [weak self] call, result in self?.handle(call, result) }
  }
  deinit { phoneTimer?.invalidate(); if let observer = backgroundObserver { NotificationCenter.default.removeObserver(observer) } }
  private func native(_ value: [String: Any]) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: value)
    guard let text = String(data: data, encoding: .utf8) else { throw NaradFailure(message: "Invalid native request") }
    let pointer = text.withCString { narad_mobile_call($0) }
    guard let pointer = pointer else { throw NaradFailure(message: "Native backend unavailable") }
    defer { narad_mobile_free(pointer) }
    let response = try JSONSerialization.jsonObject(with: Data(String(cString: pointer).utf8)) as? [String: Any] ?? [:]
    guard response["ok"] as? Bool == true else { throw NaradFailure(message: response["error"] as? String ?? "Native backend failed") }
    return response
  }
  private func identity() throws -> Any {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.narad.identity", kSecAttrAccount as String: "identity-v1"]
    var lookup = query
    lookup[kSecReturnData as String] = true
    var item: CFTypeRef?
    let status = SecItemCopyMatching(lookup as CFDictionary, &item)
    if status == errSecSuccess {
      guard let data = item as? Data else { throw NaradFailure(message: "Identity storage is invalid") }
      return try JSONSerialization.jsonObject(with: data)
    }
    guard status == errSecItemNotFound else { throw NaradFailure(message: "Unlock the iPhone to access its identity (\(status))") }
    guard let identity = try native(["op": "identity"])["identity"] else { throw NaradFailure(message: "Identity generation failed") }
    let data = try JSONSerialization.data(withJSONObject: identity)
    var insertion = query
    insertion[kSecValueData as String] = data
    insertion[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let saved = SecItemAdd(insertion as CFDictionary, nil)
    guard saved == errSecSuccess else { throw NaradFailure(message: "Unable to protect identity in Keychain (\(saved))") }
    return identity
  }
  private func directory() throws -> URL {
    var url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Narad", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.complete])
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
    return url
  }
  private func address() -> String {
    var first: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&first) == 0, let start = first else { return "127.0.0.1" }
    defer { freeifaddrs(first) }
    var pointer: UnsafeMutablePointer<ifaddrs>? = start
    while let entry = pointer {
      let interface = entry.pointee
      if String(cString: interface.ifa_name) == "en0", let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) {
        var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 { return String(cString: name) }
      }
      pointer = interface.ifa_next
    }
    return "127.0.0.1"
  }
  private func presenter() -> UIViewController? {
    var controller = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap { $0.windows }.first { $0.isKeyWindow }?.rootViewController
    while let next = controller?.presentedViewController { controller = next }
    return controller
  }
  func background() { findPlayer?.stop();findPlayer=nil; queue.async { _ = try? self.native(["op": "stop"]) } }
  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "ringDevice":
      do {
        guard let path = args["path"] as? String, URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path + "/") else { throw NaradFailure(message: "Invalid alert file") }
        findPlayer?.stop()
        findPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
        guard findPlayer?.play() == true else { throw NaradFailure(message: "Audio playback unavailable") }
        result(nil)
      } catch { result(FlutterError(code: "find_device", message: error.localizedDescription, details: nil)) }
    case "stopFinding": findPlayer?.stop();findPlayer=nil;result(nil)
    case "openUrl":
      guard let raw = args["url"] as? String, raw.utf8.count <= 2048,
            let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
        result(FlutterError(code: "open_url", message: "Only valid web links can be opened", details: nil)); return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        if opened { result(nil) } else { result(FlutterError(code: "open_url", message: "No default app can open this link", details: nil)) }
      }
    case "getTheme": result(UserDefaults.standard.string(forKey: "narad.theme") ?? "system")
    case "setTheme": UserDefaults.standard.set(args["theme"] as? String ?? "system", forKey: "narad.theme"); result(nil)
    case "setDeviceName":
      guard let name = args["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128 else { result(FlutterError(code: "name", message: "Use a device name of 1–128 UTF-8 bytes", details: nil)); return }
      UserDefaults.standard.set(name, forKey: "narad.name"); result(nil)
    case "ensureCameraPermission": AVCaptureDevice.requestAccess(for: .video) { allowed in DispatchQueue.main.async { result(allowed) } }
    case "importContact":
      let contact = CNMutableContact()
      contact.givenName = String((args["name"] as? String ?? "").prefix(256))
      contact.phoneNumbers = (args["phones"] as? [String] ?? []).prefix(8).map { CNLabeledValue(label: CNLabelOther, value: CNPhoneNumber(stringValue: String($0.prefix(256)))) }
      contact.emailAddresses = (args["emails"] as? [String] ?? []).prefix(8).map { CNLabeledValue(label: CNLabelOther, value: String($0.prefix(256)) as NSString) }
      let editor = CNContactViewController(forNewContact: contact)
      editor.contactStore = CNContactStore(); editor.delegate = self
      presenter()?.present(UINavigationController(rootViewController: editor), animated: true); result(nil)
    case "ensureDeviceAdmin": result(false)
    case "takeDeviceAction": result(nil)
    case "phoneSetup":
      let enabled = UserDefaults.standard.bool(forKey: "narad.phoneHandoff")
      let alert = UIAlertController(title: "Phone integration on iPhone", message: "View an Android phone’s permitted notifications, SMS and calls in its Phone panel. This iPhone can open SMS and call requests for your confirmation while Narad is visible. iOS does not let Narad read this phone’s SMS inbox, call history or general system notifications. Phone handoff is currently \(enabled ? "enabled" : "disabled"). Grant each paired device separately in Device settings.", preferredStyle: .alert)
      alert.addAction(UIAlertAction(title: enabled ? "Disable phone handoff" : "Enable phone handoff", style: .default) { _ in UserDefaults.standard.set(!enabled, forKey: "narad.phoneHandoff") })
      alert.addAction(UIAlertAction(title: "Allow contacts sharing", style: .default) { _ in
        CNContactStore().requestAccess(for: .contacts) { granted, _ in
          UserDefaults.standard.set(granted, forKey: "narad.contactsSharing")
        }
      })
      alert.addAction(UIAlertAction(title: "Stop contacts sharing", style: .destructive) { _ in UserDefaults.standard.set(false, forKey: "narad.contactsSharing") })
      alert.addAction(UIAlertAction(title: "Done", style: .cancel))
      presenter()?.present(alert, animated: true); result(nil)
    case "chooseSharedDirectory":
      guard folderResult == nil, exportResult == nil, let view = presenter() else { result(FlutterError(code: "folder", message: "Close the current file picker first", details: nil)); return }
      let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
      picker.allowsMultipleSelection = false; picker.delegate = self
      folderResult = result; view.present(picker, animated: true)
    case "saveReceivedFile":
      do {
        guard exportResult == nil, folderResult == nil, let id = args["id"] as? String, UUID(uuidString: id) != nil, let name = args["name"] as? String, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { throw NaradFailure(message: "Invalid completed transfer") }
        let file = try directory().appendingPathComponent("downloads").appendingPathComponent(id).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path), let view = presenter() else { throw NaradFailure(message: "Completed download unavailable") }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = self; exportResult = result; view.present(picker, animated: true)
      } catch { result(FlutterError(code: "export", message: error.localizedDescription, details: nil)) }
    case "start", "stop", "status":
      queue.async {
        do {
          var response: [String: Any] = [:]
          if call.method == "start" {
            let directory = try self.directory()
            let name = UserDefaults.standard.string(forKey: "narad.name") ?? UIDevice.current.name
            if try self.native(["op": "status"])["running"] as? Bool != true {
              _ = try self.native(["op": "start", "config": ["state_dir": directory.path, "api_port": 45700, "port": 45678, "name": name, "address": self.address(), "no_discovery": true, "identity": self.identity()]])
            }
            response = ["stateDirectory": directory.path, "apiPort": 45700, "deviceName": name]
          } else if call.method == "status" {
            let status = try self.native(["op": "status"])
            response = ["state": status["running"] as? Bool == true ? "running" : "stopped", "error": status["error"] ?? NSNull()]
          } else { _ = try self.native(["op": "stop"]) }
          let value = response
          DispatchQueue.main.async { result(call.method == "stop" ? nil : value) }
        } catch { DispatchQueue.main.async { result(FlutterError(code: "ios_backend", message: error.localizedDescription, details: nil)) } }
      }
    default: result(FlutterMethodNotImplemented)
    }
  }
  private var transferNotices: [String: String] = [:]
  private var transfersInitialized = false
  private func pollTransfers() throws {
    let snapshot = try native(["op": "bridge", "command": ["op": "status"]])
    for direction in ["transfers", "outbound", "shared_transfers"] {
      for item in snapshot[direction] as? [[String: Any]] ?? [] {
        guard let id = item["id"] as? String, UUID(uuidString: id) != nil,
              let status = item["status"] as? String else { continue }
        let key = "\(direction):\(id)"
        let name = (item["file_name"] as? String) ?? URL(fileURLWithPath: item["path"] as? String ?? "File").lastPathComponent
        let total = (item["total"] as? NSNumber ?? item["file_size"] as? NSNumber)?.int64Value ?? 0
        let done = (item["sent"] as? NSNumber ?? item["received"] as? NSNumber)?.int64Value ?? 0
        let percent = total > 0 ? min(100, done * 100 / total) : 0
        if direction == "transfers", status == "completed", !UserDefaults.standard.bool(forKey: "download.\(id)") {
          guard !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { continue }
          let source = try directory().appendingPathComponent("downloads/\(id)/\(name)")
          let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
          let destination = documents.appendingPathComponent("Downloads/Narad/\(id)")
          try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
          let file = destination.appendingPathComponent(name)
          if !FileManager.default.fileExists(atPath: file.path) { try FileManager.default.copyItem(at: source, to: file) }
          UserDefaults.standard.set(true, forKey: "download.\(id)")
        }
        let signature = "\(status):\(percent)"
        let previous = transferNotices.updateValue(signature, forKey: key)
        if previous == signature || (!transfersInitialized && previous == nil && ["completed", "cancelled"].contains(status)) { continue }
        let content = UNMutableNotificationContent()
        content.title = "\(direction == "outbound" || item["outgoing"] as? Bool == true ? "Sending" : "Receiving") \(name)"
        content.body = status == "completed" ? (direction == "shared_transfers" ? "Transfer complete · Shared folder" : "Transfer complete · Downloads/Narad") : "\(percent)% · \(done) / \(total) bytes · \(status)"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
      }
    }
    transfersInitialized = true
  }

  private func pollPhone(smsAvailable: Bool) {
    do {
      try pollTransfers()
      let contacts = UserDefaults.standard.bool(forKey: "narad.contactsSharing") && contactsAllowed()
      let handoff = UserDefaults.standard.bool(forKey: "narad.phoneHandoff")
      let enabled = handoff || contacts
      _ = try native(["op": "bridge", "command": ["op": "phone_bridge_ready", "support": ["enabled": enabled, "platform": "ios", "contacts": contacts, "sms_send": handoff && smsAvailable, "call_control": false, "dial": true, "confirmation_required": true]]])
      guard enabled else { return }
      let response = try native(["op": "bridge", "command": ["op": "phone_jobs"]])
      for job in response["jobs"] as? [[String: Any]] ?? [] {
        guard let id = job["id"] as? String, let kind = job["kind"] as? String, let args = job["args"] as? [String: Any] else { continue }
        _ = try native(["op": "bridge", "command": ["op": "phone_validate", "id": id]])
        if kind == "contacts_list" {
          var result: [String: Any]
          do {
            guard contacts else { throw NaradFailure(message: "Allow contacts sharing on the iPhone") }
            result = try contactPage(args)
          } catch { result = ["ok": false, "error": "Contacts access unavailable"] }
          _ = try native(["op": "bridge", "command": ["op": "phone_result", "id": id, "result": result]])
          continue
        }
        guard kind == "sms_send" || kind == "dial" else {
          _ = try native(["op": "bridge", "command": ["op": "phone_result", "id": id, "result": ["ok": false, "error": "This iPhone action is unavailable through Narad’s public iOS APIs"]]])
          continue
        }
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          var reply: [String: Any] = ["ok": false, "error": "Keep Narad visible on the iPhone and retry"]
          if UIApplication.shared.applicationState == .active && UserDefaults.standard.bool(forKey: "narad.phoneHandoff"), let view = self.presenter(), !(view is UIAlertController), !(view is MFMessageComposeViewController) {
            let number = args["number"] as? String ?? ""
            let valid = number.range(of: "^\\+?[0-9 ()-]{2,30}$", options: .regularExpression) != nil
            if valid && kind == "sms_send" && MFMessageComposeViewController.canSendText(), let text = args["text"] as? String, !text.isEmpty, text.count <= 1600, !(view is MFMessageComposeViewController) {
              let compose = MFMessageComposeViewController()
              compose.recipients = [number]; compose.body = text; compose.messageComposeDelegate = self
              view.present(compose, animated: true)
              reply = ["ok": true, "status": "awaiting_phone_confirmation", "message": "Confirm or cancel in Messages on the iPhone. This is not a delivery confirmation."]
            } else if valid && kind == "dial" {
              let alert = UIAlertController(title: "Call request from paired device", message: "Call \(number)? Call audio stays on the iPhone or its Bluetooth audio route.", preferredStyle: .alert)
              alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
              alert.addAction(UIAlertAction(title: "Continue", style: .default) { _ in
                let digits = number.filter { $0.isNumber || $0 == "+" }
                if let url = URL(string: "tel:\(digits)") { UIApplication.shared.open(url) }
              })
              view.present(alert, animated: true)
              reply = ["ok": true, "status": "awaiting_phone_confirmation", "message": "Confirm or cancel the call on the iPhone."]
            } else { reply = ["ok": false, "error": "Invalid request, SMS unavailable, or another message composer is open"] }
          }
          let result = reply
          self.queue.async { _ = try? self.native(["op": "bridge", "command": ["op": "phone_result", "id": id, "result": result]]) }
        }
      }
    } catch { /* Backend is stopped or the request was revoked; never retry actions. */ }
  }
  private func contactsAllowed() -> Bool {
    let status = CNContactStore.authorizationStatus(for: .contacts)
    if #available(iOS 18.0, *), status == .limited { return true }
    return status == .authorized
  }
  private func contactPage(_ args: [String: Any]) throws -> [String: Any] {
    let after = args["after"] as? String ?? ""
    let store = CNContactStore()
    let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor])
    // Stable identifier ordering provides a bounded cursor without persisting content.
    var page: [CNContact] = []
    try store.enumerateContacts(with: request) { contact, _ in
      if contact.identifier > after {
        page.append(contact); page.sort { $0.identifier < $1.identifier }
        if page.count > 21 { page.removeLast() }
      }
    }
    var rows: [[String: Any]] = []; var bytes = 0
    for contact in page.prefix(20) {
      let row: [String: Any] = ["id": contact.identifier, "name": String((contact.givenName + " " + contact.familyName).trimmingCharacters(in: .whitespaces).prefix(256)), "phones": contact.phoneNumbers.prefix(8).map { String($0.value.stringValue.prefix(256)) }, "emails": contact.emailAddresses.prefix(8).map { String(($0.value as String).prefix(256)) }]
      let size = try JSONSerialization.data(withJSONObject: row).count
      if bytes + size > 38000 { break }; bytes += size; rows.append(row)
    }
    return ["ok": true, "items": rows, "next_after": page.count > rows.count ? (rows.last?["id"] ?? NSNull()) : NSNull()]
  }
  func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) { viewController.navigationController?.dismiss(animated: true) }
  func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) { controller.dismiss(animated: true) }
  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    folderResult?(nil); folderResult = nil; exportResult?(false); exportResult = nil
  }
  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    if let result = folderResult {
      folderResult = nil
      do {
        guard let url = urls.first, url.startAccessingSecurityScopedResource() else { throw NaradFailure(message: "Folder access unavailable") }
        defer { url.stopAccessingSecurityScopedResource() }
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw NaradFailure(message: "Choose a directory") }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        result(["path": "bookmark:" + bookmark.base64EncodedString(), "label": url.lastPathComponent, "writable": FileManager.default.isWritableFile(atPath: url.path)])
      } catch { result(FlutterError(code: "folder", message: error.localizedDescription, details: nil)) }
      return
    }
    exportResult?(!urls.isEmpty); exportResult = nil
  }
}

// Security-scoped folder access is foreground-only, like the iOS runtime itself.
private extension NaradMobileBridge {
  func storageCall(_ command: [String: Any]) throws -> [String: Any] {
    try native(["op": "bridge", "command": command])
  }
  func storageValidate(_ id: String) throws { _ = try storageCall(["op": "storage_validate", "id": id]) }
  func storageName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
  }
  func storageNode(_ root: URL, _ path: String) throws -> URL {
    guard path.utf8.count <= 1024, !path.hasPrefix("/") else { throw NaradFailure(message: "Invalid shared path") }
    var node = root
    for part in path.split(separator: "/", omittingEmptySubsequences: true) {
      let name = String(part)
      guard storageName(name) else { throw NaradFailure(message: "Invalid shared path") }
      node.appendPathComponent(name)
      let values = try node.resourceValues(forKeys: [.isSymbolicLinkKey])
      guard values.isSymbolicLink != true else { throw NaradFailure(message: "Shared symbolic links are unavailable") }
    }
    let resolved = node.resolvingSymlinksInPath().standardizedFileURL
    let base = root.resolvingSymlinksInPath().standardizedFileURL.path
    let privatePath = try directory().resolvingSymlinksInPath().path
    guard (resolved.path == base || resolved.path.hasPrefix(base + "/")), resolved.path != privatePath, !resolved.path.hasPrefix(privatePath + "/") else { throw NaradFailure(message: "Shared path unavailable") }
    return node
  }
  func storageCoordinate(_ node: URL, writing: Bool, operation: @escaping (URL) throws -> [String: Any]) throws -> [String: Any] {
    var value: [String: Any]?
    var failure: Error?
    var coordinationError: NSError?
    let coordinator = NSFileCoordinator(filePresenter: nil)
    let accessor: (URL) -> Void = { url in
      do { value = try operation(url) } catch { failure = error }
    }
    if writing { coordinator.coordinate(writingItemAt: node, options: .forMerging, error: &coordinationError, byAccessor: accessor) }
    else { coordinator.coordinate(readingItemAt: node, options: .withoutChanges, error: &coordinationError, byAccessor: accessor) }
    if let error = failure { throw error }
    if let error = coordinationError { throw error }
    guard let result = value else { throw NaradFailure(message: "Folder provider unavailable") }
    return result
  }
  func storageJob(_ job: [String: Any], id: String) throws -> [String: Any] {
    try storageValidate(id)
    guard let encoded = job["root"] as? String, encoded.hasPrefix("bookmark:"), let bookmark = Data(base64Encoded: String(encoded.dropFirst(9))), let kind = job["kind"] as? String, let args = job["args"] as? [String: Any], let path = args["path"] as? String else { throw NaradFailure(message: "Invalid folder job") }
    var stale = false
    let root = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, root.startAccessingSecurityScopedResource() else { throw NaradFailure(message: "Choose the shared folder again") }
    defer { root.stopAccessingSecurityScopedResource() }
    let node = try storageNode(root, path)
    return try storageCoordinate(node, writing: kind == "publish") { [self] coordinated in
      try storageValidate(id)
      let current = try storageNode(root, path)
      guard current.standardizedFileURL == coordinated.standardizedFileURL else { throw NaradFailure(message: "Folder moved during request") }
      switch kind {
      case "list":
        var entries: [[String: Any]] = []; var bytes = 0
        let children = FileManager.default.enumerator(at: coordinated, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsSubdirectoryDescendants])
        while let child = children?.nextObject() as? URL, entries.count < 257 {
          let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
          guard storageName(child.lastPathComponent), values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { continue }
          _ = try storageNode(root, path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent)
          let entry: [String: Any] = ["name": child.lastPathComponent, "directory": values.isDirectory == true, "size": values.fileSize ?? 0]
          bytes += try JSONSerialization.data(withJSONObject: entry).count
          if bytes > 58000 { break }; entries.append(entry)
        }
        return ["ok": true, "entries": entries]
      case "read":
        guard let offset = args["offset"] as? NSNumber, offset.int64Value >= 0 else { throw NaradFailure(message: "Invalid read offset") }
        let values = try coordinated.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, offset.uint64Value <= UInt64(size) else { throw NaradFailure(message: "Shared file unavailable") }
        let handle = try FileHandle(forReadingFrom: coordinated); defer { try? handle.close() }
        try handle.seek(toOffset: offset.uint64Value)
        let data = try handle.read(upToCount: 48 * 1024) ?? Data()
        return ["ok": true, "data": data.base64EncodedString(), "size": size, "offset": offset, "next": offset.uint64Value + UInt64(data.count)]
      case "publish":
        guard let name = args["name"] as? String, storageName(name), let sourcePath = args["source"] as? String, let upload = args["upload_id"] as? String, UUID(uuidString: upload) != nil else { throw NaradFailure(message: "Invalid upload") }
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        let staging = try directory().appendingPathComponent("share-completed", isDirectory: true).resolvingSymlinksInPath()
        guard source.path.hasPrefix(staging.path + "/"), try coordinated.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw NaradFailure(message: "Invalid upload source") }
        let destination = coordinated.appendingPathComponent(name)
        let temporary = coordinated.appendingPathComponent(".narad-upload-\(upload).part")
        guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: temporary.path), FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw NaradFailure(message: "Upload destination exists or is read-only") }
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let output = try FileHandle(forWritingTo: temporary); defer { try? output.close() }
        var total = 0; var checkAt = 0
        while let data = try input.read(upToCount: 64 * 1024), !data.isEmpty {
          if total >= checkAt { try storageValidate(id); checkAt = total + 1024 * 1024 }
          try output.write(contentsOf: data); total += data.count
        }
        try output.synchronize(); try output.close(); try storageValidate(id)
        // FileManager.moveItem fails if the destination already exists.
        try FileManager.default.moveItem(at: temporary, to: destination)
        return ["ok": true]
      default: throw NaradFailure(message: "Unknown shared folder operation")
      }
    }
  }
  func pollStorage() {
    do {
      let response = try storageCall(["op": "storage_jobs"])
      for job in response["jobs"] as? [[String: Any]] ?? [] {
        guard let id = job["id"] as? String else { continue }
        let result: [String: Any]
        do { result = try storageJob(job, id: id) }
        catch { result = ["ok": false, "error": "Shared folder unavailable, read-only, or file already exists. Reopen Narad and check folder access on the source device."] }
        _ = try? storageCall(["op": "storage_result", "id": id, "result": result])
      }
    } catch { /* Foreground runtime stopped; do not retry native actions. */ }
  }
}
