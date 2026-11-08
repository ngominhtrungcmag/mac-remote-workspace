import Darwin
import Dispatch
import Foundation

public enum SSHConnectionDiagnosticFailure: Sendable, Equatable {
  case invalidEndpoint
  case dnsResolutionFailed
  case tcpConnectionTimedOut
  case tcpConnectionRefused
  case tcpConnectionFailed
  case sshHandshakeFailed
}

public enum SSHConnectionDiagnosticStatus: Sendable, Equatable {
  case succeeded
  case failed(SSHConnectionDiagnosticFailure)
  case skipped
}

public struct SSHConnectionDiagnosticStage: Sendable, Equatable {
  public let status: SSHConnectionDiagnosticStatus
  public let durationMilliseconds: Int?

  public init(status: SSHConnectionDiagnosticStatus, durationMilliseconds: Int?) {
    self.status = status
    self.durationMilliseconds = durationMilliseconds
  }
}

public struct SSHConnectionDiagnosticReport: Sendable, Equatable {
  public let dnsResolution: SSHConnectionDiagnosticStage
  public let tcpConnection: SSHConnectionDiagnosticStage
  public let sshHandshake: SSHConnectionDiagnosticStage

  public init(
    dnsResolution: SSHConnectionDiagnosticStage,
    tcpConnection: SSHConnectionDiagnosticStage,
    sshHandshake: SSHConnectionDiagnosticStage
  ) {
    self.dnsResolution = dnsResolution
    self.tcpConnection = tcpConnection
    self.sshHandshake = sshHandshake
  }
}

/// Runs a pre-authentication SSH probe. The result contains timings and stage codes only.
public enum SSHConnectionDiagnosticProbe {
  private static let tcpTimeoutMilliseconds = 5_000
  private static let sshTimeoutSeconds = 5

  public static func run(host: String, port: Int) -> SSHConnectionDiagnosticReport {
    guard (1...65535).contains(port),
          (try? NativeSSHHostTrustService.validateEndpoint(host: host, port: port)) != nil else {
      return SSHConnectionDiagnosticReport(
        dnsResolution: .init(status: .failed(.invalidEndpoint), durationMilliseconds: 0),
        tcpConnection: .init(status: .skipped, durationMilliseconds: nil),
        sshHandshake: .init(status: .skipped, durationMilliseconds: nil)
      )
    }

    let dnsStarted = DispatchTime.now().uptimeNanoseconds
    var hints = addrinfo(
      ai_flags: 0,
      ai_family: AF_UNSPEC,
      ai_socktype: SOCK_STREAM,
      ai_protocol: IPPROTO_TCP,
      ai_addrlen: 0,
      ai_canonname: nil,
      ai_addr: nil,
      ai_next: nil
    )
    var addresses: UnsafeMutablePointer<addrinfo>?
    // shortcut: getaddrinfo is blocking and not cancellable; use an async resolver when a hard DNS timeout is needed.
    let resolution = getaddrinfo(host, String(port), &hints, &addresses)
    let dnsDuration = elapsedMilliseconds(since: dnsStarted)
    guard resolution == 0, let addresses else {
      return SSHConnectionDiagnosticReport(
        dnsResolution: .init(status: .failed(.dnsResolutionFailed), durationMilliseconds: dnsDuration),
        tcpConnection: .init(status: .skipped, durationMilliseconds: nil),
        sshHandshake: .init(status: .skipped, durationMilliseconds: nil)
      )
    }
    defer { freeaddrinfo(addresses) }

    let dnsStage = SSHConnectionDiagnosticStage(status: .succeeded, durationMilliseconds: dnsDuration)
    let tcpStarted = DispatchTime.now().uptimeNanoseconds
    guard let tcpFailure = connect(to: addresses, timeoutMilliseconds: tcpTimeoutMilliseconds) else {
      let tcpStage = SSHConnectionDiagnosticStage(
        status: .succeeded,
        durationMilliseconds: elapsedMilliseconds(since: tcpStarted)
      )
      return SSHConnectionDiagnosticReport(
        dnsResolution: dnsStage,
        tcpConnection: tcpStage,
        sshHandshake: probeSSHHandshake(host: host, port: port)
      )
    }

    return SSHConnectionDiagnosticReport(
      dnsResolution: dnsStage,
      tcpConnection: .init(
        status: .failed(tcpFailure),
        durationMilliseconds: elapsedMilliseconds(since: tcpStarted)
      ),
      sshHandshake: .init(status: .skipped, durationMilliseconds: nil)
    )
  }

