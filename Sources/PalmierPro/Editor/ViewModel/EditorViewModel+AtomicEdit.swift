import Foundation

extension EditorViewModel {
    func withTimelineMutationBatch<T>(_ work: () throws -> T) rethrows -> T {
        timelineMutationBatchDepth += 1
        defer {
            timelineMutationBatchDepth -= 1
            if timelineMutationBatchDepth == 0, timelineMutationBatchNeedsRebuild {
                timelineMutationBatchNeedsRebuild = false
                notifyTimelineChanged()
            }
        }
        return try work()
    }
}
