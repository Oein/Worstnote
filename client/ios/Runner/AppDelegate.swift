import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private static let lockMethodChannel = "notee/lock"
  private static let lockEventChannel  = "notee/lock_events"

  private var eventSink: FlutterEventSink?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    setupLockChannels(messenger: engineBridge.binaryMessenger)
  }

  private func setupLockChannels(messenger: FlutterBinaryMessenger) {
    // Method channel: Dart → Native (send IPC messages via Darwin notifications).
    FlutterMethodChannel(name: AppDelegate.lockMethodChannel, binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard let self = self else { return }
        switch call.method {
        case "sendHandoffRequest", "sendHandoffAck":
          guard
            let args   = call.arguments as? [String: Any],
            let target = args["targetSession"] as? String,
            let source = args["sourceSession"] as? String,
            let noteId = args["noteId"] as? String
          else { result(FlutterError(code: "BAD_ARGS", message: nil, details: nil)); return }

          let type = call.method == "sendHandoffRequest" ? "handoffRequest" : "handoffAck"
          // On iOS multiple windows share a process — post directly to eventSink.
          self.eventSink?(["type": type, "target": target, "source": source, "noteId": noteId])
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

    // Event channel: Native → Dart.
    FlutterEventChannel(name: AppDelegate.lockEventChannel, binaryMessenger: messenger)
      .setStreamHandler(self)
  }
}

extension AppDelegate: FlutterStreamHandler {
  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }
}
