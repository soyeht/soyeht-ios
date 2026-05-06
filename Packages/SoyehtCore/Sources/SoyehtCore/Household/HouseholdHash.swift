import BLAKE3
import Foundation

public enum HouseholdHash {
    public static func blake3(_ data: Data) -> Data {
        let hasher = BLAKE3()
        hasher.update(data: data)
        return hasher.finalizeData()
    }
}
