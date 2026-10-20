func resampleWaterfallRow(_ bins: [Float], into row: inout [Float]) {
    guard !bins.isEmpty, !row.isEmpty else { return }

    if bins.count >= row.count {
        for column in row.indices {
            let start = column * bins.count / row.count
            let end = (column + 1) * bins.count / row.count
            // Preserve narrow signals when multiple FFT bins share a texture column.
            row[column] = bins[start..<end].max()!
        }
    } else {
        let scale = Float(bins.count - 1) / Float(row.count - 1)
        for column in row.indices {
            let source = Float(column) * scale
            let index = min(Int(source), bins.count - 1)
            let fraction = source - Float(index)
            let next = bins[min(index + 1, bins.count - 1)]
            row[column] = bins[index] + (next - bins[index]) * fraction
        }
    }
}
