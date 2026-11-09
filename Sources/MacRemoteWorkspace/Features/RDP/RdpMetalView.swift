import AppCore
import Metal
import QuartzCore
import SwiftUI

/// NSViewRepresentable wrapping CAMetalLayer for native RDP display and input.
public struct RdpMetalView: NSViewRepresentable {
  let renderer: RdpMetalRenderer
  let options: RdpConnectionOptions
  let frameRevision: UInt64
  let isViewOnly: Bool
  let onResize: (RdpDisplayResolution) -> Void
  let onKeyEvent: (RdpKeyboardEvent) -> Void
  let onPointerEvent: (UInt16, UInt16, UInt16) -> Void
  let onClipboardFocus: (Bool) -> Void
  let onHostViewReady: ((RdpMetalHostingView) -> Void)?

  public init(
    renderer: RdpMetalRenderer,
    frameRevision: UInt64 = 0,
    options: RdpConnectionOptions = RdpConnectionOptions(),
    isViewOnly: Bool = false,
    onResize: @escaping (RdpDisplayResolution) -> Void,
    onKeyEvent: @escaping (RdpKeyboardEvent) -> Void,
    onPointerEvent: @escaping (UInt16, UInt16, UInt16) -> Void,
    onClipboardFocus: @escaping (Bool) -> Void = { _ in },
    onHostViewReady: ((RdpMetalHostingView) -> Void)? = nil
  ) {
    self.options = options
    self.renderer = renderer
    self.frameRevision = frameRevision
    self.isViewOnly = isViewOnly
    self.onResize = onResize
    self.onKeyEvent = onKeyEvent
    self.onPointerEvent = onPointerEvent
    self.onClipboardFocus = onClipboardFocus
    self.onHostViewReady = onHostViewReady
  }

  public func makeNSView(context: Context) -> RdpMetalHostingView {
    let view = RdpMetalHostingView(renderer: renderer, options: options)
    view.onResize = onResize
    view.onKeyEvent = onKeyEvent
    view.onPointerEvent = onPointerEvent
    view.onClipboardFocus = onClipboardFocus
    view.setViewOnly(isViewOnly)
    onHostViewReady?(view)
    return view
  }

  public func updateNSView(_ nsView: RdpMetalHostingView, context: Context) {
    nsView.onResize = onResize
    nsView.onKeyEvent = onKeyEvent
    nsView.onPointerEvent = onPointerEvent
    nsView.onClipboardFocus = onClipboardFocus
    onHostViewReady?(nsView)
    nsView.setViewOnly(isViewOnly)
    nsView.updateClipboardFocus()
    nsView.renderFrame(revision: frameRevision)
  }
}

/// AppKit view owning the CAMetalLayer and mapping local input to remote pixels.
public final class RdpMetalHostingView: NSView {
  private let options: RdpConnectionOptions
  private let renderer: RdpMetalRenderer
  private var metalLayer: CAMetalLayer?
  private let debouncer = RdpDisplayDebouncer()
  private var lastRenderedRevision: UInt64?
  private var trackingArea: NSTrackingArea?
  nonisolated(unsafe) private var windowObserver: NSObjectProtocol?
  nonisolated(unsafe) private var windowKeyObserver: NSObjectProtocol?
  private var keyboardInput = RdpKeyboardInput()
  private var pressedButtons: Set<UInt16> = []
  private var lastRemotePoint: (x: UInt16, y: UInt16) = (0, 0)
  public private(set) var isViewOnly = false

  var onClipboardFocus: ((Bool) -> Void)?
  var onResize: ((RdpDisplayResolution) -> Void)?
  var onKeyEvent: ((RdpKeyboardEvent) -> Void)?
  var onPointerEvent: ((UInt16, UInt16, UInt16) -> Void)?

  private let pointerButtonPairs: [(down: UInt16, up: UInt16)] = [(0x01, 0x02), (0x04, 0x08), (0x09, 0x0A)]

  public init(renderer: RdpMetalRenderer, options: RdpConnectionOptions = RdpConnectionOptions()) {
    self.options = options
    self.renderer = renderer
    super.init(frame: .zero)
    wantsLayer = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    if let windowKeyObserver { NotificationCenter.default.removeObserver(windowKeyObserver) }
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
  }