  private static func probeSSHHandshake(host: String, port: Int) -> SSHConnectionDiagnosticStage {
    let started = DispatchTime.now().uptimeNanoseconds
    do {
      // shortcut: ssh-keyscan opens its own TCP connection; replace it if isolated key-exchange timing is required.
      let result = try NativeSSHHostTrustService.runSubprocess(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
        arguments: [
          "-t", "ed25519,ecdsa,rsa",
          "-T", String(sshTimeoutSeconds),
          "-p", String(port),
          host
        ],
        timeoutSeconds: TimeInterval(sshTimeoutSeconds + 5)
      )
      let hasHostKey = (String(data: result.stdout, encoding: .utf8) ?? "")
        .split(whereSeparator: \.isNewline)
        .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("#") }
      guard hasHostKey else {
        return .init(
          status: .failed(.sshHandshakeFailed),
          durationMilliseconds: elapsedMilliseconds(since: started)
        )
      }
      return .init(status: .succeeded, durationMilliseconds: elapsedMilliseconds(since: started))
    } catch {
      return .init(
        status: .failed(.sshHandshakeFailed),
        durationMilliseconds: elapsedMilliseconds(since: started)
      )
    }
  }

  private static func connect(
    to addresses: UnsafeMutablePointer<addrinfo>,
    timeoutMilliseconds: Int
  ) -> SSHConnectionDiagnosticFailure? {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
    var candidate: UnsafeMutablePointer<addrinfo>? = addresses
    var lastFailure: SSHConnectionDiagnosticFailure = .tcpConnectionFailed

    while let current = candidate {
      candidate = current.pointee.ai_next
      let outcome = connect(to: UnsafePointer(current), deadline: deadline)
      if outcome == nil { return nil }
      if let outcome { lastFailure = outcome }
      if DispatchTime.now().uptimeNanoseconds >= deadline { return .tcpConnectionTimedOut }
    }
    return lastFailure
  }

  private static func connect(
    to address: UnsafePointer<addrinfo>,
    deadline: UInt64
  ) -> SSHConnectionDiagnosticFailure? {
    guard let socketAddress = address.pointee.ai_addr else { return .tcpConnectionFailed }
    let descriptor = Darwin.socket(
      address.pointee.ai_family,
      address.pointee.ai_socktype,
      address.pointee.ai_protocol
    )
    guard descriptor >= 0 else { return .tcpConnectionFailed }
    defer { Darwin.close(descriptor) }

    let flags = fcntl(descriptor, F_GETFL, 0)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      return .tcpConnectionFailed
    }

    if Darwin.connect(descriptor, socketAddress, address.pointee.ai_addrlen) == 0 {
      return nil
    }
    guard errno == EINPROGRESS || errno == EWOULDBLOCK || errno == EALREADY else {
      return tcpFailure(for: errno)
    }

    while true {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline else { return .tcpConnectionTimedOut }
      let remainingMilliseconds = max(1, Int32(clamping: (deadline - now + 999_999) / 1_000_000))
      var descriptorState = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
      let pollResult = Darwin.poll(&descriptorState, 1, remainingMilliseconds)
      if pollResult == 0 { return .tcpConnectionTimedOut }
      if pollResult < 0 {
        if errno == EINTR { continue }
        return .tcpConnectionFailed
      }

      var socketError: Int32 = 0
      var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
      let socketOptionResult = withUnsafeMutablePointer(to: &socketError) {
        Darwin.getsockopt(descriptor, SOL_SOCKET, SO_ERROR, $0, &socketErrorLength)
      }
      guard socketOptionResult == 0 else { return .tcpConnectionFailed }
      return socketError == 0 ? nil : tcpFailure(for: socketError)
    }
  }

  private static func tcpFailure(for error: Int32) -> SSHConnectionDiagnosticFailure {
    switch error {
    case ETIMEDOUT: .tcpConnectionTimedOut
    case ECONNREFUSED: .tcpConnectionRefused
    default: .tcpConnectionFailed
    }
  }

  private static func elapsedMilliseconds(since start: UInt64) -> Int {
    Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
  }
}
