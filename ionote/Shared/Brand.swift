import SwiftUI

/// The name, always written the same way as its sibling iopix: "io" in the sun's gold, "notes" in white
/// (or, on a light background, the deep teal of the icon). Used wherever the app writes its own name.
enum Brand {
    static let gold = Color(red: 0.965, green: 0.812, blue: 0.447)   // #f6cf72
    static let teal = Color(red: 0.110, green: 0.353, blue: 0.369)   // #1c5a5e, ioNote's own colour

    /// The two-colour name as one piece of text, so it fits wherever a Text does.
    static func name(onLight: Bool = false) -> Text {
        Text("io").foregroundColor(gold).fontWeight(.bold) + Text("note").foregroundColor(onLight ? teal : .white).fontWeight(.bold)
    }

    /// A sentence with the name in it: "Save to ionote".
    static func text(_ before: String, _ after: String = "", onLight: Bool = false) -> Text {
        Text(before) + name(onLight: onLight) + Text(after)
    }
}
