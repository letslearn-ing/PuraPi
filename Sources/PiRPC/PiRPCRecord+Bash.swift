import Foundation

/// `bash` 命令与 `bash_execution_update` 事件的字段解析。
///
/// 单独成文件：`PiRPCProtocol.swift` 已接近 800 行预警线，bash 是自成一体的
/// 一组字段，按职责分出来比继续堆叠更清晰。
extension PiRPCRecord {
    // MARK: - bash

    /// `bash_execution_update` 的输出增量。
    public var bashOutputDelta: String? {
        guard type == "bash_execution_update" else { return nil }
        return string(at: "delta")
    }

    /// `bash` 响应的退出码。
    ///
    /// 注意：非零退出码仍然是 `success: true`——命令成功执行了，只是返回失败。
    /// 判断命令是否失败必须看这个值，不能只看 `success`。
    public var bashExitCode: Int? {
        value(at: "data", "exitCode")?.intValue.map(Int.init)
    }

    public var bashOutput: String? {
        string(at: "data", "output")
    }

    public var bashWasCancelled: Bool {
        value(at: "data", "cancelled")?.boolValue == true
    }

    public var bashOutputTruncated: Bool {
        value(at: "data", "truncated")?.boolValue == true
    }

    /// 输出被截断时，完整日志的文件路径。
    public var bashFullOutputPath: String? {
        string(at: "data", "fullOutputPath")
    }
}
