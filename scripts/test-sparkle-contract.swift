import CryptoKit
import Foundation
import Sparkle

let comparator = SUStandardVersionComparator.default
precondition(comparator.compareVersion("0.0.9", toVersion: "0.0.10") == .orderedAscending)
precondition(comparator.compareVersion("0.0.10", toVersion: "0.1.0") == .orderedAscending)
precondition(comparator.compareVersion("0.1.0", toVersion: "0.0.10") == .orderedDescending)
precondition(comparator.compareVersion("0.0.10", toVersion: "0.0.10") == .orderedSame)
print("Sparkle native comparator: 0.0.9 → 0.0.10 → 0.1.0 passed")
