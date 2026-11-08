import CFreeRDP
import CryptoKit
import Foundation

// MARK: - Pure helpers (unit-tested without a network)

/// Converts FreeRDP certificate callback material into the canonical SHA-256 fingerprint.
public enum RdpCertificateFingerprint {
  /// SHA-256 of DER bytes as 64 uppercase hex characters.
  public static func sha256Hex(ofDER der: Data) -> String {
    SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined()
  }

  /// Decodes the first CERTIFICATE block of a PEM string to DER.
  public static func der(fromPEM pem: String) -> Data? {
    guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
      let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex)
    else { return nil }
    let body = pem[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }
    return Data(base64Encoded: String(body))
  }

  /// Accepts "sha256:aa:bb..." / "AA:BB..." / plain hex; returns nil unless exactly 32 bytes.
  public static func normalizedHex(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.lowercased().hasPrefix("sha256:") { text.removeFirst(7) }
    text.removeAll { $0 == ":" || $0 == " " }
    guard text.count == 64, text.allSatisfy(\.isHexDigit) else { return nil }
    return text.uppercased()
  }

  /// Fingerprint from the FreeRDP callback argument (PEM when `isPEM`, else a legacy hash string).
  public static func fingerprint(from value: String, isPEM: Bool) -> String? {
    if isPEM {
      return der(fromPEM: value).map(sha256Hex(ofDER:))
    }
    return normalizedHex(value)
  }
}

/// The one Mac folder an RDP session may share with Windows (`\\tsclient\<driveName>`).
/// Validated in the app before launch and again in the helper before FreeRDP sees it.
public enum RdpSharedFolder {
  public enum ValidationError: Error, Equatable {
    case invalidPath
    case notADirectory
    case rootDirectory
  }

  static let maxDriveNameLength = 32

  /// Canonical (symlink-free) URL of an existing directory other than "/".
  public static func validate(_ path: String) throws -> URL {
    guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw ValidationError.invalidPath }
    guard let resolved = realpath(path, nil) else { throw ValidationError.notADirectory }
    defer { free(resolved) }
    let canonical = String(cString: resolved)
    guard canonical != "/" else { throw ValidationError.rootDirectory }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue
    else { throw ValidationError.notADirectory }
    return URL(fileURLWithPath: canonical, isDirectory: true)
  }

  /// Last path component folded to [A-Za-z0-9 _-], at most 32 characters; "Mac" if nothing is left.
  public static func driveName(for folder: URL) -> String {
    let folded = folder.lastPathComponent.folding(options: .diacriticInsensitive, locale: nil)
    let kept = folded.unicodeScalars.filter {
      $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "_" || $0 == "-")
    }
    let name = String(String.UnicodeScalarView(kept.prefix(maxDriveNameLength)))
      .trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? "Mac" : name
  }
}

/// Maps the app's pointer flag bits (see RdpMetalHostingView) to RDP PTR_FLAGS_*.
public enum RdpPointerFlags {
  public static func rdpFlags(forButtonFlags flags: UInt16) -> UInt16 {
    switch flags {
    case 0x01: return 0x8000 | 0x1000  // left down
    case 0x02: return 0x1000  // left up
    case 0x04: return 0x8000 | 0x2000  // right down
    case 0x08: return 0x2000  // right up
    case 0x09: return 0x8000 | 0x4000  // middle down
    case 0x0A: return 0x4000  // middle up
    case 0x10: return 0x0200 | 0x0078  // wheel up
    case 0x20: return 0x0200 | 0x0100 | 0x0078  // wheel down
    case 0x40: return 0x0400 | 0x0078  // horizontal wheel right
    case 0x80: return 0x0400 | 0x0100 | 0x0078  // horizontal wheel left
    default: return 0x0800  // move
    }
  }
}

