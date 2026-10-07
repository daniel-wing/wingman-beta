import SwiftUI

/// Credits for the open-source software and models Wingman uses, from the
/// THIRD_PARTY_NOTICES.md bundled with the app.
struct AcknowledgementsView: View {
    private let text: AttributedString = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return AttributedString("Acknowledgements are missing from this build.") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: raw, options: options)) ?? AttributedString(raw)
    }()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(minWidth: 480, minHeight: 400)
    }
}
