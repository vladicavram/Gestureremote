import Foundation
import UIKit
import CoreVideo
import CoreGraphics
import Combine

/// Connects to an MJPEG stream from a local network IP camera,
/// decodes frames, and publishes them for display and gesture processing.
final class IPCameraManager: NSObject, ObservableObject, URLSessionDataDelegate {

    @Published var currentFrame: UIImage?
    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var errorMessage: String?

    /// Publishes decoded CVPixelBuffers suitable for feeding into GestureProcessor.
    let framePublisher = PassthroughSubject<CVPixelBuffer, Never>()

    private var urlSession: URLSession?
    private var dataTask: URLSessionDataTask?
    /// receiveBuffer and boundaryMarker are only ever accessed on sessionQueue.
    private var receiveBuffer = Data()
    private var boundaryMarker: Data?   // "--<boundary>" as UTF-8 bytes

    /// Reconnect state — only touched on the main thread.
    private var currentURL: String = ""
    private var shouldReconnect = false
    private var reconnectAttempt = 0
    private var reconnectWork: DispatchWorkItem?
    /// Tracks the active session so stale delegate callbacks from an old session are ignored.
    private var activeSession: URLSession?

    /// Serial background queue used as URLSession delegateQueue.
    /// Keeps data delivery off the main thread so the TCP buffer drains fast.
    private let sessionQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "com.gestureremote.ipcamera.session"
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInteractive
        return q
    }()

    private let jpegSOI = Data([0xFF, 0xD8])
    private let jpegEOI = Data([0xFF, 0xD9])

    // MARK: - Public API

    func connect(to urlString: String) {
        reconnectWork?.cancel(); reconnectWork = nil
        shouldReconnect = true
        reconnectAttempt = 0
        currentURL = urlString
        startStream(urlString: urlString)
    }

    private func startStream(urlString: String) {
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        activeSession = nil
        receiveBuffer = Data()
        boundaryMarker = nil

        let trimmed = urlString.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil else {
            errorMessage = "Invalid URL"
            return
        }

        isConnecting = true

        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = .infinity
        // Use the dedicated background serial queue — never block the main thread
        // while draining the TCP receive buffer.
        let session = URLSession(configuration: config, delegate: self, delegateQueue: sessionQueue)
        urlSession = session
        activeSession = session

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }

    func disconnect() {
        shouldReconnect = false
        reconnectWork?.cancel(); reconnectWork = nil
        reconnectAttempt = 0
        dataTask?.cancel()
        dataTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        activeSession = nil
        receiveBuffer = Data()
        boundaryMarker = nil
        isConnected = false
        isConnecting = false
        currentFrame = nil
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            DispatchQueue.main.async {
                self.isConnecting = false
                self.errorMessage = "Server returned HTTP \(code)"
            }
            completionHandler(.cancel)
            return
        }

        // Try to extract multipart boundary from Content-Type header.
        // e.g. "multipart/x-mixed-replace; boundary=--myboundary"
        if let ct = http.value(forHTTPHeaderField: "Content-Type") {
            boundaryMarker = extractBoundaryData(from: ct)
        }

        DispatchQueue.main.async {
            self.isConnected = true
            self.isConnecting = false
            self.errorMessage = nil
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receiveBuffer.append(data)
        parseBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cancelled = (error as? NSError)?.code == NSURLErrorCancelled
        DispatchQueue.main.async {
            self.isConnected = false
            self.isConnecting = false
            if let error, !cancelled {
                self.errorMessage = error.localizedDescription
            }
        }
        guard !cancelled, shouldReconnect else { return }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        // Exponential backoff: 2s, 4s, 8s, 16s, 30s cap
        let delay = min(30.0, pow(2.0, Double(reconnectAttempt)))
        let url = currentURL
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldReconnect else { return }
            DispatchQueue.main.async { self.errorMessage = nil }
            self.startStream(urlString: url)
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        DispatchQueue.main.async {
            self.errorMessage = "Reconnecting in \(Int(delay))s (attempt \(self.reconnectAttempt))…"
        }
    }

    // MARK: - MJPEG Parsing

    private func extractBoundaryData(from contentType: String) -> Data? {
        for component in contentType.components(separatedBy: ";") {
            var part = component.trimmingCharacters(in: .whitespaces)
            let lower = part.lowercased()
            if lower.hasPrefix("boundary=") {
                part = String(part.dropFirst("boundary=".count))
                // Some cameras include "--" prefix in the declared boundary value
                if !part.hasPrefix("--") { part = "--" + part }
                return part.data(using: .utf8)
            }
        }
        return nil
    }

    /// Pulls complete JPEG frames out of `receiveBuffer`, dispatches each one, and trims the buffer.
    private func parseBuffer() {
        // Locate every JPEG by its SOI (0xFF 0xD8) and EOI (0xFF 0xD9) markers.
        // This is the most widely compatible approach across camera firmware variants
        // and works whether or not a proper multipart boundary is present.
        var searchStart = receiveBuffer.startIndex

        while searchStart < receiveBuffer.endIndex {
            // Find the next SOI
            guard let soiRange = receiveBuffer.range(of: jpegSOI, in: searchStart..<receiveBuffer.endIndex) else {
                // No SOI found — drop everything before the last byte (keep 1 byte for possible partial SOI)
                if receiveBuffer.count > 1 {
                    receiveBuffer.removeFirst(receiveBuffer.count - 1)
                }
                return
            }

            // Find the EOI that follows this SOI
            let afterSOI = soiRange.upperBound
            guard let eoiRange = receiveBuffer.range(of: jpegEOI, in: afterSOI..<receiveBuffer.endIndex) else {
                // EOI not yet received — drop bytes before SOI and wait for more data
                receiveBuffer.removeSubrange(receiveBuffer.startIndex..<soiRange.lowerBound)
                return
            }

            // Extract the complete JPEG (includes both SOI and EOI)
            let jpegData = receiveBuffer[soiRange.lowerBound...eoiRange.upperBound - 1]
            processJPEG(Data(jpegData))

            // Advance past this frame
            searchStart = eoiRange.upperBound
        }

        // All found frames processed — trim consumed bytes
        receiveBuffer.removeSubrange(receiveBuffer.startIndex..<searchStart)

        // Safety valve: if buffer grows large without any valid JPEG, flush it
        if receiveBuffer.count > 4_000_000 {
            receiveBuffer.removeAll()
        }
    }

    private func processJPEG(_ data: Data) {
        // Running on sessionQueue. Decode UIImage here (off main thread).
        guard let image = UIImage(data: data) else { return }
        let pixelBuffer = makePixelBuffer(from: image)
        DispatchQueue.main.async { [weak self] in
            self?.currentFrame = image
        }
        if let pixelBuffer {
            framePublisher.send(pixelBuffer)
        }
    }

    // MARK: - CVPixelBuffer Creation

    private func makePixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return buffer
    }
}
