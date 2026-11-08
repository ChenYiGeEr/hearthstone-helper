import Foundation

/// HearthMirror's `MonoObject::getClass` loads `this + 8`. A client that is
/// still launching (`hs_beta`) or not fully attached passes a null object and
/// the process dies with SIGSEGV. One failed mirror read must not take the
/// helper down; the next poll tries again.
enum MirrorFaultGuard {
    private final class Box {
        var run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
    }

    static func protect<T>(_ body: @escaping () -> T) -> T? {
        let box = Box {}
        var value: T?
        box.run = { value = body() }
        let retained = Unmanaged.passRetained(box)
        let ok = hearth_guard_call({ raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().run()
        }, retained.toOpaque())
        retained.release()
        return ok == 0 ? nil : value
    }
}

@_silgen_name("hearth_guard_call")
private func hearth_guard_call(
    _ body: @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ context: UnsafeMutableRawPointer?
) -> Int32
