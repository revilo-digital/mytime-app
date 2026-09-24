import Foundation

/// A task every project gets — like Harvest's "common tasks". Stored as JSON on BusinessSettings.
struct DefaultTask: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var isBillable = true

    /// The tidy list: tasks describe the kind of work; client/project say who it's for,
    /// and specifics (tools, tickets) go in the entry's note.
    static let recommended: [DefaultTask] = [
        DefaultTask(name: "1. Discovery & scoping"),
        DefaultTask(name: "2. Meetings & workshops"),
        DefaultTask(name: "3. Specs & solution design"),
        DefaultTask(name: "4. Engineering & implementation"),
        DefaultTask(name: "5. Testing & QA"),
        DefaultTask(name: "6. Analytics & reporting"),
        DefaultTask(name: "7. Support & maintenance"),
        DefaultTask(name: "8. Documentation & handover"),
        DefaultTask(name: "9. Training"),
        DefaultTask(name: "10. Project management"),
        DefaultTask(name: "11. Presales & new business", isBillable: false),
        DefaultTask(name: "12. Admin", isBillable: false),
    ]
}
