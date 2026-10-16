import XCTest
@testable import RocamUSB

final class USBProtocolTests: XCTestCase {
    func testRejectsUsbmuxHeaderWithWrongVersion() throws {
        var bytes = Data()
        bytes.append(contentsOf: [16, 0, 0, 0]) // total length
        bytes.append(contentsOf: [2, 0, 0, 0])  // version must be one
        bytes.append(contentsOf: [8, 0, 0, 0])  // plist message
        bytes.append(contentsOf: [0, 0, 0, 0])  // tag

        XCTAssertThrowsError(try UsbmuxFrame.decode(bytes)) { error in
            XCTAssertEqual(error as? RocamUSBError, .malformedMessage)
        }
    }

    func testRejectsUsbmuxLengthThatDoesNotMatchPayload() {
        var bytes = Data([20, 0, 0, 0, 1, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0])
        bytes.append(0)
        XCTAssertThrowsError(try UsbmuxFrame.decode(bytes))
    }

    func testRejectsIncompleteUsbmuxHeader() {
        XCTAssertThrowsError(try UsbmuxFrame.decode(Data(repeating: 0, count: 15)))
    }

    func testSessionBootstrapAcceptsOnlyBoundedLowercaseV1Key() throws {
        let key = String(repeating: "a", count: 32)
        XCTAssertEqual(try USBSession.decode(Data("{\"protocolVersion\":1,\"key\":\"\(key)\"}".utf8)).key, key)
        XCTAssertThrowsError(try USBSession.decode(Data("{\"protocolVersion\":1,\"key\":\"\(key.uppercased())\"}".utf8)))
        XCTAssertThrowsError(try USBSession.decode(Data(repeating: 0, count: ProtocolLimits.maxUSBSessionBytes + 1)))
    }

    func testHTTPReaderHandlesFragmentedHeadersAndRejectsOversizeBody() throws {
        var reader = HTTPResponseReader()
        reader.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n".utf8))
        XCTAssertNil(try reader.next())
        reader.append(Data("Content-Type: application/json\r\n\r\n{}".utf8))
        XCTAssertEqual(try reader.next()?.body, Data("{}".utf8))

        var oversized = HTTPResponseReader(maxBodyBytes: 1)
        oversized.append(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8))
        XCTAssertThrowsError(try oversized.next())
    }

    func testStreamingHTTPResponsePreservesMJPEGBytesAfterHeaders() throws {
        var reader = HTTPResponseReader(allowMissingContentLength: true)
        reader.append(Data("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\n\r\n--frame\r\n".utf8))
        XCTAssertEqual(try reader.next()?.statusCode, 200)
        XCTAssertEqual(reader.drainRemainder(), Data("--frame\r\n".utf8))
    }

    func testMJPEGParserHandlesFragmentedFrameAndRejectsWrongBoundary() throws {
        var parser = MJPEGParser()
        parser.append(Data("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: 3\r\n\r\nA".utf8))
        XCTAssertEqual(try parser.drain(), [])
        parser.append(Data("BC\r\n".utf8))
        XCTAssertEqual(try parser.drain(), [Data("ABC".utf8)])

        var invalid = MJPEGParser()
        invalid.append(Data("--other\r\n".utf8))
        XCTAssertThrowsError(try invalid.drain())
    }

    func testLatestFrameStoreNeverAccumulatesBacklogAndCanClear() {
        let store = LatestFrameStore()
        XCTAssertTrue(store.publish(Data([1])))
        XCTAssertFalse(store.publish(Data([2])))
        XCTAssertEqual(store.take(), Data([2]))
        store.clear()
        XCTAssertNil(store.take())
        XCTAssertTrue(store.publish(Data([3])))
    }
}

extension USBProtocolTests {
    func testDeviceListUsesUSBTransportAndRejectsBooleanOrZeroIdentifiers() throws {
        let valid: [String: Any] = [
            "DeviceList": [[
                "MessageType": "Attached",
                "DeviceID": NSNumber(value: 42),
                "Properties": ["ConnectionType": "USB", "ProductID": 4776, "SerialNumber": "ignored"]
            ], [
                "DeviceID": NSNumber(value: 99),
                "Properties": ["ConnectionType": "Network"]
            ]]
        ]
        XCTAssertEqual(try UsbmuxAttachedDevice.parseListResponse(valid), [UsbmuxAttachedDevice(id: 42, connectionType: "USB")])

        let boolean: [String: Any] = ["DeviceList": [["MessageType": "Attached", "DeviceID": true, "Properties": ["ConnectionType": "USB"]]]]
        XCTAssertThrowsError(try UsbmuxAttachedDevice.parseListResponse(boolean))
        let zero: [String: Any] = ["DeviceList": [["MessageType": "Attached", "DeviceID": 0, "Properties": ["ConnectionType": "USB"]]]]
        XCTAssertThrowsError(try UsbmuxAttachedDevice.parseListResponse(zero))
    }

    func testMJPEGRejectsCompletedOversizeHeader() {
        var parser = MJPEGParser()
        let header = "--frame\r\n" + String(repeating: "x", count: ProtocolLimits.maxHTTPHeadersBytes + 1) + ": y\r\n\r\n"
        parser.append(Data(header.utf8))
        XCTAssertThrowsError(try parser.drain())
    }
}
