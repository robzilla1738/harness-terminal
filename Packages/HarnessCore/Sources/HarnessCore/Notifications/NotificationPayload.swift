import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum NotificationPayload {
    public static func request(notice: NotificationNotice, sink: NotificationSink, credentials: [String: String]) throws -> URLRequest {
        try sink.validate()
        let title = sink.includeMessages ? notice.title : "Harness"
        var message = sink.includeMessages && !notice.message.isEmpty ? notice.message : notice.minimalMessage
        if sink.includeRepository, let repository = notice.repository { message += "\nRepository: " + repository }
        var request: URLRequest
        switch sink.kind {
        case .ntfy:
            guard let url = URL(string: sink.endpoint), let topic = sink.topic else { throw NotificationPolicyError.endpoint }
            request = URLRequest(url: url)
            request.httpBody = try JSONSerialization.data(withJSONObject: ["topic": topic, "title": title, "message": message, "priority": 3])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try setBearer(credentials, request: &request)
        case .pushover:
            guard let token = credentials["token"], let user = credentials["user"], !token.isEmpty, !user.isEmpty else { throw NotificationPolicyError.credential }
            request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
            let values = ["token": token, "user": user, "title": title, "message": message, "priority": "0"]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            request.httpBody = Data(values.keys.sorted().map { key in
                key + "=" + (values[key]!.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
            }.joined(separator: "&").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        case .webhook:
            guard let endpoint = credentials["endpoint"], let parts = URLComponents(string: endpoint),
                  parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil, parts.fragment == nil,
                  let url = parts.url else { throw NotificationPolicyError.endpoint }
            request = URLRequest(url: url)
            var payload: [String: Any] = ["schema": "harness.notification.v1", "id": notice.id.uuidString,
                "event": notice.event.rawValue, "at": notice.at.formatted(.iso8601), "message": message]
            if let provider = notice.provider { payload["provider"] = provider }
            if let run = notice.runID { payload["run"] = run.uuidString }
            if let surface = notice.surfaceID { payload["surface"] = surface }
            if sink.includeMessages { payload["title"] = title }
            if sink.includeRepository, let repository = notice.repository { payload["repository"] = repository }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            try setBearer(credentials, request: &request)
        }
        request.httpMethod = "POST"; request.timeoutInterval = 10
        return request
    }
    private static func setBearer(_ credentials: [String: String], request: inout URLRequest) throws {
        guard let token = credentials["token"] else { return }
        guard !token.isEmpty, !token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw NotificationPolicyError.credential }
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
    }
}
