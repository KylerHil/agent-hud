import AgentHUDCore
import AppKit
import SwiftUI

struct PortsView: View {
    let app: AppModel
    @Bindable var ports: PortsModel
    var forSnapshot = false

    var body: some View {
        VStack(spacing: 0) {
            title
            search
            filters
            Divider().opacity(0.6)
            if forSnapshot { content; Spacer(minLength: 0) }
            else { ScrollView(.vertical) { content }.scrollIndicators(.automatic) }
            if let message = ports.message { feedback(message) }
            footer
        }
        .onChange(of: ports.includeUDP) { if !forSnapshot { Task { await ports.refresh() } } }
        .alert(ports.pendingStop.map(stopTitle) ?? "Stop service?",
               isPresented: Binding(get: { ports.pendingStop != nil }, set: { if !$0 { ports.pendingStop = nil } }),
               presenting: ports.pendingStop) { request in
            Button("Cancel", role: .cancel) { ports.pendingStop = nil }
            Button(stopLabel(request), role: .destructive) { ports.confirmStop(request) }
        } message: { request in Text(stopDescription(request)) }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text("Ports").font(.system(size: 18, weight: .semibold))
            Spacer(minLength: 4)
            if ports.refreshing { ProgressView().controlSize(.mini).accessibilityLabel("Scanning ports") }
            Menu {
                Toggle("Include UDP ports", isOn: $ports.includeUDP)
                Text("TCP listeners\(ports.includeUDP ? " and bound UDP sockets" : "") on this Mac")
                if ports.snapshot.restrictedProcesses > 0 {
                    Divider()
                    Text("Some process sockets could not be read. Discovery may be incomplete.")
                }
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(ports.hasLoaded ? Color.green : Color.secondary).frame(width: 5, height: 5)
                    Text(ports.hasLoaded ? "\(ports.count(ports.source)) \(ports.includeUDP ? "ports" : "listening")" : "Scanning…")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Choose whether to include UDP ports")
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 12)
    }

