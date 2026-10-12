import Foundation

/// 把一个字符串安全地包成 shell 单引号字面量，用于拼接要交给 `/bin/sh` 的命令。
///
/// 单引号内除 `'` 外一切都是字面量（`$`、反引号、换行、反斜杠都不会被解释），
/// 所以只需把内部的 `'` 转义成 `'\''`（结束引号 → 转义的单引号 → 重新开引号）。
///
/// 放在 iVoxKit 是为了可单测：它是安全相关的纯函数，出错就是命令注入。
public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
