import Foundation
import Network
import Combine
import Darwin

/// Discovers IP cameras on the local network using Bonjour mDNS and subnet scanning.
final class IPCameraDiscovery: NSObject, ObservableObject, NetServiceBrowserDelegate, NetServiceDelegate {

    @Published var discoveredCameras: [DiscoveredCamera] = []
    @Published var isScanning = false
    @Published var statusMessage = ""

    private var serviceBrowser: NetServiceBrowser?
    private var additionalBrowsers: [NetServiceBrowser] = []
    private var foundServices: [NetService] = []
    private var hostToURL: [String: String] = [:]
    private let queue = DispatchQueue(label: "ip.camera.discovery")
    private var scanSession: URLSession?   // isolated from shared session
    private var scanOperation: OperationQueue?

    struct DiscoveredCamera: Identifiable, Hashable {
        let id = UUID()
        let name: String
        let host: String
        let streamURL: String

        func hash(into hasher: inout Hasher) {
            hasher.combine(name)
            hasher.combine(host)
        }

        static func == (lhs: DiscoveredCamera, rhs: DiscoveredCamera) -> Bool {
            lhs.name == rhs.name && lhs.host == rhs.host
        }
    }

    // Set to true while Apple TV is connected/connecting to suppress subnet scan
    var suppressSubnetScan = false

    // MARK: - Public API

    func startDiscovery() {
        guard !isScanning else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = true
            self?.statusMessage = "Scanning for cameras…"
            self?.discoveredCameras = []
        }

        foundServices = []
        hostToURL = [:]

