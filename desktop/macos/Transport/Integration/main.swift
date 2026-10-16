import Darwin
import Foundation

private enum CheckError: Error {
    case socket, bind, listen, accept, readNeverBecameActive, readDidNotCancel
    case rapidReconnect, wrongByte, serverFailed(Error)
}

private func address(for path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    path.utf8CString.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: source) }
    }
    return address
}

private func makeListener(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CheckError.socket }
    var address = address(for: path)
    let length = socklen_t(MemoryLayout<sa_family_t>.size + path.utf8CString.count)
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) }
    }
    guard bound == 0 else { Darwin.close(fd); throw CheckError.bind }
    guard Darwin.listen(fd, 64) == 0 else { Darwin.close(fd); throw CheckError.listen }
    return fd
}

private func acceptConnection(_ listener: Int32) throws -> Int32 {
    let connection = Darwin.accept(listener, nil, nil)
    guard connection >= 0 else { throw CheckError.accept }
    return connection
}

let path = "/private/tmp/rocam-socket-lifecycle-\(UUID().uuidString)"
let listener = try makeListener(path: path)
defer {
    Darwin.close(listener)
    _ = Darwin.unlink(path)
}

let firstAccepted = DispatchSemaphore(value: 0)
let serverFinished = DispatchSemaphore(value: 0)
let serverLock = NSLock()
var serverResult: Result<Void, Error>?
let rapidConnections = 48
DispatchQueue.global(qos: .userInitiated).async {
    defer { serverFinished.signal() }
    do {
        let first = try acceptConnection(listener)
        firstAccepted.signal()
        defer { Darwin.close(first) }
        for _ in 0..<rapidConnections {
            let connection = try acceptConnection(listener)
            defer { Darwin.close(connection) }
            var byte: UInt8 = 0
            guard Darwin.recv(connection, &byte, 1, 0) == 1 else { throw CheckError.rapidReconnect }
            guard byte == 0x52 else { throw CheckError.wrongByte }
        }
        serverLock.withLock { serverResult = .success(()) }
    } catch {
        serverLock.withLock { serverResult = .failure(error) }
    }
}

let blockedReader = try UnixSocket(path: path)
guard firstAccepted.wait(timeout: .now() + 2) == .success else { throw CheckError.accept }
let readFinished = DispatchSemaphore(value: 0)
let readLock = NSLock()
var cancelledRead = false
DispatchQueue.global(qos: .userInitiated).async {
    defer { readFinished.signal() }
    do {
        _ = try blockedReader.readChunk(maximum: 1)
    } catch {
        readLock.withLock { cancelledRead = true }
    }
}

let activationDeadline = Date().addingTimeInterval(2)
while !blockedReader.hasActiveOperation, Date() < activationDeadline {
    Thread.sleep(forTimeInterval: 0.001)
}
guard blockedReader.hasActiveOperation else { throw CheckError.readNeverBecameActive }

let raceStart = DispatchSemaphore(value: 0)
let closeFinished = DispatchSemaphore(value: 0)
let reconnectFinished = DispatchSemaphore(value: 0)
DispatchQueue.global(qos: .userInitiated).async {
    _ = raceStart.wait(timeout: .now() + 2)
    blockedReader.close()
    closeFinished.signal()
}
DispatchQueue.global(qos: .userInitiated).async {
    _ = raceStart.wait(timeout: .now() + 2)
    do {
        for _ in 0..<rapidConnections {
            let socket = try UnixSocket(path: path)
            try socket.write(Data([0x52]))
            socket.close()
        }
    } catch {
        serverLock.withLock { if serverResult == nil { serverResult = .failure(error) } }
    }
    reconnectFinished.signal()
}
raceStart.signal()
raceStart.signal()

guard closeFinished.wait(timeout: .now() + 2) == .success,
      reconnectFinished.wait(timeout: .now() + 2) == .success,
      readFinished.wait(timeout: .now() + 2) == .success,
      readLock.withLock({ cancelledRead }) else {
    throw CheckError.readDidNotCancel
}
guard serverFinished.wait(timeout: .now() + 2) == .success else { throw CheckError.rapidReconnect }
if case let .failure(error)? = serverLock.withLock({ serverResult }) { throw CheckError.serverFailed(error) }
guard case .success? = serverLock.withLock({ serverResult }) else { throw CheckError.rapidReconnect }
print("UnixSocket active-read cancellation raced with \(rapidConnections) reconnects passed.")
