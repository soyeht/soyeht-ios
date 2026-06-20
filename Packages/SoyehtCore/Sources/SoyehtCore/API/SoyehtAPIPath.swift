import Foundation

enum SoyehtAPIPath {
  static func segment(_ rawValue: String) throws -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    guard let encoded = rawValue.addingPercentEncoding(withAllowedCharacters: allowed),
      !encoded.isEmpty
    else {
      throw SoyehtAPIClient.APIError.invalidURL
    }
    return encoded
  }

  static func segmentOrNil(_ rawValue: String) -> String? {
    try? segment(rawValue)
  }
}
