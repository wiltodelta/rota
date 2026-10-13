import Foundation

extension Scheduler {
    public func respond(to request: String, in record: RunRecord, response: SessionResponse) {
        guard isActive(record), active[record.routineID]?.requests?.contains(where: { $0.id == request }) == true
        else { return }
        controls[record.routineID]?.respond(request, response: response)
    }

    func updateRequests(_ requests: [SessionRequest], routineID: String, recordID: UUID) {
        guard var record = active[routineID], record.id == recordID else { return }
        let previous = record.requests?.first?.title
        if record.attention == previous { record.attention = nil }
        record.requests = requests
        if let request = requests.first { record.attention = request.title }
        active[routineID] = record
        saveRecord(record)
        if previous == nil, let request = requests.first {
            notifier?.sessionNotified(record, routine: routine(routineID), title: nil,
                                      text: request.title, needsReply: true)
        }
    }

}
