import Foundation
import Testing
@testable import BobbCore

@Suite("JSONValue")
struct JSONValueTests {
    @Test func roundTripsAllCases() throws {
        let value: JSONValue = [
            "s": "hello",
            "n": 3,
            "f": 1.5,
            "b": true,
            "nil": nil,
            "arr": [1, 2, "three"],
            "obj": ["nested": true],
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(value)
        let decoded = try decoder.decode(JSONValue.self, from: data)
        #expect(decoded == value)
    }

    @Test func numberDecodesFromIntOrFloatLiteral() throws {
        let decoder = JSONDecoder()
        let intValue = try decoder.decode(JSONValue.self, from: Data("3".utf8))
        #expect(intValue == .number(3))
        let floatValue = try decoder.decode(JSONValue.self, from: Data("3.5".utf8))
        #expect(floatValue == .number(3.5))
    }

    @Test func subscriptReadsObjectFields() {
        let value: JSONValue = ["a": ["b": "c"]]
        #expect(value["a"]?["b"]?.stringValue == "c")
        #expect(value["missing"] == nil)
    }
}
