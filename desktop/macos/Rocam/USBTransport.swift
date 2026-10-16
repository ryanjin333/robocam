import Darwin
import Foundation

enum USBTransportError: LocalizedError {
    case unavailable, invalidResponse, noPhone, multiplePhones, socketFailure, cancelled

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Waiting for a trusted Rocam iPhone over USB."
        case .invalidResponse: return "The connected device sent an invalid Rocam USB response."
        case .noPhone: return "Connect and trust an iPhone running Rocam."
        case .multiplePhones: return "Choose an iPhone before connecting."
        case .socketFailure: return "The macOS USB transport is unavailable."
        case .cancelled: return "USB connection stopped."
        }
    }
}

struct USBDevice: Identifiable, Equatable, Hashable {
    let id: UInt32
    let name: String
    let productType: String
}

final class UsbmuxClient {
    fileprivate static let bootstrapRequest = Data("GET /usb/session HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nX-Rocam-USB: 1\r\nUser-Agent: Rocam-Webcam/0.1\r\nConnection: close\r\n\r\n".utf8)
    private static let muxPath = "/var/run/usbmuxd"
    private let tagLock = NSLock()
    private var nextTag: UInt32 = 1

    func phones() throws -> [USBDevice] {
        try attachedUSBDevices().compactMap { attached in
            guard let values = try? lockdownValues(for: attached.id), values.deviceClass == "iPhone" else { return nil }
            return USBDevice(id: attached.id, name: values.name, productType: values.productType)
        }
    }

    func openRocamSocket(deviceID: UInt32) throws -> UnixSocket {
        try openDeviceSocket(deviceID: deviceID, port: 8765)
    }

    func bootstrap(device: USBDevice) throws {
        let socket = try openRocamSocket(deviceID: device.id)
        defer { socket.close() }
        try socket.write(Self.bootstrapRequest)
        _ = try readSessionResponse(socket)
    }

    func openDeviceSocket(deviceID: UInt32, port: UInt16) throws -> UnixSocket {
        let socket = try UnixSocket(path: Self.muxPath)
        do {
            let networkPort = UInt32(port.bigEndian)
            let response = try sendRequest([
                "MessageType": "Connect",
                "DeviceID": NSNumber(value: deviceID),
                "PortNumber": NSNumber(value: networkPort),
                "ClientVersionString": "Rocam-Webcam/0.1",
                "ProgName": "Rocam"
            ], to: socket)
            guard response["MessageType"] as? String == "Result",
                  let number = response["Number"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(), number.intValue == 0 else {
                throw USBTransportError.unavailable
            }
            return socket
        } catch {
            socket.close()
            throw error
        }
    }

    private func readSessionResponse(_ socket: UnixSocket) throws -> USBSession {
        var reader = HTTPResponseReader()
        while true {
            reader.append(try socket.readChunk())
            if let response = try reader.next() {
                guard response.statusCode == 200,
                      response.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                    throw USBTransportError.invalidResponse
                }
                return try USBSession.decode(response.body)
            }
        }
    }

    private func attachedUSBDevices() throws -> [UsbmuxAttachedDevice] {
        let socket = try UnixSocket(path: Self.muxPath)
        defer { socket.close() }
        let response = try sendRequest([
            "MessageType": "ListDevices",
            "ClientVersionString": "Rocam-Webcam/0.1",
            "ProgName": "Rocam",
            "kLibUSBMuxVersion": 3
        ], to: socket)
        return try UsbmuxAttachedDevice.parseListResponse(response)
    }

    private func lockdownValues(for deviceID: UInt32) throws -> (deviceClass: String, productType: String, name: String) {
        let socket = try openDeviceSocket(deviceID: deviceID, port: 62078)
        defer { socket.close() }
        let deviceClass = try lockdownValue("DeviceClass", socket: socket)
        let productType = try lockdownValue("ProductType", socket: socket)
        let name = try lockdownValue("DeviceName", socket: socket)
        return (deviceClass, productType, name)
    }

