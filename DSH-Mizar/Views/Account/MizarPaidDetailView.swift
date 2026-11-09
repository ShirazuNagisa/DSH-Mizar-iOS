//
//  MizarPaidDetailView.swift
//  DSH-Mizar
//
//  What the paid plan actually buys, in the operator's own words.
//
//  Pushed from the account screen's subscription section -- the row that used to
//  carry the price and now says 详情. The price itself stays on the purchase row
//  below it, where it comes from StoreKit and is localised by Apple; this page is
//  the sentence that says what the money is for.
//
//  The copy is deliberately blunt about the money: it is a cost-sharing plan, not
//  a product with a margin, and saying so is the honest thing to put next to a
//  purchase button.
//

import SwiftUI

struct MizarPaidDetailView: View {
    /// The paragraph, verbatim. Kept as one key so both languages stay one text.
    static let copy = String(
        localized: "Mizar Paid exists to provide what a high-bandwidth server can do: carrying a session's execution as it happens, attachments, and so on. Payment only shares the server cost and can barely be profitable. Free users can still use most features and the free server. Thank you for using it.",
    )

    var body: some View {
        ScrollView {
            Text(Self.copy)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .accessibilityIdentifier("account.subscription.detail.text")
        }
        .navigationTitle(Text("Mizar Paid"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        MizarPaidDetailView()
    }
}
