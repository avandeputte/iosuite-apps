import SwiftUI

/// The name, always written the same way: "io" in the sun's gold, "pix" in white (or, on a light background,
/// the deep indigo of the icon's sky). Used wherever the apps write their own name.
enum Brand {
    static let gold = Color(red: 0.965, green: 0.812, blue: 0.447)   // #f6cf72
    static let indigo = Color(red: 0.231, green: 0.290, blue: 0.549) // #3b4a8c

    /// The two-colour name as one piece of text, so it fits wherever a Text does.
    static func name(onLight: Bool = false) -> Text {
        Text("io").foregroundColor(gold).fontWeight(.bold) + Text("pix").foregroundColor(onLight ? indigo : .white).fontWeight(.bold)
    }

    /// A sentence with the name in it: "Connect to your iopix".
    static func text(_ before: String, _ after: String = "", onLight: Bool = false) -> Text {
        Text(before) + name(onLight: onLight) + Text(after)
    }
}
