import SwiftUI
import PDFKit

struct PreviewPlaceholder: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                Spacer()
                VStack(alignment: .leading, spacing: 11) {
                    HStack { Text("QuillTeX").font(.system(size: 11, design: .serif)).foregroundStyle(.tertiary); Spacer() }
                    Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1).padding(.bottom, 20)
                    RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.045)).frame(width: 90, height: 7)
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 1).fill(Color.black.opacity(0.025)).frame(width: i == 3 ? 110 : nil, height: 4)
                    }
                    Spacer()
                    HStack { Spacer(); Text("PDF").font(.system(size: 26, weight: .regular, design: .serif)).foregroundStyle(Color.black.opacity(0.09)); Spacer() }
                    Spacer()
                }.padding(25).frame(width: 190, height: 258)
                    .background(.white, in: RoundedRectangle(cornerRadius: 2))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.035)))
                    .shadow(color: .black.opacity(0.045), radius: 14, y: 4)
                    .accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text("Ready When You Are").font(.system(size: 14, weight: .regular, design: .serif)).foregroundStyle(.secondary)
                    Text("Press ⌘T to typeset the main file").font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
