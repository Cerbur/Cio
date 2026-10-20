import Foundation

/// Read and write hits both refresh recency. Count and byte/cost budgets apply
/// together, including negative entries whose cost can be zero.
public struct BoundedLRUCache<Key: Hashable, Value> {
  private var entries: [Key: (value: Value, cost: Int)] = [:]
  private var order: [Key] = []
  public let countLimit: Int
  public let costLimit: Int
  public private(set) var totalCost = 0
  public var count: Int { entries.count }
  public var keys: [Key] { order }

  public init(countLimit: Int, costLimit: Int) {
    self.countLimit = max(0, countLimit)
    self.costLimit = max(0, costLimit)
  }

  public mutating func value(for key: Key) -> Value? {
    guard let entry = entries[key] else { return nil }
    order.removeAll { $0 == key }
    order.append(key)
    return entry.value
  }

  public mutating func insert(_ value: Value, for key: Key, cost: Int) {
    remove(key)
    guard countLimit > 0, cost >= 0, cost <= costLimit else { return }
    entries[key] = (value, cost)
    order.append(key)
    totalCost += cost
    while count > countLimit || totalCost > costLimit {
      remove(order[0])
    }
  }

  public mutating func remove(_ key: Key) {
    if let entry = entries.removeValue(forKey: key) { totalCost -= entry.cost }
    order.removeAll { $0 == key }
  }
}
