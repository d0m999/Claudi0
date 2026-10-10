import ClaudioCore
import Foundation

@MainActor
func runZedPTYBridgeSuites() {
    suite("Zed PTY：分块焦点报告与原始输入透传") {
        var filter = ZedPTYInputFilter()
        let first = filter.consume(Data("中文\u{1B}[".utf8), forwardFocus: false)
        expect(first.bytes == Data("中文".utf8), "UTF-8 输入不能丢失")
        expect(first.focus.isEmpty, "不把半条 escape sequence 当回执")
        let second = filter.consume(
            Data("Iabc\u{1B}[O\u{1B}[200~paste\u{1B}[201~".utf8), forwardFocus: false)
        expect(second.focus == [true, false], "完整报告按收到的顺序输出")
        expect(second.bytes == Data("abc\u{1B}[200~paste\u{1B}[201~".utf8), "焦点之外的键盘与粘贴字节保持原样")
        let third = filter.consume(Data("\u{1B}[I".utf8), forwardFocus: true)
        expect(third.bytes == Data("\u{1B}[I".utf8), "需要焦点报告的真实 CLI 仍能收到报告")
        expect(!third.hasInput, "转发给 CLI 的焦点回执不伪装成用户键盘干预")
        _ = filter.consume(Data([0x1B]), forwardFocus: false)
        expect(filter.finish() == Data([0x1B]), "退出时恢复不完整普通输入")
        let pasted = Data("\u{1B}[200~\u{1B}[I\u{1B}[201~".utf8)
        let pasteResult = filter.consume(pasted, forwardFocus: false)
        expect(pasteResult.bytes == pasted && pasteResult.focus.isEmpty, "粘贴的 escape 文本不是焦点回执")
        expect(pasteResult.hasInput, "普通输入或粘贴撤销自动导航")
        _ = filter.consume(Data([0x1B]), forwardFocus: false)
        expect(
            filter.hasPending && filter.flushPending() == Data([0x1B]), "单独 Escape 可以按短等待原样送入 TUI")
    }
    suite("Zed PTY：虚拟化子进程的 focus-report mode") {
        var filter = ZedPTYOutputFilter()
        let first = filter.consume(Data("a\u{1B}[?25;1004h".utf8))
        expect(first.bytes == Data("a\u{1B}[?25h".utf8), "保留其他 DEC mode，只拦截 1004")
        expect(filter.childWantsFocus, "子进程请求被记住")
        let query = filter.consume(Data("\u{1B}[?1004$p".utf8))
        expect(query.bytes.isEmpty, "子进程不能查询并混淆外层 mode")
        expect(query.reply == Data("\u{1B}[?1004;1$y".utf8), "报告子进程自己的 mode")
        let reset = filter.consume(Data("\u{1B}[?1004lEND\u{1B}[31m".utf8))
        expect(
            reset.bytes == Data("END\u{1B}[31m".utf8) && !filter.childWantsFocus,
            "CLI 关 mode 不会关闭桥接的回执")
        let disabled = filter.consume(Data("\u{1B}[?1004$p".utf8))
        expect(disabled.reply == Data("\u{1B}[?1004;2$y".utf8), "关 mode 的查询结果正确")
        let ordinary = Data("\u{1B}]2;title\u{7}\u{1B}[?2004h".utf8)
        expect(filter.consume(ordinary).bytes == ordinary, "OSC、颜色和 bracketed paste 都透传")
        let ris = filter.consume(Data("\u{1B}c".utf8))
        expect(ris.bytes == Data("\u{1B}c\u{1B}[?1004h".utf8), "terminal reset 后恢复桥接焦点 mode")
        _ = filter.consume(Data("\u{1B}[?01004h".utf8))
        expect(filter.childWantsFocus, "合法 mode 的前导零不破坏虚拟化")
        expect(
            filter.consume(Data("\u{1B}[?01004$p".utf8)).reply == Data("\u{1B}[?1004;1$y".utf8),
            "前导零查询仍报告虚拟 mode")
        _ = filter.consume(Data("\u{1B}[?1004s\u{1B}[?1004l".utf8))
        let restored = filter.consume(Data("\u{1B}[?1004r".utf8))
        expect(restored.bytes.isEmpty && filter.childWantsFocus, "保存/恢复私有 mode 不改变外层焦点协议")
        let opaqueStart = Data("\u{1B}]2;".utf8)
        let opaqueBody = Data("\u{1B}[?1004l".utf8)
        expect(filter.consume(opaqueStart).bytes == opaqueStart, "控制字符串头透传")
        expect(
            filter.consume(opaqueBody).bytes == opaqueBody && filter.childWantsFocus,
            "跨分块 OSC 内容不被当 mode 命令")
        expect(filter.consume(Data([7])).bytes == Data([7]), "OSC 正常结束")
    }
    suite("Zed PTY：任意分块与有界不完整 CSI") {
        let source = Data("abc\u{1B}[?25;1004habc\u{1B}[?1004labc\u{1B}[?2004h中文".utf8)
        var reference = ZedPTYOutputFilter()
        let expected = reference.consume(source).bytes + reference.finish()
        for split in 0...source.count {
            var filter = ZedPTYOutputFilter()
            let result =
                filter.consume(source.prefix(split)).bytes
                + filter.consume(source.dropFirst(split)).bytes + filter.finish()
            expect(result == expected, "任意分块不改变透传结果：\(split)")
        }
        var input = ZedPTYInputFilter()
        let longCSI = Data([0x1B, 0x5B] + Array(repeating: 0x31, count: 2048))
        expect(
            input.consume(longCSI, forwardFocus: false).bytes + input.finish() == longCSI,
            "超长未知 CSI 有界且不丢字节")
    }
}
