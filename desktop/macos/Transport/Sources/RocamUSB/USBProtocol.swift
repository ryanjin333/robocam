import Foundation

public enum ProtocolLimits {
    public static let maxUsbmuxMessageBytes = 1 * 1024 * 1024
    public static let maxHTTPHeadersBytes = 8 * 1024
    public static let maxUSBSessionBytes = 8 * 1024
    public static let maxMJPEGFrameBytes = 16 * 1024 * 1024
    public static let maxJPEGDimension = 8_192
}

public enum RocamUSBError: Error, Equatable {
    case malformedMessage, messageTooLarge, incompleteMessage, invalidSession
    case invalidHTTPResponse, bodyTooLarge, invalidMJPEG, invalidDeviceList
}

public struct UsbmuxFrame: Equatable {
    public static let headerLength = 16
    public let tag: UInt32
    public let payload: Data

    public static func decode(_ bytes: Data) throws -> UsbmuxFrame {
        guard bytes.count >= headerLength else { throw RocamUSBError.incompleteMessage }
        let length = try bytes.littleEndianUInt32(at: 0)
        let version = try bytes.littleEndianUInt32(at: 4)
        let message = try bytes.littleEndianUInt32(at: 8)
        let tag = try bytes.littleEndianUInt32(at: 12)
        guard version == 1, message == 8, length >= UInt32(headerLength) else {
            throw RocamUSBError.malformedMessage
        }
        guard length <= ProtocolLimits.maxUsbmuxMessageBytes else { throw RocamUSBError.messageTooLarge }
        guard Int(length) == bytes.count else { throw RocamUSBError.malformedMessage }
        return UsbmuxFrame(tag: tag, payload: bytes.dropFirst(headerLength))
    }

    public static func encode(plist payload: Data, tag: UInt32) throws -> Data {
        let length = headerLength + payload.count
        guard length <= ProtocolLimits.maxUsbmuxMessageBytes else { throw RocamUSBError.messageTooLarge }
        var data = Data()
        data.appendLittleEndian(UInt32(length))
        data.appendLittleEndian(1)
        data.appendLittleEndian(8)
        data.appendLittleEndian(tag)
        data.append(payload)
        return data
    }
}

public struct UsbmuxAttachedDevice: Equatable {
    public let id: UInt32
    public let connectionType: String

    public static func parseListResponse(_ response: [String: Any]) throws -> [UsbmuxAttachedDevice] {
        let messageType = response["MessageType"] as? String
        guard messageType == nil || messageType == "ListDevices",
              let deviceList = response["DeviceList"] as? [[String: Any]] else {
            throw RocamUSBError.invalidDeviceList
        }
        return try deviceList.compactMap { record in
            guard record["MessageType"] as? String == "Attached",
                  let properties = record["Properties"] as? [String: Any],
                  let connection = properties["ConnectionType"] as? String,
                  connection == "USB" else { return nil }
            guard let number = record["DeviceID"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue > 0,
                  number.doubleValue <= Double(UInt32.max) else {
                throw RocamUSBError.invalidDeviceList
            }
            return UsbmuxAttachedDevice(id: number.uint32Value, connectionType: connection)
        }
    }
}

public struct USBSession: Equatable {
    public let key: String
    public static func decode(_ data: Data) throws -> USBSession {
        guard data.count <= ProtocolLimits.maxUSBSessionBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any], dictionary.count == 2,
              let version = dictionary["protocolVersion"] as? Int, version == 1,
              let key = dictionary["key"] as? String, key.count == 32,
              key.allSatisfy({ $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }) else {
            throw RocamUSBError.invalidSession
        }
        return USBSession(key: key)
    }
}

public struct HTTPResponse: Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data
}

public struct HTTPResponseReader {
    private var bytes = Data()
    private let maxBodyBytes: Int
    private let allowMissingContentLength: Bool

    public init(maxBodyBytes: Int = ProtocolLimits.maxUSBSessionBytes, allowMissingContentLength: Bool = false) {
        self.maxBodyBytes = maxBodyBytes
        self.allowMissingContentLength = allowMissingContentLength
    }

    public mutating func append(_ data: Data) { bytes.append(data) }
    public mutating func drainRemainder() -> Data {
        defer { bytes.removeAll(keepingCapacity: true) }
        return bytes
    }

