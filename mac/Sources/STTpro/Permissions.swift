import AppKit
import AVFoundation
import STTproCore

/// Microphone (to record) and Accessibility (to send ⌘V) permissions.
@MainActor
enum Permissions {
    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    static var microphoneGranted: Bool { microphone == .authorized }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "com.sttpro.mac" }

    /// True when this build is ad-hoc signed — macOS then forgets grants on every rebuild.
    static var isAdHocSigned: Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        return (dict[kSecCodeInfoCertificates as String] as? [Any])?.isEmpty ?? true
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Shows the system "STTpro would like to control this computer" prompt,
    /// which adds STTpro to System Settings › Privacy & Security › Accessibility.
    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Clears STTpro's own stale entry (e.g. left over from an older build whose
    /// signature no longer matches), then asks again. Only affects this app.
    static func resetAndRequest(_ service: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, bundleIdentifier]
        do {
            try task.run()
            task.waitUntilExit()
            Log.info("tccutil reset \(service) exited \(task.terminationStatus)")
        } catch {
            Log.error("tccutil reset \(service) failed", error)
        }
        if service == "Accessibility" {
            promptAccessibility()
            openAccessibilitySettings()
        } else {
            Task { _ = await requestMicrophone() }
        }
    }

    /// Quits and reopens STTpro (some permission changes only apply to a fresh process).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", path]
        try? task.run()
        NSApp.terminate(nil)
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openKeyboardShortcutsSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