    private func lockdownValue(_ key: String, socket: UnixSocket) throws -> String {
        let request: [String: Any] = ["Label": "Rocam", "Request": "GetValue", "Key": key]
        let payload = try PropertyListSerialization.data(fromPropertyList: request, format: .binary, options: 0)
        var length = UInt32(payload.count).bigEndian
        try socket.write(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        try socket.write(payload)
        let prefix = try socket.readExactly(MemoryLayout<UInt32>.size)
        let byteCount = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard byteCount > 0, byteCount <= ProtocolLimits.maxUsbmuxMessageBytes else { throw USBTransportError.invalidResponse }
        let responseData = try socket.readExactly(Int(byteCount))
        guard let response = try PropertyListSerialization.propertyList(from: responseData, format: nil) as? [String: Any],
              response["Request"] as? String == "GetValue", response["Error"] == nil,
              let value = response["Value"] as? String, !value.isEmpty else {
            throw USBTransportError.invalidResponse
        }
        return value
    }

    private func sendRequest(_ request: [String: Any], to socket: UnixSocket) throws -> [String: Any] {
        let payload = try PropertyListSerialization.data(fromPropertyList: request, format: .binary, options: 0)
        let tag = tagLock.withLock { () -> UInt32 in
            let value = nextTag
            nextTag &+= 1
            return value
        }
        try socket.write(try UsbmuxFrame.encode(plist: payload, tag: tag))
        let header = try socket.readExactly(UsbmuxFrame.headerLength)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length >= UInt32(UsbmuxFrame.headerLength), length <= ProtocolLimits.maxUsbmuxMessageBytes else {
            throw USBTransportError.invalidResponse
        }
        let frame = try UsbmuxFrame.decode(header + socket.readExactly(Int(length) - UsbmuxFrame.headerLength))
        guard frame.tag == tag,
              let plist = try PropertyListSerialization.propertyList(from: frame.payload, format: nil) as? [String: Any] else {
            throw USBTransportError.invalidResponse
        }
        return plist
    }
}

final class UnixSocket {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var closeRequested = false
    private var activeOperations = 0

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw USBTransportError.socketFailure }
        descriptor = fd
        var one: Int32 = 1
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &one) { setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size)) }
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }
        _ = withUnsafePointer(to: &timeout) { setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size)) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close()
            throw USBTransportError.socketFailure
        }
        pathBytes.withUnsafeBytes { source in
            withUnsafeMutableBytes(of: &address.sun_path) { target in target.copyBytes(from: source) }
        }
        let addressLength = socklen_t(MemoryLayout<sa_family_t>.size + pathBytes.count)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
        }
        guard connected == 0 else {
            close()
            throw USBTransportError.unavailable
        }
    }

    deinit { close() }

    /// Cancellation first shuts down the descriptor to unblock reads. The close itself waits
    /// for all already-leased operations, preventing an old operation from using a recycled FD.
    func close() {
        let fdToClose = lock.withLock { () -> Int32? in
            guard descriptor >= 0, !closeRequested else { return nil }
            closeRequested = true
            // Keep the lifecycle lock while shutdown wakes any leased operation. This prevents
            // its final release from closing and recycling the descriptor before cancellation.
            Darwin.shutdown(descriptor, SHUT_RDWR)
            guard activeOperations == 0 else { return nil }
            let fd = descriptor
            descriptor = -1
            return fd
        }
        if let fdToClose { Darwin.close(fdToClose) }
    }

    func write(_ data: Data) throws {
        try withDescriptorLease { fd in
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var offset = 0
                while offset < raw.count {
                    let wrote = Darwin.send(fd, base.advanced(by: offset), raw.count - offset, 0)
                    if wrote > 0 { offset += wrote; continue }
                    if wrote < 0, errno == EINTR { continue }
                    throw USBTransportError.socketFailure
                }
            }
        }
    }

    func readExactly(_ count: Int) throws -> Data {
        try withDescriptorLease { fd in
            var data = Data(count: count)
            try data.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { throw USBTransportError.socketFailure }
                var offset = 0
                while offset < count {
                    let read = Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                    if read > 0 { offset += read; continue }
                    if read < 0, errno == EINTR { continue }
                    throw USBTransportError.unavailable
                }
            }
            return data
        }
    }

    func readChunk(maximum: Int = 64 * 1024) throws -> Data {
        try withDescriptorLease { fd in
            var data = Data(count: maximum)
            let amount = try data.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { throw USBTransportError.socketFailure }
                while true {
                    let read = Darwin.recv(fd, base, maximum, 0)
                    if read > 0 { return read }
                    if read < 0, errno == EINTR { continue }
                    throw USBTransportError.unavailable
                }
            }
            data.removeSubrange(amount..<maximum)
            return data
        }
    }

    /// Internal diagnostic used by the local lifecycle regression check.
    var hasActiveOperation: Bool { lock.withLock { activeOperations > 0 } }

    private func withDescriptorLease<T>(_ operation: (Int32) throws -> T) throws -> T {
        let fd = try lock.withLock { () throws -> Int32 in
            guard descriptor >= 0, !closeRequested else { throw USBTransportError.cancelled }
            activeOperations += 1
            return descriptor
        }
        defer { releaseDescriptorLease() }
        return try operation(fd)
    }

    private func releaseDescriptorLease() {
        let fdToClose = lock.withLock { () -> Int32? in
            activeOperations -= 1
            guard activeOperations == 0, closeRequested, descriptor >= 0 else { return nil }
            let fd = descriptor
            descriptor = -1
            return fd
        }
        if let fdToClose { Darwin.close(fdToClose) }
    }
}

