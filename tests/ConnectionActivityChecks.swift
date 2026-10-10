import Foundation

@main
struct ConnectionActivityChecks {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        let firstClient = UUID()
        let secondClient = UUID()
        var activity = ConnectionActivityPolicy()

        // A listener becoming ready, receiving only HTTP headers, or returning
        // an error does not have a delivery to record.
        require(!activity.isInUse(at: 0), "a ready but idle listener must stay neutral")
        require(!activity.isInUse(at: 1), "headers alone must not mark the connection in use")
        require(!activity.isInUse(at: 2), "failed and warm-up requests must stay neutral")

        activity.recordClientDelivery(for: firstClient, at: 10)
        require(activity.isInUse(at: 10), "a successful frame delivery must mark the client in use")
        require(activity.isInUse(at: 11.99),
                "a fresh delivery must remain in use during its timeout")
        require(!activity.isInUse(at: 12),
                "a stalled socket must not remain green")

        activity.recordClientDelivery(for: firstClient, at: 15)
        activity.recordClientDelivery(for: firstClient, at: 16)
        require(activity.isInUse(at: 17.99),
                "a renewed stream must remain active through its latest delivery")
        require(!activity.isInUse(at: 18),
                "a renewed stream must clear at its latest delivery deadline")

        activity.recordClientDelivery(for: firstClient, at: 20)
        activity.recordClientDelivery(for: secondClient, at: 20)
        require(activity.isInUse(at: 20), "multiple delivered streams must remain in use")
        require(activity.endClient(firstClient, at: 20),
                "disconnecting one stream must retain the other active stream")
        require(!activity.endClient(secondClient, at: 20),
                "disconnecting the final stream must clear the indicator immediately")

        activity.recordMediaDelivery(at: 30)
        require(activity.isInUse(at: 30), "a successful robot or HDR media response must create a short timeout")
        require(!activity.isInUse(at: 32),
                "a completed one-shot media response must expire without a receiver")

        activity.recordClientDelivery(for: firstClient, at: 40)
        activity.reset()
        require(!activity.isInUse(at: 40), "stopping the server must reset every activity deadline")

        activity.recordClientDelivery(for: firstClient, at: 50)
        activity.reset()
        activity.recordClientDelivery(for: secondClient, at: 51)
        require(activity.isInUse(at: 52.99),
                "a fresh stream after reset must use its own deadline")
        require(!activity.isInUse(at: 53),
                "the fresh stream must clear at its own deadline")

        activity.reset()
        for instant in stride(from: 60.0, through: 60.4, by: 0.1) {
            activity.recordClientDelivery(for: firstClient, at: instant)
        }
        require(activity.isInUse(at: 62.39),
                "continuous delivery must remain active through its latest deadline")
        require(!activity.isInUse(at: 62.4),
                "the burst must clear at its latest delivery deadline")

        print("Connection activity checks passed")
    }
}
