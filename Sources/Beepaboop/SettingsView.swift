import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var store: NotificationStore
    @ObservedObject var icons: IconRuleStore

    var body: some View {
        TabView {
            GeneralSettings(store: store, chime: store.chime)
                .tabItem { Label("General", systemImage: "gearshape") }
            IconSettings(icons: icons)
                .tabItem { Label("Project Icons", systemImage: "photo.on.rectangle") }
        }
        .frame(width: 560)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var store: NotificationStore
    @ObservedObject var chime: ChimePlayer

    var body: some View {
        Form {
            Section {
                // Single source of truth on the store, so the menu's toggle and
                // this one always agree.
                Toggle("Launch at login", isOn: Binding(
                    get: { store.launchAtLogin },
                    set: { _ in store.toggleLaunchAtLogin() }
                ))
                Toggle("Keep missed notifications as pills", isOn: $store.pillsEnabled)
                    .help("Notifications you don't act on stay as compact pills at the top of the screen until you jump to the session, dismiss them, or visit the pane.")
            }

            Section {
                // One compact row of small checkboxes (System Settings style)
                // instead of five full-height switch rows.
                LabeledContent("Show notifications for") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Claude finished (Stop)", isOn: store.bindingForKind(.stop))
                        Toggle("Waiting for input", isOn: store.bindingForKind(.idle))
                        Toggle("Permission prompts", isOn: store.bindingForKind(.permission))
                        Toggle("Errors", isOn: store.bindingForKind(.error))
                        Toggle("Info", isOn: store.bindingForKind(.info))
                    }
                    .toggleStyle(.checkbox)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section("Chimes") {
                Toggle("Play chimes", isOn: Binding(
                    get: { !chime.muted }, set: { chime.muted = !$0 }
                ))
                HStack {
                    Slider(value: $chime.volume, in: 0.1...1.0) { Text("Volume") }
                        .disabled(chime.muted)
                    Button {
                        chime.play(for: .stop)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(chime.muted)
                    .help("Preview")
                }
            }

            Section {
                LabeledContent("Auto-dismiss after") {
                    Stepper(value: $store.dismissDuration, in: 3...60, step: 1) {
                        Text("\(Int(store.dismissDuration)) s")
                            .monospacedDigit()
                    }
                }
                LabeledContent("Permission prompt timeout") {
                    Stepper(value: $store.permissionTimeout, in: 3...14, step: 1) {
                        Text("\(Int(store.permissionTimeout)) s")
                            .monospacedDigit()
                    }
                }
            } header: {
                Text("Timing")
            } footer: {
                Text("After the timeout, Claude Code falls back to its native prompt in the terminal.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
    }
}

// MARK: - Project icons

private struct IconSettings: View {
    @ObservedObject var icons: IconRuleStore
    @State private var selection: Set<UUID> = []
    @State private var importingRule: UUID?
    @State private var importError: String?

    var body: some View {
        Form {
            Section {
                ruleTable
            } header: {
                Text("Project Icons")
            } footer: {
                Text("Each rule's regex is matched against the directory the Claude session runs in. The first matching rule (top to bottom — drag to reorder) shows its icon on the overlay. PNG, JPEG, and SVG work.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .fileImporter(
            isPresented: Binding(
                get: { importingRule != nil },
                set: { if !$0 { importingRule = nil } }
            ),
            allowedContentTypes: [.png, .jpeg, .svg, .image]
        ) { result in
            defer { importingRule = nil }
            guard let id = importingRule,
                  let idx = icons.rules.firstIndex(where: { $0.id == id }),
                  case .success(let url) = result else { return }
            do {
                icons.rules[idx].iconFile = try icons.importImage(from: url)
            } catch {
                importError = error.localizedDescription
            }
        }
        .alert("Couldn't import image", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }

    private var ruleTable: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach($icons.rules) { $rule in
                    ruleRow($rule)
                        .tag(rule.id)
                }
                .onMove { from, to in
                    icons.rules.move(fromOffsets: from, toOffset: to)
                }
            }
            .listStyle(.plain)
            .frame(height: 240)

            Divider()

            // Native-style gradient-button footer (+ / −).
            HStack(spacing: 0) {
                Button {
                    let rule = ProjectIconRule()
                    icons.rules.append(rule)
                    selection = [rule.id]
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                Divider().frame(height: 16)
                Button {
                    icons.rules.removeAll { selection.contains($0.id) }
                    selection = []
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .disabled(selection.isEmpty)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(2)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func ruleRow(_ rule: Binding<ProjectIconRule>) -> some View {
        let r = rule.wrappedValue
        HStack(spacing: 10) {
            // Icon well — click to choose/replace the image.
            Button {
                importingRule = r.id
            } label: {
                Group {
                    if let file = r.iconFile, let img = icons.image(named: file) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.quaternary.opacity(0.5))
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help(r.iconFile == nil ? "Choose an image" : "Replace the image")

            TextField("path regex, e.g.  work/backend|api-server", text: rule.pattern)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()

            if !r.pattern.isEmpty && !icons.isValidPattern(r.pattern) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .help("Invalid regular expression")
            }
        }
        .padding(.vertical, 2)
    }
}
