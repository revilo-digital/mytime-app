import SwiftData
import SwiftUI

struct ClientsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Client.name) private var clients: [Client]
    @State private var selection: Client?
    @State private var showArchived = false
    @State private var search = ""

    private var visibleClients: [Client] {
        clients.filter { (showArchived || !$0.isArchived) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        NavigationSplitView {
            List(visibleClients, selection: $selection) { client in
                ClientRow(client: client).tag(client)
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Search clients")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(action: addClient) { Label("New Client", systemImage: "plus.circle.fill") }
                        .buttonStyle(.borderless)
                    Spacer()
                    Toggle("Show archived", isOn: $showArchived)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                .padding(12)
                .background(.bar)
            }
        } detail: {
            if let selection {
                ClientDetailView(client: selection, onDelete: { self.selection = nil })
                    .id(selection.persistentModelID)
            } else {
                ContentUnavailableView {
                    Label("No Client Selected", systemImage: "person.2")
                } description: {
                    Text("Pick a client, or create one to start tracking.")
                } actions: {
                    Button("New Client", action: addClient).buttonStyle(.borderedProminent)
                }
            }
        }
        .onAppear { if selection == nil { selection = visibleClients.first } }
    }

    private func addClient() {
        let client = Client(name: "New Client")
        context.insert(client)
        try? context.save()
        selection = client
    }
}

private struct ClientRow: View {
    let client: Client

    private var activeProjects: Int { client.projects.filter { !$0.isArchived }.count }

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: client.name, size: 30, imageData: client.logoData)
                .opacity(client.isArchived ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.name).font(.body.weight(.medium)).lineLimit(1)
                Text(client.isArchived ? "Archived" : "\(activeProjects) project\(activeProjects == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
