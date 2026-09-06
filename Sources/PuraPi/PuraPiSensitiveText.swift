import Foundation

/// 用户可见错误的统一敏感信息清洗器。
/// Provider 返回的 HTTP body 可能包含 token，即使错误来自普通 Pi RPC 也不能原样展示。
enum PuraPiSensitiveText {
    static func redacted(_ value: String, limit: Int = 2_000) -> String {
        // 先限制正则处理的输入，避免异常响应体很大时清洗本身占用过多内存。
        var result = String(value.prefix(max(1, limit * 16)))
        let fieldPattern = #"(?i)([\"']?(?:access[_ -]?token|refresh[_ -]?token|id[_ -]?token|api[_ -]?key|auth(?:orization)?|client[_ -]?secret|oauth[_ -]?token|password|secret|credential)[\"']?\s*[:=]\s*)(?:(?:Bearer|Basic)\s+[^\s,;\]}]+|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\s,;\]}]+)"#
        result = result.replacingOccurrences(
            of: fieldPattern,
            with: "$1[已隐藏]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\bsk-[A-Za-z0-9_-]+\b"#,
            with: "[凭据已隐藏]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\beyJ[A-Za-z0-9_-]+\b"#,
            with: "[令牌已隐藏]",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"\b(?:Bearer|Basic)\s+[^\s,;\]}]+"#,
            with: "[认证信息已隐藏]",
            options: [.regularExpression, .caseInsensitive]
        )
        result = result.replacingOccurrences(
            of: #"([?&](?:code|state|token|key|secret|authorization)=)[^&\s\"'<>]+"#,
            with: "$1[已隐藏]",
            options: [.regularExpression, .caseInsensitive]
        )
        return String(result.prefix(max(1, limit)))
    }

    static func redacted(_ error: Error, limit: Int = 2_000) -> String {
        redacted(error.localizedDescription, limit: limit)
    }
}
