import AppKit
import Testing
@testable import EchoDock

struct ApplicationTerminationDeliveryTests {
    @Test func deliversWhileMainQueueIsInsideTerminationModalLoop() async {
        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                // Reproduce terminate() called by a MainActor task: the current
                // main queue block cannot return until the nested loop finishes.
                let port = Port()
                RunLoop.main.add(port, forMode: .modalPanel)
                defer { RunLoop.main.remove(port, forMode: .modalPanel) }
                var delivered = false
                DispatchQueue.global().async {
                    ApplicationTerminationDelivery.schedule {
                        delivered = Thread.isMainThread
                        CFRunLoopStop(CFRunLoopGetMain())
                    }
                }
                let deadline = Date(timeIntervalSinceNow: 2)
                while !delivered && Date() < deadline {
                    RunLoop.main.run(mode: .modalPanel, before: deadline)
                }
                continuation.resume(returning: delivered)
            }
        }
        #expect(result)
    }

    @Test func alreadyFinishedCleanupStillDefersItsReply() async {
        let result: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                var delegateHasReturned = false
                ApplicationTerminationDelivery.schedule {
                    continuation.resume(returning: delegateHasReturned && Thread.isMainThread)
                }
                delegateHasReturned = true
            }
        }
        #expect(result)
    }
}
