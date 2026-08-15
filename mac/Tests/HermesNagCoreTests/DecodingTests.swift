import Testing
import Foundation
@testable import HermesNagCore

/// Decoding against the server's actual wire format.
/// The JSON below is copied verbatim from a live response (docs/01-api.md),
/// so a server-side field rename fails here rather than silently in the UI.
@Suite struct DecodingTests {

    @Test func testDecodesRealTaskPayload() throws {
        let json = """
        {
            "id": "3087a259-a412-4251-9106-95b5b38ff0f4",
            "title": "Pay electricity bill",
            "notes": null,
            "due_at": "2026-08-12T13:00:00+00:00",
            "due_at_local": "2026-08-12T18:30:00+05:30",
            "recurrence": null,
            "priority": "must",
            "tags": ["home"],
            "status": "pending",
            "snooze_until": null,
            "escalation_level": 0,
            "ignore_count": 0,
            "snooze_count": 0,
            "no_escape": false,
            "completed_at": null
        }
        """.data(using: .utf8)!

        let task = try JSON.decoder().decode(Task.self, from: json)

        #expect(task.title == "Pay electricity bill")
        #expect(task.priority == .must)
        #expect(task.tags == ["home"])
        #expect(task.status == .pending)
        #expect(!(task.noEscape))
    }

    @Test func testDueAtIsTheSameInstantRegardlessOfOffsetNotation() throws {
        // 13:00Z and 18:30+05:30 are the same moment. The client must treat
        // due_at as canonical and never do arithmetic on the local string.
        let json = """
        {"id":"1","title":"t","due_at":"2026-08-12T13:00:00+00:00",
         "due_at_local":"2026-08-12T18:30:00+05:30","priority":"normal","tags":[],
         "status":"pending","escalation_level":0,"ignore_count":0,
         "snooze_count":0,"no_escape":false}
        """.data(using: .utf8)!

        let task = try JSON.decoder().decode(Task.self, from: json)
        // 2026-08-12T13:00:00Z
        #expect(task.dueAt?.timeIntervalSince1970 == 1786539600)

        // The same instant expressed in IST must decode identically — that
        // equivalence is the whole point of storing UTC on the wire.
        let istJSON = """
        {"id":"1","title":"t","due_at":"2026-08-12T18:30:00+05:30","priority":"normal",
         "tags":[],"status":"pending","escalation_level":0,"ignore_count":0,
         "snooze_count":0,"no_escape":false}
        """.data(using: .utf8)!
        let istTask = try JSON.decoder().decode(Task.self, from: istJSON)
        #expect(istTask.dueAt == task.dueAt)
    }

    @Test func testDecodesFractionalSeconds() throws {
        // /health emits microseconds: "2026-08-12T06:53:16.457808+00:00"
        let json = """
        {"id":"1","title":"t","due_at":"2026-08-12T06:53:16.457808+00:00",
         "priority":"normal","tags":[],"status":"pending","escalation_level":0,
         "ignore_count":0,"snooze_count":0,"no_escape":false}
        """.data(using: .utf8)!

        #expect((try JSON.decoder().decode(Task.self, from: json).dueAt) != nil)
    }

    @Test func testDecodesHealth() throws {
        let json = """
        {"ok":true,"version":"0.1.0","db_ok":true,"hermes_ok":true,
         "now_utc":"2026-08-12T06:53:16.457808+00:00","sse_subscribers":0}
        """.data(using: .utf8)!

        let health = try JSON.decoder().decode(Health.self, from: json)
        #expect(health.ok)
        #expect(health.hermesOk)
        #expect(health.version == "0.1.0")
    }

    @Test func testDecodesDueResponseWithNagLine() throws {
        let json = """
        {"due":[{"id":"abc","title":"Renew domain","priority":"must","level":3,
                 "nag_line":"Renew domain is overdue and it counts.",
                 "due_at":"2026-08-10T03:30:00+00:00"}],
         "count":1,"now_utc":"2026-08-12T06:53:00+00:00"}
        """.data(using: .utf8)!

        let due = try JSON.decoder().decode(DueResponse.self, from: json)
        #expect(due.count == 1)
        #expect(due.due.first?.level == 3)
        #expect(!(due.due.first!.nagLine.isEmpty), "never mute")
    }

    @Test func testDecodesServerErrorShape() throws {
        let json = """
        {"error":{"code":"unauthorized","message":"missing bearer token"}}
        """.data(using: .utf8)!

        let err = try JSON.decoder().decode(APIError.self, from: json)
        #expect(err.error.code == "unauthorized")
    }

    @Test func testDecodesStats() throws {
        let json = """
        {"streak_days":1,"xp":10,"xp_level":0,"completed_7d":1,
         "completion_rate":null,"heatmap":[{"date":"2026-08-12","count":1}]}
        """.data(using: .utf8)!

        #expect(try JSON.decoder().decode(Stats.self, from: json).streakDays == 1)
    }

    @Test func testRejectsDatetimeWithoutOffset() {
        // The server rejects naive datetimes (correction C1); the client must
        // not quietly accept one either.
        let json = """
        {"id":"1","title":"t","due_at":"2026-08-12T18:30:00","priority":"normal",
         "tags":[],"status":"pending","escalation_level":0,"ignore_count":0,
         "snooze_count":0,"no_escape":false}
        """.data(using: .utf8)!

        #expect(throws: (any Error).self) {
            try JSON.decoder().decode(Task.self, from: json)
        }
    }

    @Test func testTaskOverdueHelper() {
        let now = Date()
        let overdue = Task(id: "1", title: "x", dueAt: now.addingTimeInterval(-60))
        let future = Task(id: "2", title: "y", dueAt: now.addingTimeInterval(60))
        let done = Task(id: "3", title: "z", dueAt: now.addingTimeInterval(-60), status: .done)

        #expect(overdue.isOverdue(now: now))
        #expect(!(future.isOverdue(now: now)))
        #expect(!(done.isOverdue(now: now)), "completed tasks are never overdue")
    }
}
