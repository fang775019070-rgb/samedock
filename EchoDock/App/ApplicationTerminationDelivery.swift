import AppKit

enum ApplicationTerminationDelivery {
    /// terminateLater runs a nested modal loop. A quit requested by a MainActor
    /// task still occupies the main dispatch queue, so another main-queue block
    /// cannot deliver the reply. Schedule directly in the run loop instead.
    /// Always defer, including when cleanup is already complete, so the delegate
    /// has returned terminateLater before its reply is delivered.
    static func schedule(_ completion: @escaping () -> Void) {
        RunLoop.main.perform(inModes: [.common, .modalPanel], block: completion)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}
