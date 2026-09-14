public enum CandidateGrid {
    public static func pageRange(index: Int, count: Int, rows: Int, columns: Int = 5) -> Range<Int> {
        guard count > 0, rows > 0, columns > 0 else { return 0..<0 }
        let size = rows * columns
        let start = min(count - 1, max(0, index)) / size * size
        return start..<min(count, start + size)
    }
    public static func move(index: Int, count: Int, rows: Int, horizontal: Int, vertical: Int) -> Int {
        guard count > 0, rows > 0 else { return 0 }
        let current = min(count - 1, max(0, index))
        let column = min((count - 1) / rows, max(0, current / rows + horizontal))
        let row = min(min(rows - 1, count - 1 - column * rows), max(0, current % rows + vertical))
        return column * rows + row
    }
}
