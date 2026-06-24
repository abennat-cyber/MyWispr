import SwiftUI

private struct LanguageRow: View {
    let lang: WhisperLanguage
    let isAdded: Bool

    var body: some View {
        HStack {
            Text(lang.displayName)
            Spacer()
            if lang == .auto {
                Text("default")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if isAdded {
                Image(systemName: "checkmark")
                    .foregroundColor(.accentColor)
                    .fontWeight(.semibold)
            }
        }
    }
}

struct LanguageAddView: View {
    let existing: [WhisperLanguage]
    let onAdd: (WhisperLanguage) -> Void
    @Binding var isPresented: Bool

    @State private var search: String = ""

    private var available: [WhisperLanguage] {
        WhisperLanguage.allCases
            .filter { $0 != .auto }
            .filter { lang in
                search.isEmpty || lang.displayName.localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Language")
                    .font(.headline)
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.escape)
            }
            .padding()

            Divider()

            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search languages…", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.quaternary.opacity(0.5))

            Divider()

            List(available) { lang in
                let isAdded = existing.contains(lang)
                LanguageRow(lang: lang, isAdded: isAdded)
                    .contentShape(Rectangle())
                    .background(isAdded ? Color.accentColor.opacity(0.08) : Color.clear)
                    .onTapGesture {
                        if !isAdded {
                            onAdd(lang)
                            isPresented = false
                        }
                    }
            }
            .listStyle(.plain)
        }
        .frame(width: 340, height: 440)
    }
}
