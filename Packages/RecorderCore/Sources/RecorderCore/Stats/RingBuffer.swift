//
//  RingBuffer.swift
//  RecorderCore
//

import Foundation

/// Fixed-capacity buffer that keeps the most recent elements (used for live preview charts).
public struct RingBuffer<Element> {
    public let capacity: Int
    private var storage: [Element] = []
    private var head = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        self.capacity = capacity
        storage.reserveCapacity(capacity)
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func append(_ element: Element) {
        if storage.count < capacity {
            storage.append(element)
        } else {
            storage[head] = element
            head = (head + 1) % capacity
        }
    }

    /// Elements from oldest to newest.
    public var elements: [Element] {
        Array(storage[head...] + storage[..<head])
    }

    public var last: Element? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

/// Lets every `factor`-th sample through (preview decimation).
public struct Decimator {
    public let factor: Int
    private var counter = 0

    public init(factor: Int) {
        precondition(factor > 0, "factor must be positive")
        self.factor = factor
    }

    public mutating func shouldEmit() -> Bool {
        defer { counter = (counter + 1) % factor }
        return counter == 0
    }
}
