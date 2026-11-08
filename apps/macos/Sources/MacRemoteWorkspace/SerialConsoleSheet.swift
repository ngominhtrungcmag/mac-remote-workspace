import AppCore
import SwiftUI

@MainActor
final class SerialConsoleViewModel: ObservableObject {
  @Published private(set) var ports: [String] = []
  @Published private(set) var output = ""
  @Published private(set) var isOpen = false
  @Published private(set) var errorMessage: String?
  @Published var config = SerialConfig(path: "")
  @Published var input = ""

  private var session: SerialSession?
  private let buffer = SSHOutputBuffer(capacity: 64 * 1024)
  private static let maxOutputChars = 64 * 1024

  func refresh() {
    ports = SerialPortEnumerator.availablePorts()
    if config.path.isEmpty || !ports.contains(config.path) { config.path = ports.first ?? "" }
  }

  func open() {
    close()
    errorMessage = nil
    let buffer = buffer
    buffer.reset()
    do {
      session = try SerialSession.open(
        config,
        onData: { [weak self] data in
          buffer.append(data)
          Task { @MainActor in self?.drain() }
        },
        onClose: { [weak self] in
          Task { @MainActor in
            self?.errorMessage = AppLocalization.string("Port disconnected.")
            self?.close()
          }
        })
      isOpen = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func close() {
    session?.close()
    session = nil
    isOpen = false
  }

  func send() {
    guard let session, !input.isEmpty else { return }
    do {
      try session.write(Data((input + "\r").utf8))
      input = ""
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func drain() {
    output += buffer.drainDecodableString()
    if output.count > Self.maxOutputChars { output = String(output.suffix(Self.maxOutputChars)) }
  }
}

struct SerialConsoleSheet: View {
  @Environment(\.dismiss) private var dismiss
  @StateObject private var model = SerialConsoleViewModel()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Label(AppLocalization.string("Serial Console"), systemImage: "cable.connector").font(.title2).bold()
        .accessibilityAddTraits(.isHeader)
      HStack {
        Picker(AppLocalization.string("Port"), selection: $model.config.path) {
          if model.ports.isEmpty { Text(AppLocalization.string("No /dev/cu.* ports")).tag("") }
          ForEach(model.ports, id: \.self) { Text($0).tag($0) }
        }
        Button(AppLocalization.string("Refresh")) { model.refresh() }.disabled(model.isOpen)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)], alignment: .leading, spacing: 12) {
        Picker(AppLocalization.string("Baud"), selection: $model.config.baudRate) {
          ForEach(SerialConfig.standardBaudRates, id: \.self) { Text(String($0)).tag($0) }
        }
        Picker(AppLocalization.string("Data"), selection: $model.config.dataBits) {
          ForEach(5...8, id: \.self) { Text(String($0)).tag($0) }
        }
        Picker(AppLocalization.string("Parity"), selection: $model.config.parity) {
          ForEach(SerialParity.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
        Picker(AppLocalization.string("Stop"), selection: $model.config.stopBits) {
          ForEach(1...2, id: \.self) { Text(String($0)).tag($0) }
        }
        Picker(AppLocalization.string("Flow"), selection: $model.config.flowControl) {
          ForEach(SerialFlowControl.allCases, id: \.self) { Text($0.localizedTitle).tag($0) }
        }
      }
      .disabled(model.isOpen)

      if let error = model.errorMessage {
        Text(error).font(.caption).foregroundStyle(.red)
      }

      ScrollView {
        Text(model.output.isEmpty ? AppLocalization.string("No output yet.") : model.output)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .topLeading)
          .padding(8)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .frame(minHeight: 220)

      HStack {
        TextField(AppLocalization.string("Send (CR appended)…"), text: $model.input)
          .font(.system(.body, design: .monospaced))
          .disabled(!model.isOpen)
          .onSubmit { model.send() }
          .accessibilityLabel(AppLocalization.string("Serial input"))
        Button(AppLocalization.string("Send")) { model.send() }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(!model.isOpen || model.input.isEmpty)
      }
      HStack {
        if model.isOpen {
          Button(AppLocalization.string("Disconnect")) { model.close() }
        } else {
          Button(AppLocalization.string("Connect")) { model.open() }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(model.config.path.isEmpty)
        }
        Spacer()
        Button(AppLocalization.string("Close")) { model.close(); dismiss() }
      }
    }
    .padding()
    .frame(minWidth: 560, idealWidth: 720, minHeight: 520)
    .onAppear { model.refresh() }
    .onDisappear { model.close() }
  }
}

private extension SerialParity {
  var localizedTitle: String {
    switch self {
    case .none: AppLocalization.string("None")
    case .even: AppLocalization.string("Even")
    case .odd: AppLocalization.string("Odd")
    }
  }
}

private extension SerialFlowControl {
  var localizedTitle: String {
    switch self {
    case .none: AppLocalization.string("None")
    case .rtsCts: AppLocalization.string("RTS/CTS")
    case .xonXoff: AppLocalization.string("XON/XOFF")
    }
  }
}
