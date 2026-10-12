extension Array where Element: Hashable {
    /// Returns the elements in their original order, keeping only the first occurrence of each.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
