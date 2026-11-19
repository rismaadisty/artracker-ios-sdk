import XCTest
@testable import ARTracker

final class TraitSanitizerTests: XCTestCase {
    func testKeysCappedAt50SortedOrder() {
        var traits: [String: Any] = [:]
        for i in 0..<60 {
            // key names like "key_00", "key_01", ...
            let key = String(format: "key_%02d", i)
            traits[key] = "val_\(i)"
        }

        let result = TraitSanitizer.sanitize(traits)
        XCTAssertEqual(result.count, 50)

        // Sorted order: key_00 through key_49 should be present, key_50 through key_59 dropped
        XCTAssertEqual(result["key_00"], .string("val_0"))
        XCTAssertEqual(result["key_49"], .string("val_49"))
        XCTAssertNil(result["key_50"])
        XCTAssertNil(result["key_59"])
    }

    func testLongKeyAndEmptyKeyDropped() {
        let emptyKey = ""
        let validKey = "valid_key"
        let longKey = String(repeating: "k", count: 65)

        let traits: [String: Any] = [
            emptyKey: "empty",
            validKey: "ok",
            longKey: "too_long"
        ]

        let result = TraitSanitizer.sanitize(traits)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result["valid_key"], .string("ok"))
    }

    func testStringTruncatedTo256() {
        let longString = String(repeating: "A", count: 300)
        let traits: [String: Any] = ["desc": longString]

        let result = TraitSanitizer.sanitize(traits)
        if case .string(let val) = result["desc"] {
            XCTAssertEqual(val.count, 256)
            XCTAssertEqual(val, String(repeating: "A", count: 256))
        } else {
            XCTFail("Expected string value")
        }
    }

    func testSensitiveKeysDropped() {
        let traits: [String: Any] = [
            "password": "secret_pass",
            "PassWord": "secret_pass",
            "api_key": "abc",
            "APIKEY": "xyz",
            "apiKey": "123",
            "auth_token": "token123",
            "authorization": "Bearer xxx",
            "secret": "my_secret",
            "cookie": "sid=123",
            "card": "4111222233334444",
            "cardNumber": "4111222233334444",
            "cvv": "123",
            "pin": "1234",
            "nik": "3201010101010001",
            "ssn": "123-45-6789",
            "plan": "premium",
            "role": "admin"
        ]

        let result = TraitSanitizer.sanitize(traits)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result["plan"], .string("premium"))
        XCTAssertEqual(result["role"], .string("admin"))
    }

    func testNSNumberBoolAndNonScalars() {
        let traits: [String: Any] = [
            "bool_true": NSNumber(value: true),
            "bool_false": NSNumber(value: false),
            "native_bool": true,
            "int_val": NSNumber(value: 42),
            "native_int": 100,
            "double_val": NSNumber(value: 3.14),
            "native_double": 2.718,
            "nan_val": Double.nan,
            "inf_val": Double.infinity,
            "date_val": Date(),
            "array_val": [1, 2, 3],
            "dict_val": ["nested": "val"],
            "null_val": NSNull()
        ]

        let result = TraitSanitizer.sanitize(traits)
        XCTAssertEqual(result["bool_true"], .bool(true))
        XCTAssertEqual(result["bool_false"], .bool(false))
        XCTAssertEqual(result["native_bool"], .bool(true))
        XCTAssertEqual(result["int_val"], .number(42))
        XCTAssertEqual(result["native_int"], .number(100))
        XCTAssertEqual(result["double_val"], .number(3.14))
        XCTAssertEqual(result["native_double"], .number(2.718))
        XCTAssertEqual(result["null_val"], .null)

        // Dropped types
        XCTAssertNil(result["nan_val"])
        XCTAssertNil(result["inf_val"])
        XCTAssertNil(result["date_val"])
        XCTAssertNil(result["array_val"])
        XCTAssertNil(result["dict_val"])
    }
}
