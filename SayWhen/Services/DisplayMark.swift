import QuartzCore
import os

/// A one-shot display link lets Instruments correlate SwiftUI actions with the next display refresh.
@MainActor final class DisplayMark: NSObject {
    private static let log = Logger(subsystem: "local.saywhen.app", category: "Interaction")
    private static let signposts = OSSignposter(subsystem: "local.saywhen.app", category: "Interaction")
    enum Event { case foreground, completion }
    private let event: Event
    private let began: CFTimeInterval
    private init(_ event: Event, began: CFTimeInterval) { self.event = event; self.began = began }

    static func nextFrame(_ event: Event, began: CFTimeInterval = CACurrentMediaTime()) {
        let mark = DisplayMark(event, began: began)
        let link = CADisplayLink(target: mark, selector: #selector(mark.tick(_:)))
        link.add(to: .main, forMode: .common)
    }

    @objc private func tick(_ link: CADisplayLink) {
        link.invalidate()
        switch event {
        case .foreground:
            Self.signposts.emitEvent("ListForegroundFrame")
            Self.log.notice("ListForegroundFrame")
        case .completion:
            let milliseconds = (CACurrentMediaTime() - began) * 1000
            Self.signposts.emitEvent("CompletionFrame")
            Self.log.info("CompletionFrame ms=\(milliseconds, privacy: .public)")
        }
    }
}