/// Pure mapping from a FreeRDP last-error code to a session error (low 16 bits = ERRCONNECT_*).
func mapFreeRdpError(code: UInt32, message: String) -> (RdpSessionError, RdpDisconnectReason) {
  switch code & 0xFFFF {
  case UInt32(ERRCONNECT_WRONG_PASSWORD), UInt32(ERRCONNECT_PASSWORD_EXPIRED),
    UInt32(ERRCONNECT_PASSWORD_MUST_CHANGE), UInt32(ERRCONNECT_ACCOUNT_DISABLED),
    UInt32(ERRCONNECT_ACCOUNT_LOCKED_OUT), 0x0009 /* AUTHENTICATION_FAILED */:
    return (.credentialUnavailable(message), .authenticationFailed)
  case UInt32(ERRCONNECT_DNS_ERROR), UInt32(ERRCONNECT_DNS_NAME_NOT_FOUND):
    return (.dnsResolutionFailed(message), .networkDrop)
  case UInt32(ERRCONNECT_TLS_CONNECT_FAILED):
    return (.tlsHandshakeFailed(message), .networkDrop)
  case UInt32(ERRCONNECT_CONNECT_FAILED), UInt32(ERRCONNECT_CONNECT_TRANSPORT_FAILED),
    UInt32(ERRCONNECT_SECURITY_NEGO_CONNECT_FAILED):
    return (.tcpConnectionFailed(message), .networkDrop)
  default:
    return (.protocolViolation(message), .networkDrop)
  }
}

// MARK: - Client

/// How the user/verifier decided about a presented certificate. Credentials are only
/// carried on acceptance, so nothing secret is resolved before trust is decided.
struct RdpTrustDecision {
  let credentials: RdpResolvedCredentials
}

/// FreeRDP client running on a dedicated thread; only instantiated inside `RdpSessionHelper`.
final class FreeRdpClient: @unchecked Sendable {
  static func isChangedCertificate(flags: UInt32) -> Bool {
    flags & UInt32(VERIFY_CERT_FLAG_CHANGED) != 0
  }
  struct Callbacks {
    /// Called on the RDP thread; blocks until trust is decided. nil = reject.
    var verifyCertificate: @Sendable (RdpCertificateRecord, _ changed: Bool) -> RdpTrustDecision?
    var onConnected: @Sendable () -> Void
    var onFrame: @Sendable (RdpFramebuffer) -> Void
    /// Always called exactly once when the thread ends (error nil = clean end).
    var onEnded: @Sendable (_ lastErrorCode: UInt32, _ message: String, _ connected: Bool) -> Void
    var onClipboardStatus: (@Sendable (String, Bool) -> Void)? = nil
  }

  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [UnsafeMutableRawPointer: FreeRdpClient] = [:]

  private static func client(for instance: UnsafeMutablePointer<freerdp>?) -> FreeRdpClient? {
    guard let instance else { return nil }
    registryLock.lock()
    defer { registryLock.unlock() }
    return registry[UnsafeMutableRawPointer(instance)]
  }

  private let host: String
  private let port: Int
  private let resolution: RdpDisplayResolution
  private let sharedFolder: URL?
  private let callbacks: Callbacks
  private let finished = DispatchSemaphore(value: 0)

  /// Guards `instance` and `disp` so input/resize never touch freed memory.
  private let ioLock = NSLock()
  private var instance: UnsafeMutablePointer<freerdp>?
  private var disp: UnsafeMutablePointer<DispClientContext>?
  private var connected = false
  /// Touched only on the RDP thread (except its own thread-safe focus flag).
  private let clipboard = RdpClipboardBridge()

  init(
    host: String, port: Int, resolution: RdpDisplayResolution, clipboardDirectory: URL? = nil,
    sharedFolder: URL? = nil, callbacks: Callbacks
  ) {
    self.host = host
    self.port = port
    self.resolution = resolution
    // Defense in depth: an invalid folder is dropped, so the session runs without sharing.
    self.sharedFolder = sharedFolder.flatMap { try? RdpSharedFolder.validate($0.path) }
    self.callbacks = callbacks
    clipboard.configureFiles(directory: clipboardDirectory, onStatus: callbacks.onClipboardStatus)
  }

