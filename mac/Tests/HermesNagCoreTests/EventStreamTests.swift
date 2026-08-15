import Testing
import Foundation
@testable import HermesNagCore

/// The SSE frame parser — pure, so tested without any networking.
///
/// The frames below mirror the server's real output (events.py `sse_format`
/// and the 15s `: heartbeat`).
@Suite struct SSEParserTests {

    private func feed(_ lines: [String]) -> [SSEvent] {
        var parser = SSEParser()
        return lines.compactMap { parser.consume(line: $0) }
    }

    @Test func parsesTheServersRealFrameShape() {
        // Exactly what /events emits for a task event.
        let events = feed([
            "event: task.created",
            "data: {\"id\": \"abc\", \"title\": \"buy milk\"}",
            "",
        ])
        #expect(events.count == 1)
        #expect(events[0].name == "task.created")
        #expect(events[0].data.contains("buy milk"))
    }

    @Test func heartbeatsProduceNothing() {
        // One every 15s keeps the tunnel from idling out; they must never
        // reach the app as events.
        #expect(feed([": heartbeat", "", ": heartbeat", ""]).isEmpty)
    }

    @Test func worksWithoutBlankLines() {
        // AsyncLineSequence is known to swallow empty lines — the parser must
        // not depend on frame terminators arriving at all.
        let events = feed([
            "event: task.created",
            "data: {\"id\": \"1\"}",
            "event: task.changed",
            "data: {\"id\": \"2\"}",
        ])
        #expect(events.map(\.name) == ["task.created", "task.changed"])
    }

    @Test func dataWithoutEventNameIsAGenericMessage() {
        let events = feed(["data: hello"])
        #expect(events == [SSEvent(name: "message", data: "hello")])
    }

    @Test func eventNameDoesNotLeakIntoTheNextFrame() {
        // After task.created fires, a bare data frame must not inherit its name.
        let events = feed([
            "event: task.created",
            "data: {}",
            "data: stray",
        ])
        #expect(events.map(\.name) == ["task.created", "message"])
    }

    @Test func blankLineResetsAPendingEventName() {
        let events = feed([
            "event: task.created",
            "",              // frame abandoned without data
            "data: later",
        ])
        #expect(events.map(\.name) == ["message"])
    }

    @Test func helloFrameParsesLikeAnyOther() {
        // EventStream filters `hello`; the parser itself must stay neutral.
        let events = feed(["event: hello", "data: {\"version\": \"0.1.0\"}"])
        #expect(events.first?.name == "hello")
    }

    @Test func whitespaceAfterColonsIsTrimmed() {
        let events = feed(["event:   task.due  ", "data:   x  "])
        #expect(events == [SSEvent(name: "task.due", data: "x")])
    }
}

/// URL construction — the habits-404 regression.
@Suite struct APIClientURLTests {

    let client = APIClient(config: .init(baseURL: URL(string: "http://127.0.0.1:8787")!),
                           tokenProvider: { "t" })

    @Test func queryStringSurvivesURLBuilding() {
        // appendingPathComponent percent-encoded the '?', turning this into
        // the literal path /habits%3Factive=true — a 404 that silently killed
        // the entire habits feature in the app.
        let url = client.url(for: "habits?active=true&continuous_minutes=5")
        #expect(url.absoluteString == "http://127.0.0.1:8787/habits?active=true&continuous_minutes=5")
        #expect(!url.absoluteString.contains("%3F"))
    }

    @Test func plainPathsAreUntouched() {
        #expect(client.url(for: "tasks").absoluteString == "http://127.0.0.1:8787/tasks")
    }

    @Test func nestedPathsWork() {
        #expect(client.url(for: "tasks/abc/complete").path == "/tasks/abc/complete")
    }
}