    public mutating func next() throws -> HTTPResponse? {
        guard let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            guard bytes.count <= ProtocolLimits.maxHTTPHeadersBytes else { throw RocamUSBError.invalidHTTPResponse }
            return nil
        }
        guard headerEnd.lowerBound <= ProtocolLimits.maxHTTPHeadersBytes,
              let headerText = String(data: bytes[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw RocamUSBError.invalidHTTPResponse
        }
        let lines = headerText.components(separatedBy: "\r\n")
        let statusParts = lines.first?.split(separator: " ") ?? []
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/"), let status = Int(statusParts[1]) else {
            throw RocamUSBError.invalidHTTPResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let name = parts.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard parts.count == 2, !name.isEmpty, headers[name] == nil else { throw RocamUSBError.invalidHTTPResponse }
            headers[name] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard let value = headers["content-length"] else {
            guard allowMissingContentLength else { throw RocamUSBError.invalidHTTPResponse }
            bytes.removeSubrange(0..<headerEnd.upperBound)
            return HTTPResponse(statusCode: status, headers: headers, body: Data())
        }
        guard let length = Int(value), length >= 0, length <= maxBodyBytes else { throw RocamUSBError.bodyTooLarge }
        let bodyStart = headerEnd.upperBound
        guard bytes.count - bodyStart >= length else { return nil }
        let body = bytes.subdata(in: bodyStart..<(bodyStart + length))
        bytes.removeSubrange(0..<(bodyStart + length))
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }
}

public struct MJPEGParser {
    private var bytes = Data()
    public init() {}
    public mutating func append(_ data: Data) { bytes.append(data) }

    public mutating func drain() throws -> [Data] {
        var frames: [Data] = []
        while true {
            guard let boundaryEnd = bytes.range(of: Data("\r\n".utf8)) else {
                guard bytes.count <= ProtocolLimits.maxHTTPHeadersBytes else { throw RocamUSBError.invalidMJPEG }
                return frames
            }
            guard bytes[..<boundaryEnd.lowerBound] == Data("--frame".utf8) else { throw RocamUSBError.invalidMJPEG }
            let headerStart = boundaryEnd.upperBound
            guard let headerEnd = bytes.range(of: Data("\r\n\r\n".utf8), options: [], in: headerStart..<bytes.count) else {
                guard bytes.count - headerStart <= ProtocolLimits.maxHTTPHeadersBytes else { throw RocamUSBError.invalidMJPEG }
                return frames
            }
            guard headerEnd.lowerBound - headerStart <= ProtocolLimits.maxHTTPHeadersBytes,
                  let headerText = String(data: bytes[headerStart..<headerEnd.lowerBound], encoding: .utf8) else {
                throw RocamUSBError.invalidMJPEG
            }
            var headers: [String: String] = [:]
            for line in headerText.components(separatedBy: "\r\n") {
                let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let name = pair.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                guard pair.count == 2, !name.isEmpty, headers[name] == nil else { throw RocamUSBError.invalidMJPEG }
                headers[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard headers["content-type"]?.lowercased() == "image/jpeg",
                  let text = headers["content-length"], let length = Int(text),
                  length > 0, length <= ProtocolLimits.maxMJPEGFrameBytes else { throw RocamUSBError.invalidMJPEG }
            let frameStart = headerEnd.upperBound
            guard bytes.count >= frameStart + length + 2 else { return frames }
            guard bytes.subdata(in: (frameStart + length)..<(frameStart + length + 2)) == Data("\r\n".utf8) else {
                throw RocamUSBError.invalidMJPEG
            }
            frames.append(bytes.subdata(in: frameStart..<(frameStart + length)))
            bytes.removeSubrange(0..<(frameStart + length + 2))
        }
    }
}

public final class LatestFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: Data?
    private var scheduled = false
    public init() {}

    /// Returns true only for the caller that must schedule the single draining task.
    public func publish(_ frame: Data) -> Bool {
        lock.withLock {
            latest = frame
            guard !scheduled else { return false }
            scheduled = true
            return true
        }
    }

    /// Returns the latest frame; nil atomically marks the draining task complete.
    public func take() -> Data? {
        lock.withLock {
            guard let frame = latest else {
                scheduled = false
                return nil
            }
            latest = nil
            return frame
        }
    }

    public func clear() { lock.withLock { latest = nil } }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) throws -> UInt32 {
        guard count >= offset + 4 else { throw RocamUSBError.incompleteMessage }
        return withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var little = value.littleEndian
        append(Data(bytes: &little, count: MemoryLayout<UInt32>.size))
    }
}
