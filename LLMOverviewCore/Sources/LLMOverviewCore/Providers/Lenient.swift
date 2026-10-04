import Foundation

/// Some dashboards serialize big integers and money as strings, inconsistently. These wrappers
/// accept a number, a numeric string, or null.
struct LenientDouble: Decodable, Sendable {
    let value: Double?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let d = try? c.decode(Double.self) { value = d }
        else if let s = try? c.decode(String.self) {
            value = Double(s.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: "$", with: ""))
        } else { value = nil }
    }
}

struct LenientInt: Decodable, Sendable {
    let value: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { value = nil }
        else if let i = try? c.decode(Int.self) { value = i }
        else if let d = try? c.decode(Double.self) { value = Int(d) }
        else if let s = try? c.decode(String.self) { value = Int(s) ?? Double(s).map(Int.init) }
        else { value = nil }
    }
}

extension Optional where Wrapped == LenientDouble { var v: Double? { self?.value } }
extension Optional where Wrapped == LenientInt { var v: Int? { self?.value } }
