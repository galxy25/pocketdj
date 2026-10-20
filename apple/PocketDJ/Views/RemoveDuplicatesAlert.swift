import SwiftUI

/// "Remove duplicates" result alert, shared by the pocket / playlist detail menus and the
/// Collections tab's all-collections action. `removed` non-nil ⇒ shown.
struct RemoveDuplicatesAlert: ViewModifier {
    @Binding var removed: Int?

    func body(content: Content) -> some View {
        content.alert(title, isPresented: Binding(get: { removed != nil }, set: { if !$0 { removed = nil } })) {
            Button("OK") { removed = nil }
        } message: {
            Text("Same song on the same album, listed twice (e.g. the featured artist in the title on one copy, in the artist on the other). Where the copies differed, the one that streams from Apple Music was kept.")
        }
    }

    private var title: String {
        switch removed ?? 0 {
        case 0: return "No duplicates found"
        case 1: return "Removed 1 duplicate"
        case let n: return "Removed \(n) duplicates"
        }
    }
}

extension View {
    func removeDuplicatesAlert(_ removed: Binding<Int?>) -> some View {
        modifier(RemoveDuplicatesAlert(removed: removed))
    }
}
