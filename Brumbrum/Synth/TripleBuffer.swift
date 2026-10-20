import Synchronization

/// Lock-free single-producer / single-consumer triple buffer.
///
/// The writer (control loop, 100 Hz) always has a private slot to write into and
/// the reader (audio callback) always has a private slot to read from. The third
/// slot is exchanged through one atomic word, so neither side ever blocks or
/// allocates. `T` must be a trivial value type.
final class TripleBuffer<T> {
    private let slots: UnsafeMutablePointer<T>
    /// Low two bits: index of the middle slot. Bit 2: middle holds unread data.
    private let state: Atomic<Int>
    private var back = 0   // owned by the writer
    private var front = 2  // owned by the reader

    init(initial: T) {
        slots = .allocate(capacity: 3)
        slots.initialize(repeating: initial, count: 3)
        state = Atomic(1)
    }

    deinit {
        slots.deinitialize(count: 3)
        slots.deallocate()
    }

    /// Producer side only.
    func write(_ value: T) {
        slots[back] = value
        let old = state.exchange(back | 4, ordering: .acquiringAndReleasing)
        back = old & 3
    }

    /// Consumer side only. Returns the newest published value.
    func read() -> T {
        if state.load(ordering: .relaxed) & 4 != 0 {
            let old = state.exchange(front, ordering: .acquiringAndReleasing)
            front = old & 3
        }
        return slots[front]
    }
}

/// Everything the audio thread needs from the control loop, once per 10 ms.
struct ControlFrame {
    var rpm: Float = 800
    var load: Float = 0
    var speed: Float = 0            // m/s, for wind and road noise
    var gate: Float = 0             // fade target, 0…1
    var fadeSeconds: Float = 0.1
    var volume: Float = 0.7         // user level × ceiling × speed cap
    var shiftCut: Float = 0         // ignition-cut blip, 0…1
    var limiter: Float = 0          // 1 while bouncing off the limiter
    var popCounter: UInt32 = 0      // incremented for each exhaust pop request
    var blowoffCounter: UInt32 = 0  // incremented for each blow-off request
}
