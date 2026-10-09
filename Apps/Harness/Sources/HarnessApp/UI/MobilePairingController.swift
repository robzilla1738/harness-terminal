import AppKit
import CoreImage
import HarnessCore
import HarnessRemoteProtocol
import Network

/// Credential-free pairing: a reachable address and trusted SSH fingerprint, presented
/// together. The phone still authenticates and explicitly installs its own device key.
@MainActor
final class MobilePairingController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static let shared = MobilePairingController()
    private let hostField = NSTextField(string: "")
    private let addresses = NSPopUpButton()
    private let portField = NSTextField(string: "22")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let fingerprint = NSTextField(wrappingLabelWithString: "")
    private let qr = NSImageView()
    private let generate = NSButton(title: "Update Code", target: nil, action: nil)
    private let copy = NSButton(title: "Copy Connection", target: nil, action: nil)
    private var metadata: Data?
    private var task: Task<Void, Never>?
    private var probe: NWConnection?

    private init() {
        let height = min(780, (NSScreen.main?.visibleFrame.height ?? 820) - 48)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect a Phone or iPad"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let heading = NSTextField(labelWithString: "Your work, within reach.")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: "Open Harness on your phone and tap Scan QR code. Enter your Mac password once to set up a device key; future connections use the key automatically.")
        explanation.textColor = .secondaryLabelColor
        hostField.placeholderString = "Mac address or Tailscale name"
        hostField.setAccessibilityLabel("Reachable Mac address")
        hostField.delegate = self; portField.delegate = self
        addresses.setAccessibilityLabel("Connection network")
        addresses.target = self; addresses.action = #selector(selectAddress)
        portField.setAccessibilityLabel("SSH port")
        let hostRow = NSStackView(views: [NSTextField(labelWithString: "Address"), hostField, NSTextField(labelWithString: "Port"), portField])
        hostRow.spacing = 10
        portField.widthAnchor.constraint(equalToConstant: 58).isActive = true
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        qr.imageScaling = .scaleNone
        qr.setAccessibilityLabel("Connection metadata QR code")
        qr.widthAnchor.constraint(equalToConstant: 280).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 280).isActive = true
        fingerprint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        fingerprint.isSelectable = true
        fingerprint.alignment = .center
        status.alignment = .center
        status.textColor = .secondaryLabelColor
        generate.target = self; generate.action = #selector(updateCode)
        copy.target = self; copy.action = #selector(copyConnection)
        copy.isEnabled = false
        let settings = NSButton(title: "Remote Login Settings…", target: self, action: #selector(openRemoteLogin))
        let actions = NSStackView(views: [settings, generate, copy])
        actions.spacing = 10
        let note = NSTextField(wrappingLabelWithString: "This code contains no password or private key. Your phone verifies the host fingerprint before connecting.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [heading, explanation, addresses, hostRow, qr, fingerprint, status, actions, note])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = PairingDocumentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        window.contentView = scroll
        NSLayoutConstraint.activate([
            content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 26),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -26),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fingerprint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            status.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.center()
    }
    required init?(coder: NSCoder) { nil }

    func present() {
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        do {
            let available = try MobileConnectionAddress.available()
            addresses.removeAllItems()
            for address in available {
                addresses.addItem(withTitle: address.title)
                addresses.lastItem?.representedObject = address.host
            }
            addresses.isHidden = available.isEmpty
            if hostField.stringValue.isEmpty { hostField.stringValue = available.first?.host ?? "" }
            if let item = addresses.itemArray.first(where: { $0.representedObject as? String == hostField.stringValue }) { addresses.select(item) }
            updateCode()
        } catch { status.stringValue = "Could not discover network addresses. Enter your Mac's address and choose Update Code." }
    }

    @objc private func selectAddress() {
        guard let address = addresses.selectedItem?.representedObject as? String else { return }
        hostField.stringValue = address
        updateCode()
    }

    func controlTextDidChange(_ notification: Notification) {
        task?.cancel(); probe?.cancel(); probe = nil
        metadata = nil; qr.image = nil; fingerprint.stringValue = ""; copy.isEnabled = false; generate.isEnabled = true
        status.stringValue = "Choose Update Code to use this address and port."
    }
    func windowWillClose(_ notification: Notification) { task?.cancel(); probe?.cancel(); probe = nil }

    @objc private func updateCode() {
        task?.cancel(); probe?.cancel(); probe = nil
        metadata = nil; qr.image = nil; fingerprint.stringValue = ""; copy.isEnabled = false; generate.isEnabled = true
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.contains(where: \.isWhitespace), let port = Int(portField.stringValue), (1...65535).contains(port) else {
            status.stringValue = "Enter a reachable address and a valid SSH port."
            return
        }
        guard let executable = HarnessCLILocator.url() else { status.stringValue = "Install the Harness CLI, then try again."; return }
        generate.isEnabled = false
        status.stringValue = "Preparing your connection…"
        task = Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try Self.loadMetadata(executable: executable, host: host, port: port)
                }.value
                try Task.checkCancellation()
                guard let self else { return }
                let info = try JSONDecoder().decode(RemotePairingInfo.self, from: data)
                let code = Data(try info.connectionURL().absoluteString.utf8)
                self.metadata = code
                self.qr.image = self.qrImage(code)
                self.fingerprint.stringValue = "SSH host key\n\(info.fingerprint)"
                self.copy.isEnabled = true
                self.generate.isEnabled = true
                self.status.stringValue = "Checking Remote Login…"
                self.checkRemoteLogin(port: port)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.generate.isEnabled = true
                self.status.stringValue = error.localizedDescription
            }
        }
    }
    @objc private func copyConnection() {
        guard let metadata, let text = String(data: metadata, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        status.stringValue = "Connection copied. Choose Paste connection link on your phone."
    }
    @objc private func openRemoteLogin() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sharing-Settings.extension") { NSWorkspace.shared.open(url) }
    }
    private func qrImage(_ data: Data) -> NSImage? {
        let filter = CIFilter(name: "CIQRCodeGenerator")
        filter?.setValue(data, forKey: "inputMessage")
        filter?.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter?.outputImage else { return nil }
        let bordered = image.composited(over: CIImage(color: .white).cropped(to: image.extent.insetBy(dx: -4, dy: -4)))
        let scale = max(1, floor(280 / bordered.extent.width))
        let scaled = bordered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
    private func checkRemoteLogin(port: Int) {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let connection = NWConnection(host: "127.0.0.1", port: endpointPort, using: .tcp)
        probe = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated {
                guard let self, let connection, self.probe === connection else { return }
                switch state {
                case .ready:
                    self.status.stringValue = "SSH is reachable on this Mac. Scan the code to connect."
                    connection.cancel(); self.probe = nil
                case .failed:
                    self.status.stringValue = "Enable Remote Login in System Settings → General → Sharing."
                    connection.cancel(); self.probe = nil
                default: break
                }
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak connection] in
            guard let self, let connection, self.probe === connection else { return }
            connection.cancel(); self.probe = nil
            self.status.stringValue = "Enable Remote Login in System Settings → General → Sharing."
        }
    }
    nonisolated private static func loadMetadata(executable: URL, host: String, port: Int) throws -> Data {
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = executable
        process.arguments = ["mobile-setup", "--json", "--host", host, "--port", String(port)]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "MobilePairing", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: message.isEmpty ? "Could not prepare this Mac’s connection." : message])
        }
        return data
    }
}

private final class PairingDocumentView: NSView {
    override var isFlipped: Bool { true }
}
