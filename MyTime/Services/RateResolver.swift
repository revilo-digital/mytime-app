import Foundation

/// Hourly rate precedence: task override → project override → client default.
enum RateResolver {
    static func rate(for task: TaskType?) -> Decimal {
        guard let task else { return 0 }
        if let rate = task.rateOverride { return rate }
        if let rate = task.project?.rateOverride { return rate }
        return task.project?.client?.defaultRate ?? 0
    }

    /// Whether time on this task should count as billable at all.
    static func isBillable(_ task: TaskType?) -> Bool {
        guard let task, let project = task.project else { return false }
        return task.isBillable && project.isBillable
    }
}
