import ClaudioCore
import ClaudioGUIComponents
import Foundation

@MainActor
func runTmuxNavigationSuites() {
    suite("tmux navigation：唯一client、内核实例、有界稳定paneID") {
        let identity = HostProcessIdentity(pid: 42, startSeconds: 100, startMicroseconds: 0)
        let process: (Int32) -> HostProcessSnapshot? = { pid in
            pid == 42 ? HostProcessSnapshot(identity: identity, parentPID: 43, userID: 501) : nil
        }
        expect(
            TmuxNavigationAdapter.parseClient("42|/dev/ttys001|$1", process: process, userID: 501)?
                .process == identity,
            "解析唯一client并绑定内核启动时间")
        for text in [
            "", "42|/dev/ttys001|$1\n42|/dev/ttys002|$2", "999|/dev/ttys001|$1", "42|/tmp/x|$1",
            "42|/dev/ttys001|name", "42|/dev/ttys001|$1|extra",
        ] {
            expect(
                TmuxNavigationAdapter.parseClient(text, process: process, userID: 501) == nil,
                "歧义/失效client不得选第一个")
        }
        expect(
            TmuxNavigationAdapter.parseClient("42|/dev/ttys001|$1", process: process, userID: 502)
                == nil,
            "跨用户client拒绝")
        expect(
            TmuxNavigationAdapter.parsePane("$1|@2|%3|/dev/ttys004", paneID: "%3") != nil,
            "稳定pane解析")
        expect(
            TmuxNavigationAdapter.parsePane("$1|@2|%4|/dev/ttys004", paneID: "%3") == nil,
            "错误pane拒绝")
        expect(
            TmuxNavigationAdapter.parsePane("name|window|%3|/dev/ttys004", paneID: "%3") == nil,
            "cwd/title不作为定位标识")
    }
}
