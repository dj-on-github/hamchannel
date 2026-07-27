import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Native Bluetooth Classic (RFCOMM) handler for the Bluetooth-radio
    // audio backend (code from HTCommander, Apache-2.0, Ylian Saint-Hilaire).
    BluetoothClassicHandler.register(
      with: flutterViewController.registrar(forPlugin: "BluetoothClassicHandler"))

    super.awakeFromNib()
  }
}
