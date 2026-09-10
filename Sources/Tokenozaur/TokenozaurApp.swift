import AppKit
import Combine
import SwiftUI

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
  private static var retainedDelegate: AppDelegate?
  private var statusItem: NSStatusItem?
  private let popover = NSPopover()
  private var model: AppModel?
  private var modelUpdates: AnyCancellable?
  private var eatingTimer: Timer?
  private var eatingStepsRemaining = 0
  private var mouthOpen = false
  private var lastObservedTokenTotal: Int64?
  private var didSetUpApplication = false

  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    retainedDelegate = delegate
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    delegate.setUpApplication()
    application.run()
    retainedDelegate = nil
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    setUpApplication()
  }

  private func setUpApplication() {
    guard !didSetUpApplication else { return }
    didSetUpApplication = true
    installStatusItem()

    let model = AppModel()
    self.model = model
    installPopover(model: model)
    observeModel(model)
    updateTooltip()
  }

  private func installStatusItem() {
    let item = NSStatusBar.system.statusItem(withLength: 36)
    item.isVisible = true

    if let button = item.button {
      button.image = DinosaurStatusIcon.image(mouthOpen: false)
      button.imagePosition = .imageOnly
      button.imageScaling = .scaleProportionallyDown
      button.setAccessibilityLabel("Tokenozaur alpha")
      button.toolTip = "Tokenozaur alpha"
      button.target = self
      button.action = #selector(togglePopover(_:))
    }

    statusItem = item
  }

  private func installPopover(model: AppModel) {
    let content = MenuContentView()
      .environmentObject(model)
      .frame(width: 390)

    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentSize = NSSize(width: 390, height: 640)
    popover.contentViewController = NSHostingController(rootView: content)
  }

  private func observeModel(_ model: AppModel) {
    modelUpdates = model.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async {
        self?.updateTooltip()
      }
    }
  }

  private func updateTooltip() {
    guard let model else { return }
    statusItem?.button?.toolTip = "Tokenozaur alpha · \(model.menuBarTitle)"
    let tokenTotal = model.monitoredSessions.reduce(Int64(0)) {
      $0 + $1.currentActivity.totalUsage.total
    }
    if let lastObservedTokenTotal, tokenTotal > lastObservedTokenTotal {
      animateEating()
    }
    self.lastObservedTokenTotal = tokenTotal
  }

  private func animateEating() {
    eatingTimer?.invalidate()
    eatingStepsRemaining = 8
    mouthOpen = true
    updateDinosaurFrame()

    let timer = Timer(
      timeInterval: 0.14,
      target: self,
      selector: #selector(advanceEatingAnimation(_:)),
      userInfo: nil,
      repeats: true
    )
    eatingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func advanceEatingAnimation(_ timer: Timer) {
    eatingStepsRemaining -= 1
    if eatingStepsRemaining <= 0 {
      timer.invalidate()
      eatingTimer = nil
      mouthOpen = false
    } else {
      mouthOpen.toggle()
    }
    updateDinosaurFrame()
  }

  private func updateDinosaurFrame() {
    statusItem?.button?.image = DinosaurStatusIcon.image(mouthOpen: mouthOpen)
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }

    if popover.isShown {
      popover.performClose(sender)
    } else {
      model?.setPopoverVisible(true)
      popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
      NSApp.activate(ignoringOtherApps: true)
    }
  }

  func popoverDidClose(_ notification: Notification) {
    model?.setPopoverVisible(false)
  }
}