  /// Applies view-only mode. When transitioning into view-only, any held local keys/buttons
  /// are released first through the existing release path before local input is suppressed.
  public func setViewOnly(_ viewOnly: Bool) {
    guard isViewOnly != viewOnly else { return }
    if viewOnly {
      releasePressedInput()
      isViewOnly = true
      onClipboardFocus?(false)
    } else {
      isViewOnly = false
      updateClipboardFocus()
    }
  }

  func updateClipboardFocus() {
    let focused = !isViewOnly && window?.isKeyWindow == true && window?.firstResponder === self
    onClipboardFocus?(focused)
  }

  public override func makeBackingLayer() -> CALayer {
    let layer = CAMetalLayer()
    layer.device = renderer.device
    layer.pixelFormat = .bgra8Unorm
    layer.framebufferOnly = false
    layer.displaySyncEnabled = true
    layer.contentsScale = window?.backingScaleFactor ?? 2
    metalLayer = layer
    return layer
  }

  public override var acceptsFirstResponder: Bool { true }

  public override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if let windowKeyObserver { NotificationCenter.default.removeObserver(windowKeyObserver) }
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
    windowObserver = nil
    windowKeyObserver = nil
    onClipboardFocus?(false)
    if let window {
      windowKeyObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.updateClipboardFocus()
        }
      }
      window.acceptsMouseMovedEvents = true
      window.makeFirstResponder(self)
      windowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification, object: window, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in
          self?.onClipboardFocus?(false)
          self?.releasePressedInput()
        }
      }
    }
    updateDrawableSize()
    triggerResize()
    if let revision = lastRenderedRevision { renderFrame(revision: revision) }
  }

  public override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    updateDrawableSize()
    triggerResize()
  }

  public override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingArea = area
  }

  public override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateDrawableSize()
    triggerResize()
  }

  public override func layout() {
    super.layout()
    updateDrawableSize()
  }

  public override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { updateClipboardFocus() }
    return accepted
  }

  public override func resignFirstResponder() -> Bool {
    onClipboardFocus?(false)
    releasePressedInput()
    return super.resignFirstResponder()
  }

  private func updateDrawableSize() {
    guard let metalLayer else { return }
    let scale = window?.backingScaleFactor ?? 2
    metalLayer.contentsScale = scale
    metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
  }

  private func triggerResize() {
    guard bounds.width > 0, bounds.height > 0 else { return }
    let resolution = options.resolution(
      pointWidth: Double(bounds.width),
      pointHeight: Double(bounds.height),
      backingScaleFactor: Double(window?.backingScaleFactor ?? 2)
    )
    debouncer.scheduleUpdate(to: resolution) { [weak self] settled in
      Task { @MainActor in self?.onResize?(settled) }
    }
  }

  func renderFrame(revision: UInt64) {
    guard lastRenderedRevision != revision else { return }
    lastRenderedRevision = revision
    guard let metalLayer else { return }
    _ = renderer.render(to: metalLayer)
  }

  // MARK: - Keyboard Input

  public override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard !isViewOnly, window?.firstResponder === self, event.type == .keyDown,
      event.modifierFlags.contains(.command),
      RdpKeyboardInput.isCommandShortcut(event.keyCode)
    else { return super.performKeyEquivalent(with: event) }
    keyDown(with: event)
    return true
  }

  public override func keyDown(with event: NSEvent) {
    guard !isViewOnly else { return }
    guard RdpScancodeMapper.mapMacKeyCode(event.keyCode) != nil else {
      super.keyDown(with: event)
      return
    }
    for mapped in keyboardInput.keyDown(event.keyCode) { onKeyEvent?(mapped) }
  }

  public override func keyUp(with event: NSEvent) {
    guard !isViewOnly else { return }
    for mapped in keyboardInput.keyUp(event.keyCode) { onKeyEvent?(mapped) }
  }

  public override func flagsChanged(with event: NSEvent) {
    guard !isViewOnly else { return }
    if event.keyCode == 0x39, let down = RdpScancodeMapper.mapMacKeyCode(0x39) {
      onKeyEvent?(down)
      onKeyEvent?(RdpKeyboardEvent(scancode: down.scancode, isExtended: down.isExtended, isKeyUp: true))
      return
    }
    guard [0x37, 0x36, 0x38, 0x3C, 0x3A, 0x3D, 0x3B, 0x3E].contains(event.keyCode) else {
      super.flagsChanged(with: event)
      return
    }
    for mapped in keyboardInput.modifierChanged(event.keyCode) { onKeyEvent?(mapped) }
  }

  /// Releases any held keyboard keys/modifiers and mouse buttons via the existing release path.
  public func releasePressedInput() {
    for mapped in keyboardInput.releaseAll() { onKeyEvent?(mapped) }
    for (down, up) in pointerButtonPairs where pressedButtons.contains(down) {
      onPointerEvent?(lastRemotePoint.x, lastRemotePoint.y, up)
    }
    pressedButtons.removeAll()
  }

  // MARK: - Pointer Input

  public override func mouseDown(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0x01) }
  public override func mouseUp(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0x02) }
  public override func rightMouseDown(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0x04) }
  public override func rightMouseUp(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0x08) }
  public override func otherMouseDown(with event: NSEvent) {
    if event.buttonNumber == 2 { forwardPointer(event: event, buttonFlag: 0x09) }
    else { super.otherMouseDown(with: event) }
  }
  public override func otherMouseUp(with event: NSEvent) {
    if event.buttonNumber == 2 { forwardPointer(event: event, buttonFlag: 0x0A) }
    else { super.otherMouseUp(with: event) }
  }
  public override func mouseMoved(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0) }
  public override func mouseDragged(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0) }
  public override func rightMouseDragged(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0) }
  public override func otherMouseDragged(with event: NSEvent) { forwardPointer(event: event, buttonFlag: 0) }

  public override func scrollWheel(with event: NSEvent) {
    guard !isViewOnly else { return }
    guard let point = remotePoint(event: event, clampToImage: false) else { return }
    let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
    let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 10
    let flags: UInt16
    if abs(deltaY) >= abs(deltaX), deltaY != 0 {
      flags = deltaY > 0 ? 0x10 : 0x20
    } else if deltaX != 0 {
      flags = deltaX > 0 ? 0x40 : 0x80
    } else {
      return
    }
    lastRemotePoint = (point.x, point.y)
    onPointerEvent?(point.x, point.y, flags)
  }

  private func forwardPointer(event: NSEvent, buttonFlag: UInt16) {
    guard !isViewOnly else { return }
    if let pair = pointerButtonPairs.first(where: { $0.down == buttonFlag }) {
      guard let point = remotePoint(event: event, clampToImage: false) else { return }
      pressedButtons.insert(pair.down)
      lastRemotePoint = (point.x, point.y)
      onPointerEvent?(point.x, point.y, buttonFlag)
      return
    }
    if let pair = pointerButtonPairs.first(where: { $0.up == buttonFlag }) {
      guard pressedButtons.contains(pair.down),
        let point = remotePoint(event: event, clampToImage: true)
      else { return }
      pressedButtons.remove(pair.down)
      lastRemotePoint = (point.x, point.y)
      onPointerEvent?(point.x, point.y, buttonFlag)
      return
    }
    guard let point = remotePoint(event: event, clampToImage: false) else { return }
    lastRemotePoint = (point.x, point.y)
    onPointerEvent?(point.x, point.y, buttonFlag)
  }

  private func remotePoint(event: NSEvent, clampToImage: Bool) -> RdpRemotePixel? {
    guard let frame = renderer.currentFrameSize else { return nil }
    let location = convert(event.locationInWindow, from: nil)
    return RdpDisplayGeometry.remotePixel(
      atX: location.x, y: location.y,
      remoteWidth: frame.width, remoteHeight: frame.height,
      viewWidth: bounds.width, viewHeight: bounds.height, clampToImage: clampToImage)
  }
}

// Preview omitted: RdpMetalView requires a live RDP session.