final class RocamUSBStream: @unchecked Sendable {
    private struct Callbacks: @unchecked Sendable {
        let frame: (Data) -> Void
        let state: (String) -> Void
    }
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var sockets: [UnixSocket] = []
    private var preferredName: String?

    func start(device: USBDevice, frame: @escaping (Data) -> Void, state: @escaping (String) -> Void) {
        let transition = stateLock.withLock { () -> (UInt64, [UnixSocket]) in
            generation &+= 1
            preferredName = device.name
            defer { sockets.removeAll() }
            return (generation, sockets)
        }
        let activeGeneration = transition.0
        transition.1.forEach { $0.close() }
        let callbacks = Callbacks(frame: frame, state: state)
        DispatchQueue.global(qos: .userInitiated).async { [weak self, callbacks] in
            self?.run(generation: activeGeneration, callbacks: callbacks, mux: UsbmuxClient())
        }
    }

    func stop() {
        let toClose = stateLock.withLock { () -> [UnixSocket] in
            generation &+= 1
            defer { sockets.removeAll() }
            return sockets
        }
        toClose.forEach { $0.close() }
    }

    private func run(generation activeGeneration: UInt64, callbacks: Callbacks, mux: UsbmuxClient) {
        while isCurrent(activeGeneration) {
            do {
                let device = try currentPhone(using: mux)
                let sessionSocket = try mux.openRocamSocket(deviceID: device.id)
                retain(sessionSocket, generation: activeGeneration)
                defer { release(sessionSocket) }
                try sessionSocket.write(UsbmuxClient.bootstrapRequest)
                let session = try readSession(sessionSocket)

                let streamSocket = try mux.openRocamSocket(deviceID: device.id)
                retain(streamSocket, generation: activeGeneration)
                defer { release(streamSocket) }
                try streamSocket.write(Self.streamRequest(key: session.key))
                try readMJPEG(streamSocket, frame: callbacks.frame, didValidate: {
                    guard self.isCurrent(activeGeneration) else { throw USBTransportError.cancelled }
                    callbacks.state("Streaming from \(device.name).")
                })
            } catch USBTransportError.cancelled {
                return
            } catch {
                if isCurrent(activeGeneration) { callbacks.state("Waiting for Rocam over USB.") }
            }
            if isCurrent(activeGeneration) { Thread.sleep(forTimeInterval: 1) }
        }
    }

    private func currentPhone(using mux: UsbmuxClient) throws -> USBDevice {
        let phones = try mux.phones()
        let preference = stateLock.withLock { preferredName }
        if let preference {
            let matches = phones.filter { $0.name == preference }
            if matches.count == 1, let selected = matches.first { return selected }
            if matches.count > 1 { throw USBTransportError.multiplePhones }
        }
        guard phones.count == 1, let phone = phones.first else {
            throw phones.isEmpty ? USBTransportError.noPhone : USBTransportError.multiplePhones
        }
        return phone
    }

    private func isCurrent(_ candidate: UInt64) -> Bool { stateLock.withLock { generation == candidate } }
    private func retain(_ socket: UnixSocket, generation: UInt64) { stateLock.withLock { if self.generation == generation { sockets.append(socket) } else { socket.close() } } }
    private func release(_ socket: UnixSocket) { stateLock.withLock { sockets.removeAll { $0 === socket } }; socket.close() }

    private func readSession(_ socket: UnixSocket) throws -> USBSession {
        var reader = HTTPResponseReader()
        while true {
            reader.append(try socket.readChunk())
            if let response = try reader.next() {
                guard response.statusCode == 200,
                      response.headers["content-type"]?.lowercased().hasPrefix("application/json") == true else {
                    throw USBTransportError.invalidResponse
                }
                return try USBSession.decode(response.body)
            }
        }
    }

    private func readMJPEG(_ socket: UnixSocket, frame: @escaping (Data) -> Void, didValidate: () throws -> Void) throws {
        var header = HTTPResponseReader(maxBodyBytes: 0, allowMissingContentLength: true)
        var parser = MJPEGParser()
        var validated = false
        while true {
            let data = try socket.readChunk()
            if !validated {
                header.append(data)
                guard let response = try header.next() else { continue }
                guard response.statusCode == 200,
                      response.headers["content-type"]?.lowercased().contains("multipart/x-mixed-replace") == true,
                      response.headers["content-type"]?.lowercased().contains("boundary=frame") == true else {
                    throw USBTransportError.invalidResponse
                }
                validated = true
                try didValidate()
                parser.append(header.drainRemainder())
            } else {
                parser.append(data)
            }
            for image in try parser.drain() { frame(image) }
        }
    }

    private static func streamRequest(key: String) -> Data {
        Data("GET /stream?key=\(key) HTTP/1.1\r\nHost: 127.0.0.1:8765\r\nX-Rocam-USB: 1\r\nUser-Agent: Rocam-Webcam/0.1\r\n\r\n".utf8)
    }
}