  func start() {
    let thread = Thread { [self] in run() }
    thread.name = "mrw.rdp.\(host)"
    thread.qualityOfService = .userInteractive
    thread.start()
  }

  /// Thread-safe; makes the loop exit and unblocks connect.
  func abort() {
    ioLock.lock()
    if let instance, let context = instance.pointee.context {
      _ = freerdp_abort_connect_context(context)
    }
    ioLock.unlock()
  }

  /// Returns false on timeout.
  func waitUntilFinished(timeout: TimeInterval) -> Bool {
    if finished.wait(timeout: .now() + timeout) == .success {
      finished.signal()
      return true
    }
    return false
  }

  func cancelClipboardFiles() { clipboard.cancelFileTransfer() }

  func setClipboardActive(_ active: Bool) { clipboard.setActive(active) }

  // MARK: Input

  func sendKey(_ event: RdpKeyboardEvent) {
    ioLock.lock()
    defer { ioLock.unlock() }
    guard connected, let input = instance?.pointee.context?.pointee.input else { return }
    let code = UInt32(event.scancode & 0xFF) | (event.isExtended ? 0x100 : 0)
    _ = freerdp_input_send_keyboard_event_ex(input, !event.isKeyUp, false, code)
  }

  func sendPointer(x: UInt16, y: UInt16, buttonFlags: UInt16) {
    ioLock.lock()
    defer { ioLock.unlock() }
    guard connected, let input = instance?.pointee.context?.pointee.input else { return }
    _ = freerdp_input_send_mouse_event(input, RdpPointerFlags.rdpFlags(forButtonFlags: buttonFlags), x, y)
  }

  func resize(_ r: RdpDisplayResolution) {
    ioLock.lock()
    defer { ioLock.unlock() }
    guard connected, let disp, let send = disp.pointee.SendMonitorLayout else { return }
    var layout = DISPLAY_CONTROL_MONITOR_LAYOUT(
      Flags: 1, Left: 0, Top: 0, Width: r.width & ~1, Height: r.height,
      PhysicalWidth: 0, PhysicalHeight: 0, Orientation: 0,
      DesktopScaleFactor: r.scaleFactor, DeviceScaleFactor: 100)
    _ = send(disp, 1, &layout)
  }

  // MARK: Thread body

  private func run() {
    defer { finished.signal() }
    if getenv("HOME") == nil {
      setenv("HOME", NSHomeDirectory(), 1)
    }
    if getenv("TMPDIR") == nil {
      setenv("TMPDIR", NSTemporaryDirectory(), 1)
    }
    guard let inst = freerdp_new() else {
      callbacks.onEnded(0, "freerdp_new failed", false)
      return
    }
    let key = UnsafeMutableRawPointer(inst)
    Self.registryLock.lock()
    Self.registry[key] = self
    Self.registryLock.unlock()
    defer {
      Self.registryLock.lock()
      Self.registry[key] = nil
      Self.registryLock.unlock()
    }

    Self.installChannelLoader(on: inst)
    inst.pointee.PostConnect = { i in
      guard let i, let c = FreeRdpClient.client(for: i) else { return ObjCBool(false) }
      return ObjCBool(c.postConnect(i))
    }
    inst.pointee.PostDisconnect = { if let i = $0 { gdi_free(i) } }
    inst.pointee.VerifyCertificateEx = { inst, _, _, commonName, subject, issuer, fp, flags in
      guard let inst, let c = FreeRdpClient.client(for: inst) else { return 0 }
      return c.verify(
        inst, commonName: commonName, subject: subject, issuer: issuer,
        fingerprint: fp, flags: flags)
    }
    inst.pointee.VerifyChangedCertificateEx = { _, _, _, _, _, _, _, _, _, _, _ in
      0  // changed certificate (per FreeRDP's own store) is a hard reject; we never store there
    }

    guard freerdp_context_new(inst), let context = inst.pointee.context else {
      freerdp_free(inst)
      callbacks.onEnded(0, "freerdp_context_new failed", false)
      return
    }
    ioLock.lock()
    instance = inst
    ioLock.unlock()

    var lastError: UInt32 = 0
    var message = ""
    if configure(inst), freerdp_connect(inst) {
      ioLock.lock()
      connected = true
      ioLock.unlock()
      callbacks.onConnected()
      loop: while !freerdp_shall_disconnect_context(context) {
        var handles = [HANDLE?](repeating: nil, count: 64)
        let count = freerdp_get_event_handles(context, &handles, 64)
        if count == 0 { break }
        let wait = WaitForMultipleObjects(count, handles, false, 100)
        if wait == WAIT_FAILED { break loop }
        if !freerdp_check_event_handles(context) { break loop }
        clipboard.pollLocalChange()
      }
    } else {
      lastError = freerdp_get_last_error(context)
      message = String(cString: freerdp_get_last_error_string(lastError))
    }
    let wasConnected = connected

    ioLock.lock()
    connected = false
    disp = nil
    ioLock.unlock()
    _ = freerdp_disconnect(inst)
    ioLock.lock()
    instance = nil
    ioLock.unlock()
    freerdp_context_free(inst)
    freerdp_free(inst)
    callbacks.onEnded(lastError, message, wasConnected)
  }

