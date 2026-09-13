import Foundation
import InputCore

let args = CommandLine.arguments
 guard args.count == 4 else { fatalError("Usage: EngineCheck LIBRARY SHARED_DATA USER_DATA") }
let engine = try Engine(library: args[1], shared: args[2], user: args[3])
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
for (scheme, input) in [(InputScheme.full, "nihao"), (.flypy, "nihc")] {
    let session = try engine.session(scheme)
    for c in input.utf8 { check(session.process(Int32(c)), "key \(c)") }
    check(session.candidates.texts.contains("你好"), "\(scheme.title): 你好 candidate")
    check(!session.preedit.text.isEmpty, "preedit")
    session.process(32)
    check(session.takeCommit() == "你好", "\(scheme.title): commit")
    for c in (scheme == .full ? "zhongguo" : "vsgo").utf8 { session.process(Int32(c)) }
    session.process(32)
    check(session.takeCommit() == "中国", "simplified output via bundled OpenCC")
    session.process(110); session.process(0xff1b)
    check(session.preedit.text.isEmpty, "Escape clears")
    session.process(110); session.process(0xff08)
    check(session.preedit.text.isEmpty, "Backspace clears")
    for c in "ni".utf8 { session.process(Int32(c)) }
    let firstPage = session.candidates.texts
    check(firstPage.count == 5, "five candidates per page")
    session.process(0xff56)
    check(session.candidates.texts != firstPage, "Page Down changes candidates")
    session.process(0xff55)
    check(session.candidates.texts == firstPage, "Page Up restores candidates")
    session.process(50)
    check(session.takeCommit() == firstPage[1], "numeric candidate selection")
    for c in "ni".utf8 { session.process(Int32(c)) }
    session.process(0xff56)
    let secondPage = session.candidates.texts
    check(!session.selectCandidate(at: -1), "reject negative candidate index")
    check(!session.selectCandidate(at: secondPage.count), "reject out-of-range candidate index")
    check(session.selectCandidate(at: 1), "click candidate on second page")
    check(session.takeCommit() == secondPage[1], "click commits current page candidate")
    session.process(44)
    check(session.takeCommit() == "，", "Chinese punctuation")
    let second = try engine.session(scheme)
    session.process(110)
    check(second.preedit.text.isEmpty, "independent client sessions")
    session.clear()
    session.setASCII(true)
    let handled = session.process(97)
    check(!handled || session.takeCommit() == "a", "ASCII pass-through")
    print("PASS: \(scheme.title), candidates, commit, Escape, Backspace, paging, numeric selection, punctuation, session isolation, ASCII")
}
