//! Small shared helpers: edit distance, used both to fuzzy-match header keywords (`layout.rs`)
//! and to cluster near-identical pilot-name readings into one track (`track.rs`).

/// Levenshtein edit distance, case-sensitive.
pub fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for i in 1..=a.len() {
        cur[0] = i;
        for j in 1..=b.len() {
            let cost = if a[i - 1] == b[j - 1] { 0 } else { 1 };
            cur[j] = (prev[j] + 1).min(cur[j - 1] + 1).min(prev[j - 1] + cost);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// Case-insensitive edit distance, used for header-keyword matching where OCR case is not
/// meaningful (the overview always title-cases headers, but a misread could flip case).
pub fn levenshtein_ci(a: &str, b: &str) -> usize {
    levenshtein(&a.to_ascii_lowercase(), &b.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_strings_have_zero_distance() {
        assert_eq!(levenshtein("Velocity", "Velocity"), 0);
    }

    #[test]
    fn single_substitution() {
        assert_eq!(levenshtein("Kyle", "KyIe"), 1);
    }

    #[test]
    fn case_insensitive_matches_headers() {
        assert_eq!(levenshtein_ci("DISTANCE", "distance"), 0);
    }
}
