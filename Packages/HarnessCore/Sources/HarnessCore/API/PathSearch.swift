import Foundation

public enum PathSearch {
    public static func ranked(_ entries: [PaneDirEntry], query: String) -> [PaneDirEntry] {
        let needle = Array(query.lowercased())
        return entries.compactMap { entry -> (PaneDirEntry, Int)? in
            guard !needle.isEmpty else { return (entry, 0) }
            var next = 0, score = 0, last = -2
            let name = Array(entry.name.lowercased())
            for (index, character) in name.enumerated() where character == needle[next] {
                score += last + 1 == index ? 8 : 1
                if index == 0 || "/_- .".contains(name[index - 1]) { score += 12 }
                last = index; next += 1
                if next == needle.count { return (entry, score - name.count / 8) }
            }
            return nil
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.directory != $1.0.directory { return $0.0.directory }
            return $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending
        }.map(\.0)
    }
}
