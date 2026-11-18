import AppKit

@MainActor
extension BubblePanelController {
    func verifyIncrementalRows(on area: CGRect) {
        defer { retire() }
        let anchor = CGRect(x: area.midX - 280, y: area.minY + 80, width: 560, height: 70)
        func present(_ items: [SavedBubble]) {
            show(bubbles: items, anchor: anchor, screen: area, hostFrame: area)
        }

        let chat = "thread:2dc4b7c3-1104-43bf-94c3-bfb4591b4721"
        let firstThousand = (1...1000).map { (number: Int) in
            SavedBubble(text: "Review change \(number)", chatKey: chat, number: number)
        }
        present(firstThousand)
        let original = pills
        let extra = SavedBubble(text: "Write the release notes.", chatKey: chat, number: 1001)
        present([extra] + firstThousand)
        precondition(pills.count == 1001 && zip(pills, original).allSatisfy { $0 === $1 })
        precondition(scroll.documentVisibleRect.intersects(pills[1000].frame))

        let captionWidth = pills[0].preferredCellSize.width
        setStyle(.numbers)
        precondition(pills[0] === original[0] && pills[0].preferredCellSize.width < captionWidth)
        setStyle(.shortCaptions)
        precondition(pills[0].preferredCellSize.width == captionWidth)

        var remaining = firstThousand
        remaining.remove(at: 1)
        present(remaining)
        precondition(original[1].superview == nil)
        precondition(pills[0] === original[0] && pills[1] === original[2])
        present(firstThousand)
        precondition(pills[1] !== original[1] && pills[2] === original[2])

        let replacement = SavedBubble(id: firstThousand[0].id, text: "Review the latest diff.", chatKey: chat, number: 1)
        present([replacement] + firstThousand.dropFirst())
        precondition(original[0].superview == nil && pills[0].fullText == replacement.text)
        precondition(pills[2] === original[2])
        present([])
        precondition(pills.isEmpty && original.allSatisfy { $0.superview == nil })
        print("Passed row insertion, removal, restoration, replacement, style measurements and reuse of 1,000 native buttons.")
    }
}
