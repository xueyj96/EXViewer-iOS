import Foundation
import SwiftSoup

/// The current settings form stays in memory so a rename preserves the other
/// account preferences, including fields introduced by the site later.
public struct FavoriteSettingsForm: Sendable {
    public let site: GallerySite
    public let names: [String]
    private let fields: [(String, String)]
    private let nameLimits: [Int]

    public static func endpoint(for site: GallerySite) -> URL {
        site.baseURL.appendingPathComponent("uconfig.php")
    }

    public static func read(_ html: String, site: GallerySite) throws -> Self {
        try EHParser.check(html)
        let url = endpoint(for: site)
        let document = try SwiftSoup.parse(html, url.absoluteString)
        guard let first = try document.select("input[name=favorite_0]").first() else { throw ViewerError.layoutChanged }
        var ancestor = first.parent()
        while ancestor != nil && ancestor?.tagName() != "form" { ancestor = ancestor?.parent() }
        guard let form = ancestor, try form.attr("method").lowercased() == "post" else { throw ViewerError.layoutChanged }
        let rawAction = try form.attr("action")
        if !rawAction.isEmpty {
            guard let action = URL(string: rawAction, relativeTo: url)?.absoluteURL,
                  action.scheme == "https", action.host == site.host, action.path == url.path,
                  action.query == nil else { throw ViewerError.restricted }
        }

        var names: [String] = []
        var limits: [Int] = []
        for index in 0...9 {
            let matches = try form.select("input[name=favorite_\(index)]")
            guard matches.count == 1, let input = matches.first(), !input.hasAttr("disabled") else { throw ViewerError.layoutChanged }
            names.append(try input.val())
            limits.append(Int(try input.attr("maxlength")).flatMap { (1...200).contains($0) ? $0 : nil } ?? 20)
        }

        var fields: [(String, String)] = []
        for control in try form.select("input[name], select[name], textarea[name]") {
            guard !control.hasAttr("disabled") else { continue }
            let name = try control.attr("name")
            guard !name.isEmpty else { continue }
            switch control.tagName() {
            case "select":
                let options = try control.select("option:not([disabled])")
                let selected = options.filter { $0.hasAttr("selected") }
                let values = selected.isEmpty && !control.hasAttr("multiple") ? Array(options.prefix(1)) : selected
                for option in values { fields.append((name, try option.hasAttr("value") ? option.attr("value") : option.text())) }
            case "textarea": fields.append((name, try control.val()))
            default:
                let type = try control.attr("type").lowercased()
                if ["submit", "button", "reset", "image", "file"].contains(type) { continue }
                if ["checkbox", "radio"].contains(type) && !control.hasAttr("checked") { continue }
                let value = try control.hasAttr("value") ? control.attr("value") : (["checkbox", "radio"].contains(type) ? "on" : "")
                fields.append((name, value))
            }
        }
        guard try form.select("input[type=submit][name=apply], button[type=submit][name=apply]").count == 1,
              fields.count <= 1_024, fields.allSatisfy({ $0.0.count <= 100 && $0.1.utf8.count <= 32_768 }) else { throw ViewerError.layoutChanged }
        fields.append(("apply", "Apply"))
        return Self(site: site, names: names, fields: fields, nameLimits: limits)
    }

    public func requestRenaming(group: Int, to name: String) throws -> GalleryFavoriteRequest {
        guard (0...9).contains(group) else { throw ViewerError.invalidQuery("请选择有效的收藏分组") }
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= nameLimits[group],
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw ViewerError.invalidQuery("分组名称需为 1 至 \(nameLimits[group]) 个字符")
        }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: safe)!.replacingOccurrences(of: "%20", with: "+") }
        let body = fields.map { key, original in
            encode(key) + "=" + encode(key == "favorite_\(group)" ? value : original)
        }.joined(separator: "&")
        return GalleryFavoriteRequest(url: Self.endpoint(for: site), body: Data(body.utf8))
    }
}