        // Bonjour must run on main thread (requires run loop)
        DispatchQueue.main.async { [weak self] in
            self?.scanBonjour()
        }
        // Subnet scan on background queue — skip if Apple TV is active to avoid disrupting it
        guard !suppressSubnetScan else {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Bonjour scan running (subnet scan skipped while Apple TV is connected)"
            }
            return
        }
        queue.async { [weak self] in
            self?.scanSubnet()
        }
    }

    func stopDiscovery() {
        // Cancel subnet scan immediately
        scanOperation?.cancelAllOperations()
        scanOperation = nil
        scanSession?.invalidateAndCancel()
        scanSession = nil
        // Must stop browsers on main thread
        DispatchQueue.main.async { [weak self] in
            self?.serviceBrowser?.stop()
            self?.serviceBrowser = nil
            self?.additionalBrowsers.forEach { $0.stop() }
            self?.additionalBrowsers.removeAll()
            self?.foundServices.removeAll()
        }
        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
        }
    }

    // MARK: - Bonjour Discovery
    // Must be called on the main thread — NetServiceBrowser needs a run loop.
    private func scanBonjour() {
        // Search multiple service types commonly used by IP cameras
        let serviceTypes = ["_http._tcp", "_rtsp._tcp", "_axis-video._tcp", "_daap._tcp"]
        for (i, type) in serviceTypes.enumerated() {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browser.searchForServices(ofType: type, inDomain: "local.")
            if i == 0 {
                serviceBrowser = browser
            } else {
                additionalBrowsers.append(browser)
            }
        }
    }

    // MARK: - Subnet Scanning (fallback)

    /// Common ports used by IP cameras and camera apps (DroidCam=4747, IP Webcam=8080,
    /// generic RTSP=8554, generic HTTP=80/8080/8081/8888/8008).
    private let cameraPorts = [80, 8080, 8081, 4747, 8554, 8888, 8008]

    /// MJPEG stream paths to try when a host responds on a port.
    private let mjpegPaths = [
        "/mjpeg",           // most cameras
        "/video",           // some generic cameras
        "/videostream.cgi", // many FOSCAM / generic
        "/stream",
        "/feed",
        "/mjpg/video.cgi",  // Axis
        "/axis-cgi/mjpg/video.cgi",
        "/shot.jpg",        // single-frame fallback
    ]

    private func scanSubnet() {
        guard let localIP = getLocalIP() else {
            DispatchQueue.main.async { [weak self] in
                self?.statusMessage = "Could not determine local IP"
            }
            return
        }

        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return }
        let subnet = parts[0...2].joined(separator: ".")

        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "Scanning \(subnet).1-254…"
        }

        // Phase 1 — fast TCP connect to find alive hosts
        // Use raw BSD sockets for speed (no HTTP overhead).
        let opQueue = OperationQueue()
        opQueue.maxConcurrentOperationCount = 50
        scanOperation = opQueue

        let aliveLock = NSLock()
        var aliveHosts: [(host: String, port: Int)] = []
        let phase1Group = DispatchGroup()

        for last in 1...254 {
            for port in cameraPorts {
                phase1Group.enter()
                let host = "\(subnet).\(last)"
                opQueue.addOperation { [weak self] in
                    guard self?.scanOperation != nil else { phase1Group.leave(); return }
                    if Self.tcpPing(host: host, port: port, timeoutMs: 400) {
                        aliveLock.lock(); aliveHosts.append((host, port)); aliveLock.unlock()
                    }
                    phase1Group.leave()
                }
            }
        }

        phase1Group.wait()

        guard scanOperation != nil else { return }   // cancelled

        DispatchQueue.main.async { [weak self] in
            self?.statusMessage = "Found \(aliveHosts.count) responding hosts — probing for streams…"
        }

        // Phase 2 — probe alive hosts for a real MJPEG or HTTP stream
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2.0
        let session = URLSession(configuration: config)
        scanSession = session

        let phase2Group = DispatchGroup()
        let probedHosts = NSMutableSet()

        for (host, port) in aliveHosts {
            // Skip if we already found a stream on this host
            if probedHosts.contains(host) { continue }
            probedHosts.add(host)

            for path in mjpegPaths {
                guard scanOperation != nil else { break }
                phase2Group.enter()
                let urlString = "http://\(host):\(port)\(path)"
                guard let url = URL(string: urlString) else { phase2Group.leave(); continue }

                var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
                req.httpMethod = "GET"
                // Open stream but cancel after headers arrive — enough to confirm it's MJPEG
                let sem = DispatchSemaphore(value: 0)
                var foundStream = false

                let task = session.dataTask(with: req) { _, response, error in
                    if let http = response as? HTTPURLResponse {
                        let ct = http.allHeaderFields["Content-Type"] as? String ?? ""
                        let isStream = http.statusCode == 200 &&
                            (ct.contains("multipart") || ct.contains("mjpeg") ||
                             ct.contains("octet-stream") || ct.contains("video"))
                        let isImage = http.statusCode == 200 && ct.contains("image")
                        if isStream || isImage {
                            foundStream = true
                        }
                    }
                    sem.signal()
                }
                task.resume()
                _ = sem.wait(timeout: .now() + 2.0)
                task.cancel()

                if foundStream {
                    let camera = IPCameraDiscovery.DiscoveredCamera(
                        name: "Camera @ \(host):\(port)",
                        host: host,
                        streamURL: urlString
                    )
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if !self.discoveredCameras.contains(where: { $0.streamURL == urlString }) {
                            self.discoveredCameras.append(camera)
                        }
                    }
                    phase2Group.leave()
                    break   // found a good stream for this host — stop trying more paths
                }
                phase2Group.leave()
            }
        }

        phase2Group.wait()

        DispatchQueue.main.async { [weak self] in
            self?.isScanning = false
            let count = self?.discoveredCameras.count ?? 0
            self?.statusMessage = count == 0 ? "No cameras found" : "Found \(count) camera(s)"
        }
    }

    /// TCP connect probe using BSD socket — much faster than URLSession for alive detection.
    private static func tcpPing(host: String, port: Int, timeoutMs: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        // Set non-blocking
        var flags = fcntl(sock, F_GETFL, 0)
        fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        inet_pton(AF_INET, host, &addr.sin_addr)

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult == 0 { return true }   // immediate connect (unusual but possible)
        guard errno == EINPROGRESS else { return false }

        // Wait for writability with select
        var writefds = fd_set()
        // zero out the fd_set manually
        withUnsafeMutableBytes(of: &writefds) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        let wordIdx = Int(sock) / 32
        let bitIdx  = Int(sock) % 32
        withUnsafeMutableBytes(of: &writefds) { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: Int32.self)
            base[wordIdx] |= Int32(bitPattern: 1 << bitIdx)
        }

        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs) * 1000)
        let n = select(sock + 1, nil, &writefds, nil, &tv)
        guard n > 0 else { return false }

        // Check for connect error
        var err: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &errLen)
        return err == 0
    }

    // MARK: - NetServiceBrowserDelegate

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind netService: NetService, moreComing: Bool) {
        netService.delegate = self
        foundServices.append(netService)
        netService.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        // Silently ignore — this fires for service types not on the network or when
        // Local Network permission hasn't been granted yet. The subnet scan is the
        // real fallback and is already running in parallel.
    }

    // MARK: - NetServiceDelegate

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let addresses = sender.addresses, !addresses.isEmpty else { return }

        let hostString = sender.hostName ?? sender.name
        let ports = sender.port > 0 ? [sender.port] : [80, 8080, 8081]

        // Probe in background — don't block the main thread
        queue.async { [weak self] in
            guard let self else { return }
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 1.5
            let session = URLSession(configuration: config)

            for port in ports {
                for path in self.mjpegPaths {
                    let urlString = "http://\(hostString):\(port)\(path)"
                    guard let url = URL(string: urlString) else { continue }
                    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 1.5)
                    req.httpMethod = "GET"
                    let sem = DispatchSemaphore(value: 0)
                    var found = false
                    let task = session.dataTask(with: req) { _, response, _ in
                        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                            let ct = http.allHeaderFields["Content-Type"] as? String ?? ""
                            if ct.contains("multipart") || ct.contains("mjpeg") ||
                               ct.contains("video") || ct.contains("image") {
                                found = true
                            }
                        }
                        sem.signal()
                    }
                    task.resume()
                    _ = sem.wait(timeout: .now() + 2.0)
                    task.cancel()
                    if found {
                        let camera = DiscoveredCamera(name: sender.name, host: hostString, streamURL: urlString)
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            if !self.discoveredCameras.contains(where: { $0.streamURL == urlString }) {
                                self.discoveredCameras.append(camera)
                            }
                        }
                        return   // found a good stream for this Bonjour service
                    }
                }
            }
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Silently ignore resolution failures
    }

    // MARK: - Helpers

    private func getLocalIP() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next }

            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            if addrFamily == UInt8(AF_INET) {
                if let name = interface.ifa_name,
                   let addr = interface.ifa_addr,
                   String(cString: name) == "en0" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                    address = String(cString: hostname)
                }
            }
        }

        return address
    }
}
