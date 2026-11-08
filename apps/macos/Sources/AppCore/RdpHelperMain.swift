import Darwin
import Foundation

/// Entry point of the `RdpSessionHelper` executable: runs FreeRDP out of process so a FreeRDP
/// crash cannot take the app down. The socket arrives as stdin; stdio is then pointed at /dev/null
/// so nothing (logs included) can leak. Exits on socket EOF, i.e. when the parent dies.
public enum RdpHelperMain {
  public static func run() -> Never {
    signal(SIGPIPE, SIG_IGN)
    if getenv("HOME") == nil {
      setenv("HOME", NSHomeDirectory(), 1)
    }
    if getenv("TMPDIR") == nil {
      setenv("TMPDIR", NSTemporaryDirectory(), 1)
    }
    let ctrl = dup(0)
    let null = open("/dev/null", O_RDWR)
    if null >= 0 { for fd in [0, 1, 2] as [Int32] { dup2(null, fd) } }
    guard ctrl >= 0 else { exit(2) }
    let channel = RdpHelperChannel(fd: ctrl)

    guard case .start(let host, let port, let w, let h, let scale, let clipboardDirectory)? = try? channel.receive() else { exit(2) }

    let decisionLock = NSLock()
    let decisionReady = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var decision: RdpHelperMessage?

    let client = FreeRdpClient(
      host: host, port: port, resolution: RdpDisplayResolution(width: w, height: h, scaleFactor: scale),
      clipboardDirectory: clipboardDirectory.map { URL(fileURLWithPath: $0) },
      callbacks: .init(
        verifyCertificate: { cert, changed in
          channel.send(
            .certificate(
              host: cert.host, port: cert.port, sha256: cert.sha256Fingerprint,
              subjectCN: cert.subjectCN, issuerCN: cert.issuerCN, changed: changed))
          decisionReady.wait()
          decisionLock.lock()
          defer { decisionLock.unlock() }
          guard case .trustDecision(true, let user?, let domain, let password?)? = decision else { return nil }
          return RdpTrustDecision(credentials: RdpResolvedCredentials(username: user, domain: domain, password: password))
        },
        onConnected: { channel.send(.connected) },
        onFrame: { frame in
          channel.send(.frame(width: frame.width, height: frame.height, bytesPerRow: frame.bytesPerRow, data: frame.data))
        },
        onEnded: { code, message, connected in
          channel.send(.ended(code: code, message: message, connected: connected))
          exit(0)
        },
        onClipboardStatus: { message, busy in channel.send(.clipboardStatus(message: message, busy: busy)) }))
    client.start()

    while true {
      guard let message = try? channel.receive() else {  // EOF/malformed: parent gone
        client.abort()
        exit(0)
      }
      switch message {
      case .trustDecision:
        decisionLock.lock()
        decision = message
        decisionLock.unlock()
        decisionReady.signal()
      case .key(let code, let ext, let up):
        client.sendKey(RdpKeyboardEvent(scancode: code, isExtended: ext, isKeyUp: up))
      case .pointer(let x, let y, let flags):
        client.sendPointer(x: x, y: y, buttonFlags: flags)
      case .resize(let w, let h, let s):
        client.resize(RdpDisplayResolution(width: w, height: h, scaleFactor: s))
      case .cancelClipboardFiles:
        client.cancelClipboardFiles()
      case .clipboardActive(let active):
        client.setClipboardActive(active)
      case .abort:
        decisionReady.signal()  // unblock a pending trust wait (decision stays nil = reject)
        client.abort()
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { _exit(0) }
      default:
        break
      }
    }
  }
}