  private func configure(_ inst: UnsafeMutablePointer<freerdp>) -> Bool {
    guard let s = inst.pointee.context?.pointee.settings else { return false }
    var ok = freerdp_settings_set_string(s, FreeRDP_ServerHostname, host)
    ok = freerdp_settings_set_uint32(s, FreeRDP_ServerPort, UInt32(port)) && ok
    ok = freerdp_settings_set_uint32(s, FreeRDP_DesktopWidth, resolution.width) && ok
    ok = freerdp_settings_set_uint32(s, FreeRDP_DesktopHeight, resolution.height) && ok
    ok = freerdp_settings_set_uint32(s, FreeRDP_ColorDepth, 32) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_SoftwareGdi, true) && ok
    // Security: NLA only, never ignore certificates, never auto-accept.
    ok = freerdp_settings_set_bool(s, FreeRDP_NlaSecurity, true) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_TlsSecurity, false) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_RdpSecurity, false) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_IgnoreCertificate, false) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_AutoAcceptCertificate, false) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_AutoDenyCertificate, false) && ok
    ok = Self.configureDeviceRedirection(s, sharedFolder: sharedFolder) && ok
    // Text and file clipboard use cliprdr.
    ok = freerdp_settings_set_bool(s, FreeRDP_RedirectClipboard, true) && ok
    // Display control channel for dynamic resize. No GFX/H.264 yet.
    ok = freerdp_settings_set_bool(s, FreeRDP_SupportGraphicsPipeline, false) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_SupportDisplayControl, true) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_DynamicResolutionUpdate, true) && ok
    ok = freerdp_settings_set_bool(s, FreeRDP_SupportDynamicChannels, true) && ok
    ok = freerdp_settings_set_uint32(s, FreeRDP_DesktopScaleFactor, resolution.scaleFactor) && ok
    "disp".withCString { name in
      var argv: [UnsafePointer<CChar>?] = [name]
      ok = freerdp_client_add_dynamic_channel(s, 1, &argv) && ok
    }
    if let pubSub = inst.pointee.context?.pointee.pubSub {
      _ = PubSub_SubscribeChannelConnected(pubSub) { ctx, e in
        guard let ctx, let e, let name = e.pointee.name, let iface = e.pointee.pInterface else { return }
        let rdpCtx = ctx.assumingMemoryBound(to: rdpContext.self)
        guard let client = FreeRdpClient.client(for: rdpCtx.pointee.instance) else { return }
        switch String(cString: name) {
        case "disp":
          client.ioLock.lock()
          client.disp = iface.assumingMemoryBound(to: DispClientContext.self)
          client.ioLock.unlock()
        case "cliprdr":
          client.clipboard.attach(iface.assumingMemoryBound(to: CliprdrClientContext.self))
        default: break
        }
      }
      _ = PubSub_SubscribeChannelDisconnected(pubSub) { ctx, e in
        guard let ctx, let e, let name = e.pointee.name, String(cString: name) == "cliprdr" else { return }
        let rdpCtx = ctx.assumingMemoryBound(to: rdpContext.self)
        FreeRdpClient.client(for: rdpCtx.pointee.instance)?.clipboard.detach()
      }
    }
    return ok
  }

  /// All device redirection is off unless a validated `sharedFolder` is given; then rdpdr carries
  /// exactly that one drive. Printers, smart cards, ports and audio are never redirected.
  static func configureDeviceRedirection(_ s: UnsafeMutablePointer<rdpSettings>, sharedFolder: URL?) -> Bool {
    var ok = true
    for key in [FreeRDP_DeviceRedirection, FreeRDP_AudioPlayback,
      FreeRDP_AudioCapture, FreeRDP_RedirectDrives, FreeRDP_RedirectHomeDrive, FreeRDP_RedirectPrinters,
      FreeRDP_RedirectSmartCards, FreeRDP_RedirectSerialPorts, FreeRDP_RedirectParallelPorts] {
      ok = freerdp_settings_set_bool(s, key, false) && ok
    }
    for name in ["rdpdr", "rdpsnd", "drive", "printer", "smartcard"] {
      _ = freerdp_client_del_static_channel(s, name)
    }
    guard let sharedFolder else { return ok }
    // freerdp_device_new copies both strings; the collection then owns the device.
    let device = RdpSharedFolder.driveName(for: sharedFolder).withCString { name in
      sharedFolder.path.withCString { path in
        var args: [UnsafePointer<CChar>?] = [name, path]
        return freerdp_device_new(UInt32(RDPDR_DTYP_FILESYSTEM), args.count, &args)
      }
    }
    guard let device else { return false }
    guard freerdp_device_collection_add(s, device) else {
      freerdp_device_free(device)
      return false
    }
    ok = freerdp_settings_set_bool(s, FreeRDP_DeviceRedirection, true) && ok
    return freerdp_settings_set_bool(s, FreeRDP_RedirectDrives, true) && ok
  }

  // MARK: FreeRDP callbacks (RDP thread)

  static func installChannelLoader(on instance: UnsafeMutablePointer<freerdp>) {
    // FreeRDP 3.10 replaces the channel manager after PreConnect, including on redirection.
    instance.pointee.LoadChannels = { instance in
      guard let instance else { return ObjCBool(false) }
      return ObjCBool(FreeRdpClient.loadChannels(instance))
    }
  }

  private static func loadChannels(_ inst: UnsafeMutablePointer<freerdp>) -> Bool {
    guard let context = inst.pointee.context, let settings = context.pointee.settings else { return false }
    guard freerdp_register_addin_provider(freerdp_channels_load_static_addin_entry, 0) == 0,
      freerdp_settings_set_uint32(settings, FreeRDP_ThreadingFlags,
        freerdp_settings_get_uint32(settings, FreeRDP_ThreadingFlags) | UInt32(THREADING_FLAGS_DISABLE_THREADS))
    else { return false }
    // Channel callbacks and clipboard polling share this RDP thread.
    // freerdp_client_load_addins could dlopen non-built addins; load only drdynvc (resolves the
    // "disp" dynamic channel from the static table), cliprdr and, for a shared folder, rdpdr
    // (resolves its "drive" device from the static table via the provider registered above).
    var names = ["drdynvc", "cliprdr"]
    if freerdp_settings_get_bool(settings, FreeRDP_DeviceRedirection) { names.append("rdpdr") }
    return names.allSatisfy { loadStaticChannel($0, context) }
  }

  private static func loadStaticChannel(_ name: String, _ context: UnsafeMutablePointer<rdpContext>) -> Bool {
    guard let entry = freerdp_channels_load_static_addin_entry(
      name, nil, nil, UInt32(FREERDP_ADDIN_CHANNEL_STATIC | FREERDP_ADDIN_CHANNEL_ENTRYEX))
    else { return false }
    return freerdp_channels_client_load_ex(
      context.pointee.channels, context.pointee.settings,
      unsafeBitCast(entry, to: PVIRTUALCHANNELENTRYEX.self), context.pointee.settings) == 0
  }

  // FREERDP_PIXEL_FORMAT(32, TYPE_BGRA=4, 8, 8, 8, 8)
  private static let pixelFormatBGRA32: UInt32 = (32 << 24) | (4 << 16) | (8 << 12) | (8 << 8) | (8 << 4) | 8

  private func postConnect(_ inst: UnsafeMutablePointer<freerdp>) -> Bool {
    guard gdi_init(inst, Self.pixelFormatBGRA32), let context = inst.pointee.context,
      let update = context.pointee.update
    else { return false }
    update.pointee.EndPaint = { ctx in
      guard let ctx, let client = FreeRdpClient.client(for: ctx.pointee.instance) else { return ObjCBool(true) }
      client.emitFrame(ctx)
      return ObjCBool(true)
    }
    return true
  }

  private func emitFrame(_ context: UnsafeMutablePointer<rdpContext>) {
    guard let gdi = context.pointee.gdi, let buffer = gdi.pointee.primary_buffer else { return }
    let width = Int(gdi.pointee.width), height = Int(gdi.pointee.height)
    let stride = Int(gdi.pointee.stride)
    guard width > 0, height > 0,
      width <= Int(RdpDisplayResolution.maximumDimension),
      height <= Int(RdpDisplayResolution.maximumDimension),
      stride >= width * 4, stride <= Int.max / height,
      stride * height <= RdpHelperMessage.maxBodyBytes - 13
    else { return }
    // ponytail: full-frame copy per EndPaint; switch to dirty-rect/IOSurface in Phase 3.
    let data = Data(bytes: buffer, count: stride * height)
    callbacks.onFrame(
      RdpFramebuffer(width: width, height: height, bytesPerRow: stride, pixelFormat: .bgra8Unorm, data: data))
  }

  /// Returns 2 (accept for this session only; FreeRDP must not persist) or 0 (reject).
  private func verify(
    _ inst: UnsafeMutablePointer<freerdp>, commonName: UnsafePointer<CChar>?,
    subject: UnsafePointer<CChar>?, issuer: UnsafePointer<CChar>?,
    fingerprint: UnsafePointer<CChar>?, flags: DWORD
  ) -> DWORD {
    guard let fingerprint,
      let hex = RdpCertificateFingerprint.fingerprint(
        from: String(cString: fingerprint), isPEM: flags & DWORD(VERIFY_CERT_FLAG_FP_IS_PEM) != 0)
    else { return 0 }
    let subj = subject.map { String(cString: $0) } ?? ""
    let record = RdpCertificateRecord(
      host: host, port: port, sha256Fingerprint: hex,
      subjectCN: commonName.map { String(cString: $0) } ?? subj,
      issuerCN: issuer.map { String(cString: $0) } ?? "")
    let changed = Self.isChangedCertificate(flags: flags)
    guard let decision = callbacks.verifyCertificate(record, changed),
      let s = inst.pointee.context?.pointee.settings
    else { return 0 }
    // Trust decided: only now do credentials enter FreeRDP memory.
    let c = decision.credentials
    var ok = freerdp_settings_set_string(s, FreeRDP_Username, c.username)
    ok = freerdp_settings_set_string(s, FreeRDP_Password, c.password) && ok
    if let domain = c.domain { ok = freerdp_settings_set_string(s, FreeRDP_Domain, domain) && ok }
    return ok ? 2 : 0
  }
}
