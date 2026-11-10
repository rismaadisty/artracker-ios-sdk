import Foundation

/// Builds W3C / rrweb compatible Virtual DOM structures from [RawWireframeNode].
/// Operates on background queue (0ms Main Thread consumption).
public struct VirtualDOMBuilder: Sendable {

    public init() {}

    /// Builds standard rrweb EventType.Meta (type: 4)
    public static func buildMetaEvent(
        timestamp: Int64,
        href: String,
        width: Double,
        height: Double
    ) -> [String: JSONValue] {
        return [
            "type": .number(4),
            "timestamp": .number(Double(timestamp)),
            "data": .object([
                "href": .string(href),
                "width": .number(round(width)),
                "height": .number(round(height))
            ])
        ]
    }

    /// Builds standard rrweb EventType.FullSnapshot (type: 2)
    public static func buildFullSnapshotEvent(
        timestamp: Int64,
        nodes: [RawWireframeNode],
        screenWidth: Double,
        screenHeight: Double
    ) -> [String: JSONValue] {
        let sw = Int(round(screenWidth))
        let sh = Int(round(screenHeight))

        // Build child nodes under body (id: 4)
        var bodyChildNodes: [JSONValue] = []

        for node in nodes {
            let x = Int(round(node.frame[0]))
            let y = Int(round(node.frame[1]))
            let w = Int(round(node.frame[2]))
            let h = Int(round(node.frame[3]))

            var styleParts: [String] = [
                "position:absolute",
                "left:\(x)px",
                "top:\(y)px",
                "width:\(w)px",
                "height:\(h)px",
                "box-sizing:border-box"
            ]

            if let bg = node.backgroundColor {
                styleParts.append("background:\(bg)")
            }
            if let tc = node.textColor {
                styleParts.append("color:\(tc)")
            }
            if let fs = node.fontSize {
                styleParts.append("font-size:\(Int(round(fs)))px")
            }
            if let fw = node.fontWeight {
                styleParts.append("font-weight:\(fw)")
            }
            if let br = node.borderRadius, br > 0 {
                styleParts.append("border-radius:\(Int(round(br)))px")
            }
            if let bw = node.borderWidth, let bc = node.borderColor, bw > 0 {
                styleParts.append("border:\(Int(round(bw)))px solid \(bc)")
            }

            if node.tag == "button" {
                styleParts.append("display:flex")
                styleParts.append("align-items:center")
                styleParts.append("justify-content:center")
                styleParts.append("border:none")
            } else if node.text != nil && !node.text!.isEmpty {
                styleParts.append("display:flex")
                styleParts.append("align-items:center")
            }

            var attrs: [String: JSONValue] = [
                "style": .string(styleParts.joined(separator: ";") + ";")
            ]

            if let customClass = node.customClassName {
                attrs["class"] = .string(customClass)
            }

            var childNodes: [JSONValue] = []
            if let txt = node.text, !txt.isEmpty {
                let textNodeId = node.id * 1000 + 1
                childNodes.append(.object([
                    "id": .number(Double(textNodeId)),
                    "type": .number(3), // Text node
                    "textContent": .string(txt)
                ]))
            }

            var elementDict: [String: JSONValue] = [
                "id": .number(Double(node.id)),
                "type": .number(2), // Element node
                "tagName": .string(node.tag),
                "attributes": .object(attrs)
            ]
            if !childNodes.isEmpty {
                elementDict["childNodes"] = .array(childNodes)
            }

            bodyChildNodes.append(.object(elementDict))
        }

        let bodyStyle = "margin:0;padding:0;position:relative;width:\(sw)px;height:\(sh)px;overflow:hidden;"
        let htmlStyle = "margin:0;padding:0;background:#F2F2F7;overflow:hidden;width:\(sw)px;height:\(sh)px;font-family:-apple-system,BlinkMacSystemFont,sans-serif;"

        let rootDoc: [String: JSONValue] = [
            "id": .number(1),
            "type": .number(0), // Document node
            "childNodes": .array([
                .object([
                    "id": .number(2),
                    "type": .number(1), // DocumentType
                    "name": .string("html")
                ]),
                .object([
                    "id": .number(3),
                    "type": .number(2), // Element node
                    "tagName": .string("html"),
                    "attributes": .object(["style": .string(htmlStyle)]),
                    "childNodes": .array([
                        .object([
                            "id": .number(4),
                            "type": .number(2), // Element node
                            "tagName": .string("body"),
                            "attributes": .object(["style": .string(bodyStyle)]),
                            "childNodes": .array(bodyChildNodes)
                        ])
                    ])
                ])
            ])
        ]

        return [
            "type": .number(2), // FullSnapshot
            "timestamp": .number(Double(timestamp)),
            "data": .object([
                "node": .object(rootDoc),
                "initialOffset": .object([
                    "left": .number(0),
                    "top": .number(0)
                ])
            ])
        ]
    }

    /// Builds standard rrweb EventType.IncrementalSnapshot (type: 3) for Touch/Mouse interactions
    public static func buildTouchInteractionEvent(
        timestamp: Int64,
        source: Int = 2, // MouseInteraction
        type: Int = 2, // MouseUp / TouchEnd
        targetId: Int,
        x: Double,
        y: Double
    ) -> [String: JSONValue] {
        return [
            "type": .number(3), // IncrementalSnapshot
            "timestamp": .number(Double(timestamp)),
            "data": .object([
                "source": .number(Double(source)),
                "type": .number(Double(type)),
                "id": .number(Double(targetId)),
                "x": .number(round(x)),
                "y": .number(round(y))
            ])
        ]
    }
}

