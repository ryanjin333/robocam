import Foundation

let client = UsbmuxClient()
let phones = try client.phones()
print("Native USB probe found \(phones.count) classified iPhone(s).")
guard phones.count == 1, let phone = phones.first else {
    if phones.count > 1 { print("Native USB probe requires an in-app phone selection.") }
    exit(0)
}
try client.bootstrap(device: phone)
print("Native USB session bootstrap accepted.")

let stream = RocamUSBStream()
let finished = DispatchSemaphore(value: 0)
stream.start(device: phone, frame: { jpeg in
    guard !jpeg.isEmpty else { return }
    print("Native USB MJPEG stream delivered a frame.")
    stream.stop()
    finished.signal()
}, state: { message in
    if message.hasPrefix("Streaming") { print("Native USB MJPEG response accepted.") }
})
if finished.wait(timeout: .now() + 15) == .timedOut {
    stream.stop()
    print("Native USB MJPEG stream did not deliver a frame within 15 seconds.")
    exit(2)
}
