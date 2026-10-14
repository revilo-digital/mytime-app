import Foundation
import SwiftData

/// A client's own client, e.g. Globex for work done through the agency Acme. It tags projects
/// for grouping and subtotals; invoices still go to the client.
@Model
final class EndClient {
    var name: String
    var client: Client?
    var createdAt: Date

    @Relationship(deleteRule: .nullify, inverse: \Project.endClient)
    var projects: [Project] = []

    init(name: String, client: Client) {
        self.name = name
        self.client = client
        self.createdAt = .now
    }
}

/// Projects sharing an end client (or none), for grouped lists.
struct EndClientGroup: Identifiable {
    let endClient: EndClient?
    var projects: [Project]

    var id: PersistentIdentifier? { endClient?.persistentModelID }

    /// Groups projects, keeping their order within each group: projects without an end client
    /// first, then each end client A–Z. `including` adds end clients that have no projects listed.
    static func group(_ projects: [Project], including endClients: [EndClient] = []) -> [EndClientGroup] {
        var groups = endClients.map { EndClientGroup(endClient: $0, projects: []) }
        for project in projects {
            if let i = groups.firstIndex(where: { $0.id == project.endClient?.persistentModelID }) {
                groups[i].projects.append(project)
            } else {
                groups.append(EndClientGroup(endClient: project.endClient, projects: [project]))
            }
        }
        return groups.sorted {
            switch ($0.endClient, $1.endClient) {
            case (_, nil): false
            case (nil, _): true
            case let (a?, b?): a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
    }
}
