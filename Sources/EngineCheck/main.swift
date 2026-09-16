import Foundation
import InputCore

let args = CommandLine.arguments
guard args.count == 4 || args.count == 5 else { fatalError("Usage: EngineCheck LIBRARY SHARED_DATA USER_DATA [EVALUATION_FIXTURES]") }
let engine = try Engine(library: args[1], shared: args[2], user: args[3])
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
// Evaluation uses an isolated user directory and never commits or learns samples.
if args.count == 5 {
    var fixtures = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[4]))) as! [[String: Any]]
    for index in fixtures.indices {
        let session = try engine.session(.full)
        check(session.setCandidateCount(9), "evaluation page size")
        for c in (fixtures[index]["pinyin"] as! String).utf8 { session.process(Int32(c)) }
        fixtures[index]["candidates"] = session.candidates.texts
        session.clear()
    }
    let data = try JSONSerialization.data(withJSONObject: fixtures, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    exit(0)
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
    check(firstPage.first?.utf8.contains(where: { $0 >= 0x80 }) == true,
          "\(scheme.title): Chinese remains first for ambiguous lowercase input")
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
    check(session.setEnglishCandidateMinimum(5), "set English minimum length")
    for c in "gith".utf8 { session.process(Int32(c)) }
    check(!session.candidateSlice(offset: 0).contains("GitHub"), "\(scheme.title): hide English below minimum length")
    session.process(117)
    let english = session.candidateSlice(offset: 0)
    check(english.contains("GitHub"), "\(scheme.title): English prefix completion")
    check(session.selectGlobalCandidate(at: english.firstIndex(of: "GitHub")!), "select English completion")
    check(session.takeCommit() == "GitHub", "\(scheme.title): English commit")
    check(session.setEnglishCandidateMinimum(3), "restore English minimum length")
    let second = try engine.session(scheme)
    session.process(110)
    check(second.preedit.text.isEmpty, "independent client sessions")
    session.clear()
    for count in [9, 3, 5] {
        check(session.setCandidateCount(count), "set page size")
        for c in "ni".utf8 { session.process(Int32(c)) }
        let page = session.candidates.texts
        check(page.count == count, "configured page size \(count)")
        session.process(0xff56)
        check(session.candidates.texts.count == count, "configured next page size")
        session.process(0xff55)
        check(session.candidates.texts == page, "configured previous page")
        session.process(Int32(48 + count))
        check(session.takeCommit() == page[count - 1], "configured last numeric selection")
    }
    session.setASCII(true)
    let handled = session.process(97)
    check(!handled || session.takeCommit() == "a", "ASCII pass-through")
    print("PASS: \(scheme.title), Chinese and English candidates, commit, Escape, Backspace, paging, numeric selection, punctuation, session isolation, ASCII")
}