    private var search: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(.secondary)
            TextField("Search ports or projects…", text: $ports.query)
                .textFieldStyle(.plain).font(.system(size: 11.5))
                .accessibilityLabel("Find a port, project, or process")
            if !ports.query.isEmpty {
                Button { ports.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Clear port search").accessibilityLabel("Clear port search")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.10)))
        .padding(.horizontal, 13).padding(.bottom, 9)
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            filterRow(PortsModel.Source.allCases)
            VStack(alignment: .leading, spacing: 4) {
                filterRow(PortsModel.Source.allCases.filter { $0 != .editor })
                HStack(spacing: 6) {
                    filterButton(.editor)
                    Spacer(minLength: 0)
                    Text("Hidden from All").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 9)
    }

    private func filterRow(_ sources: [PortsModel.Source]) -> some View {
        HStack(spacing: 3) {
            ForEach(sources, id: \.self) { source in filterButton(source) }
            Spacer(minLength: 0)
        }
    }

    private func filterButton(_ source: PortsModel.Source) -> some View {
        Button { ports.source = source } label: {
            HStack(spacing: 4) {
                Text(source.rawValue).fontWeight(ports.source == source ? .semibold : .regular)
                Text("\(ports.count(source))").opacity(0.7).font(.system(size: 9))
            }
            .font(.system(size: 10.5)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(ports.source == source ? Color.accentColor.opacity(0.10) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain).fixedSize()
        .foregroundStyle(ports.source == source ? Color.accentColor : Color.secondary)
        .accessibilityAddTraits(ports.source == source ? .isSelected : [])
        .help(source == .editor ? "Editor helper ports are hidden from All. Show them here."
              : source == .all ? "All listeners except editor internals" : source.rawValue)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if let notice = ports.snapshot.docker.message, ports.hasLoaded {
                Text(notice).font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                    .padding(.top, 8)
            }
            if ports.rows.isEmpty {
                empty
            } else {
                ForEach([PortSource.local, .docker, .other, .editor], id: \.self) { source in
                    let rows = ports.rows.filter { $0.source == source }
                    if !rows.isEmpty {
                        HStack {
                            Text(groupTitle(source))
                                .font(.system(size: 10.5, weight: .semibold))
                            Spacer()
                            Text("\(rows.count)\(source == .docker ? " published" : "")").font(.system(size: 9.5))
                        }
                        .foregroundStyle(.secondary).padding(.top, 13).padding(.bottom, 7).padding(.horizontal, 2)
                        ForEach(rows) { row in
                            PortEndpointRow(endpoint: row, ports: ports, forSnapshot: forSnapshot)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "network").font(.system(size: 24)).foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 12, weight: .semibold))
            Text(emptyDescription)
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if ports.hiddenEditorMatches > 0 {
                Button("Show \(ports.hiddenEditorMatches) matching editor ports") { ports.source = .editor }.buttonStyle(.link)
            }
            if !ports.query.isEmpty || ports.source != .all {
                Button("Clear filters") { ports.query = ""; ports.source = .all }.buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 35)
    }

    private var emptyTitle: String {
        if !ports.hasLoaded { return "Looking for listening ports…" }
        if !ports.query.isEmpty { return "No matching ports" }
        if ports.source == .docker && ports.snapshot.docker.message != nil { return "Docker ports unavailable" }
        if ports.source != .all { return "No ports in this filter" }
        if ports.count(.editor) > 0 { return "No visible ports" }
        return "No listening ports"
    }

    private var emptyDescription: String {
        if ports.source == .docker && ports.snapshot.docker.message != nil { return "Reconnect Docker, then refresh." }
        if !ports.query.isEmpty { return "Try a project name, process, or another port." }
        if ports.source == .editor { return "Editor helper listeners appear here when available." }
        if ports.count(.editor) > 0 { return "Editor helper ports are available under Editor internals." }
        return "Start a local server to see its port here."
    }

    private func groupTitle(_ source: PortSource) -> String {
        switch source {
        case .local: "Local development"
        case .docker: "Docker containers"
        case .other: "Other listeners"
        case .editor: "Editor internals"
        }
    }

    private func feedback(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: ports.messageIsError ? "exclamationmark.circle" : "checkmark.circle")
            Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            Button { ports.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Dismiss port status").accessibilityLabel("Dismiss port status")
        }
        .font(.system(size: 10.5)).foregroundStyle(ports.messageIsError ? Color.orange : Color.secondary)
        .padding(9).background(Color.primary.opacity(0.04))
        .accessibilityElement(children: .contain)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text("On this Mac")
            Spacer(minLength: 4)
            if ports.hasLoaded {
                Text("Updated \(ports.snapshot.capturedAt.formatted(date: .omitted, time: .shortened))")
                    .help(ports.snapshot.capturedAt.formatted())
            }
        }
        .font(.system(size: 9.5)).foregroundStyle(.secondary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().opacity(0.5) }
    }

    private func stopTitle(_ request: PortStopRequest) -> String {
        "\(request.force ? "Force quit" : "Stop") \(request.endpoint.title)?"
    }
    private func stopLabel(_ request: PortStopRequest) -> String {
        if request.force { return "Force Quit" }
        if request.endpoint.container != nil { return "Stop Container" }
        if request.endpoint.editor != nil { return request.endpoint.owners.count > 1 ? "Stop Editor Helpers" : "Stop Editor Helper" }
        return request.endpoint.owners.count > 1 ? "Stop \(request.endpoint.owners.count) Processes" : "Stop Process"
    }
    private func stopDescription(_ request: PortStopRequest) -> String {
        let target = request.endpoint
        let action: String
        let identity: String
        if let container = target.container {
            action = "Stops this container and all of its published ports. Docker allows up to 10 seconds before forcing it to stop."
            identity = "Container: \(container.name)\nContext: \(container.context)"
        } else {
            action = request.force ? "Ends the selected processes immediately. Pending work may be lost."
                : "Asks the selected processes to quit. All ports they own will close if they exit."
            identity = target.owners.map { "\($0.processName) · PID \($0.pid)" }.joined(separator: "\n")
        }
        let impact = target.editor == nil ? "" : "\n\nThis stops the editor helper and can disconnect extensions or agent integrations in its editor window."
        let bindings = request.affectedBindings.prefix(12).map { "\($0.display) (\($0.transport.rawValue.uppercased()))" }.joined(separator: "\n")
        let more = request.affectedBindings.count > 12 ? "\n…and \(request.affectedBindings.count - 12) more bindings" : ""
        return "\(action)\(impact)\n\n\(identity)\n\nAffected bindings:\n\(bindings)\(more)"
    }
}

private struct PortEndpointRow: View {
    let endpoint: PortEndpoint
    @Bindable var ports: PortsModel
    var forSnapshot: Bool
    private var expanded: Bool { ports.expanded.contains(endpoint.id) }
    private var busy: Bool { ports.busy(endpoint) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    if expanded { ports.expanded.remove(endpoint.id) } else { ports.expanded.insert(endpoint.id) }
                } label: { rowLabel }
                .buttonStyle(.plain)
                .accessibilityLabel("\(endpoint.title), \(endpoint.transport.rawValue.uppercased()) port \(endpoint.port), \(endpoint.subtitle)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                .accessibilityHint("Show or hide process details")
                actions
            }
            .padding(.vertical, 9)
            operationStatus
            if expanded { details }
            Divider().opacity(0.5)
        }
        .contextMenu { contextActions }
    }

    private var rowLabel: some View {
        HStack(spacing: 9) {
            VStack(spacing: 2) {
                Text(String(endpoint.port)).font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                Text(endpoint.transport.rawValue.uppercased()).font(.system(size: 8)).foregroundStyle(.secondary)
            }
            .frame(width: 49, height: 42)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor.opacity(0.13)))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(endpoint.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                Text(subtitle).font(.system(size: 10.5)).foregroundStyle(busy ? Color.orange : Color.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if ports.preparing?.id == endpoint.id { return "Reviewing affected ports…" }
        if case .stopping(let force) = ports.operation(endpoint) {
            return force ? "Force quitting…" : endpoint.container == nil ? "Stopping process…" : "Stopping container…"
        }
        return endpoint.subtitle
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let url = endpoint.browserURL {
                Button { NSWorkspace.shared.open(url) } label: {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11)).frame(width: 23, height: 25)
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 5))
                .help("Open HTTP · \(url.absoluteString)").accessibilityLabel("Open \(endpoint.title) in browser using HTTP")
            }
            Button { if !forSnapshot { ports.prepareStop(endpoint) } } label: {
                HStack(spacing: 4) {
                    Image(systemName: endpoint.stopUnavailableReason == nil ? "stop" : "lock")
                    if endpoint.stopUnavailableReason == nil { Text("Stop") }
                }
                .font(.system(size: 10)).padding(.horizontal, 6).frame(height: 25)
                .foregroundStyle(endpoint.stopUnavailableReason == nil ? Color.red : Color.secondary)
                .background(Color.red.opacity(endpoint.stopUnavailableReason == nil ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.10)))
            }
            .buttonStyle(.plain).disabled(endpoint.stopUnavailableReason != nil || busy)
            .help(endpoint.stopUnavailableReason ?? "Stop \(stopTarget)")
            .accessibilityLabel(endpoint.stopUnavailableReason ?? "Stop \(stopTarget) \(endpoint.title)")
        }
        .fixedSize()
    }

    @ViewBuilder private var operationStatus: some View {
        if case .stillRunning = ports.operation(endpoint) {
            HStack(spacing: 6) {
                Text("Still running. The process didn’t exit.").frame(maxWidth: .infinity, alignment: .leading)
                Button("Force quit…") { if !forSnapshot { ports.prepareStop(endpoint, force: true) } }
                    .buttonStyle(.bordered).controlSize(.mini).disabled(busy || forSnapshot)
            }
            .font(.system(size: 10)).foregroundStyle(.red).padding(7)
            .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 8)
        } else if case .failed(let error) = ports.operation(endpoint) {
            Text(error).font(.system(size: 10)).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading).padding(7)
                .background(Color.red.opacity(0.05), in: RoundedRectangle(cornerRadius: 6)).padding(.bottom, 8)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(endpoint.bindings, id: \.self) { binding in
                detail("\(binding.transport == .tcp ? "Listening" : "Bound") on", binding.display)
            }
            if let container = endpoint.container {
                detail("Container", container.name)
                detail("Container port", "\(container.internalPort)/\(endpoint.transport.rawValue)")
                detail("Docker context", container.context)
            } else {
                ForEach(endpoint.owners, id: \.key) { owner in
                    detail("Process", "\(owner.processName) · PID \(owner.pid)").help(owner.executable)
                }
            }
            if let editor = endpoint.editor {
                detail("Editor", editor.appName)
                detail("Service", editor.role.rawValue)
            }
            if let editor = endpoint.editor, editor.workspaceFolders.count > 1 {
                ForEach(editor.workspaceFolders, id: \.self) { path in folderButton(path) }
            } else if let path = endpoint.project?.path {
                folderButton(path)
            } else if let cwd = endpoint.workingDirectory {
                Text("Working directory: \(shortPath(cwd))").font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).textSelection(.enabled).help(cwd)
            }
            HStack {
                Text(endpoint.project?.evidence ?? "Project not identified").font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button { copyAddresses() } label: { Label("Copy address\(endpoint.bindings.count > 1 ? "es" : "")", systemImage: "doc.on.doc") }
                    .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 9.5))
            }
        }
        .padding(9).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
        .padding(.bottom, 9)
    }

    private var stopTarget: String { endpoint.container != nil ? "container" : endpoint.editor != nil ? "editor helper" : "process" }

    private func folderButton(_ path: String) -> some View {
        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) } label: {
            Label(shortPath(path), systemImage: "folder").font(.system(size: 10)).lineLimit(2).truncationMode(.middle)
        }.buttonStyle(.plain).foregroundStyle(.secondary).help(path)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).font(.system(size: 10, design: .monospaced)).multilineTextAlignment(.trailing).textSelection(.enabled)
        }.font(.system(size: 10))
    }
    private func shortPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    private func copyAddresses() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpoint.bindings.map(\.connectAddress).joined(separator: "\n"), forType: .string)
    }
    @ViewBuilder private var contextActions: some View {
        Button("Copy Address\(endpoint.bindings.count > 1 ? "es" : "")") { copyAddresses() }
        if endpoint.transport == .tcp && endpoint.editor == nil {
            Button("Open HTTP in Browser") { if let url = endpoint.url(scheme: "http") { NSWorkspace.shared.open(url) } }
            Button("Open HTTPS in Browser") { if let url = endpoint.url(scheme: "https") { NSWorkspace.shared.open(url) } }
        }
        Divider()
        Button(endpoint.container != nil ? "Stop Container…" : endpoint.editor != nil ? "Stop Editor Helper…" : "Stop Process…", role: .destructive) {
            if !forSnapshot { ports.prepareStop(endpoint) }
        }.disabled(endpoint.stopUnavailableReason != nil || busy || forSnapshot)
        if case .stillRunning = ports.operation(endpoint) {
            Button("Force Quit…", role: .destructive) { if !forSnapshot { ports.prepareStop(endpoint, force: true) } }
                .disabled(busy || forSnapshot)
        }
    }
}
