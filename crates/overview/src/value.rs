//! Typed parsing of numeric overview cell text (DESIGN.md S4.4: "parse each cell to a typed
//! value ... recovering the unit suffix").

/// A parsed numeric overview cell.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum CellValue {
    /// The overview's own `"-"` — a real absence of a value (e.g. a celestial has no velocity),
    /// not a read failure.
    None,
    /// Successfully parsed, in canonical units (metres for distance, m/s for scalar speeds).
    Value(f64),
    /// Present but did not parse cleanly: OCR noise, or — importantly — a value the *client*
    /// itself truncated because the column was too narrow to hold it (e.g. `"329,25"`, whose
    /// final thousands-group is two digits, not three). Must never be silently coerced into a
    /// number (that would read `"329,25"` as `32925`, off by roughly 10x); the caller drops it.
    Unreadable,
}

impl CellValue {
    pub fn ok(self) -> Option<f64> {
        match self {
            CellValue::Value(v) => Some(v),
            _ => None,
        }
    }
}

pub const METRES_PER_AU: f64 = 149_597_870_700.0;

/// Parse a distance cell (`"29 km"`, `"4,758 m"`, `"1.2 AU"`) to metres.
///
/// `"k"` is also accepted as `"km"`: `glyph`'s matcher deliberately never overrides a confident
/// single-glyph read on width alone (see its `CONFIDENT_SINGLE_SCORE` doc comment) — a `k`+`m`
/// touching pair can end up read as just `k` when `k` alone happens to score high enough at some
/// offset within the run — and this is the one place with enough context to know that's what
/// happened: nothing in a distance cell legitimately uses a bare `k` unit, so a lone `k` here is
/// unambiguously a truncated `km`, never a real (1000x smaller) value.
pub fn parse_distance(text: &str) -> CellValue {
    parse_numeric_with_unit(text, |unit| match unit {
        "m" => Some(1.0),
        "km" | "k" => Some(1_000.0),
        "AU" => Some(METRES_PER_AU),
        _ => None,
    })
}

/// Parse a plain scalar cell (Velocity, Angular/Radial/Transversal Velocity): the overview shows
/// these as bare numbers (m/s or rad/s implied by the column, not the cell), but a unit is
/// tolerated if present.
pub fn parse_scalar(text: &str) -> CellValue {
    parse_numeric_with_unit(text, |unit| match unit {
        "" => Some(1.0),
        "m/s" => Some(1.0),
        _ => None,
    })
}

fn parse_numeric_with_unit(text: &str, unit_scale: impl Fn(&str) -> Option<f64>) -> CellValue {
    let text = text.trim();
    if text.is_empty() {
        return CellValue::Unreadable;
    }
    if text == "-" {
        return CellValue::None;
    }
    let split_at = text.find(|c: char| !(c.is_ascii_digit() || c == ',' || c == '.' || c == '-'));
    let (number, unit) = match split_at {
        Some(i) => (&text[..i], text[i..].trim()),
        None => (text, ""),
    };
    if number.is_empty() || !valid_thousands_grouping(number) {
        return CellValue::Unreadable;
    }
    // Trailing noise after the unit (a stray punctuation glyph picked up from the next column's
    // edge, e.g. `"37 km ."`) is dropped rather than failing the whole cell: a unit is always a
    // short run of letters (plus `/`, for `"m/s"`), so anything after that isn't part of it.
    let unit: String = unit
        .chars()
        .take_while(|c| c.is_ascii_alphabetic() || *c == '/')
        .collect();
    let Some(scale) = unit_scale(&unit) else {
        return CellValue::Unreadable;
    };
    match number.replace(',', "").parse::<f64>() {
        Ok(v) => CellValue::Value(v * scale),
        Err(_) => CellValue::Unreadable,
    }
}

/// A comma-grouped integer must group in 3s from the right (`"1,515"`, `"50,095"`). EVE never
/// prints a partial trailing group — `"329,25"` is the client itself truncating a wider number to
/// fit the column, not a real (much smaller) value, so this must be rejected rather than parsed.
fn valid_thousands_grouping(number: &str) -> bool {
    let integer_part = number.split('.').next().unwrap_or(number);
    let integer_part = integer_part.strip_prefix('-').unwrap_or(integer_part);
    let groups: Vec<&str> = integer_part.split(',').collect();
    match groups.as_slice() {
        [] => false,
        [single] => !single.is_empty() && single.chars().all(|c| c.is_ascii_digit()),
        [first, rest @ ..] => {
            !first.is_empty()
                && first.len() <= 3
                && first.chars().all(|c| c.is_ascii_digit())
                && rest
                    .iter()
                    .all(|g| g.len() == 3 && g.chars().all(|c| c.is_ascii_digit()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_metres_and_kilometres() {
        assert_eq!(parse_distance("0 m"), CellValue::Value(0.0));
        assert_eq!(parse_distance("4,758 m"), CellValue::Value(4758.0));
        assert_eq!(parse_distance("29 km"), CellValue::Value(29_000.0));
        assert_eq!(parse_distance("462 km"), CellValue::Value(462_000.0));
    }

    #[test]
    fn dash_is_a_real_absence() {
        assert_eq!(parse_distance("-"), CellValue::None);
        assert_eq!(parse_scalar("-"), CellValue::None);
    }

    #[test]
    fn truncated_thousands_group_is_unreadable_not_wrong() {
        // A client-side column-width truncation, not the number 32925.
        assert_eq!(parse_scalar("329,25"), CellValue::Unreadable);
    }

    #[test]
    fn plain_scalars() {
        assert_eq!(parse_scalar("247"), CellValue::Value(247.0));
        assert_eq!(parse_scalar("0.32"), CellValue::Value(0.32));
        assert_eq!(parse_scalar("50,095"), CellValue::Value(50_095.0));
    }

    #[test]
    fn garbage_is_unreadable() {
        assert_eq!(parse_distance(""), CellValue::Unreadable);
        assert_eq!(parse_distance("2? km"), CellValue::Unreadable);
        assert_eq!(parse_distance("29 furlongs"), CellValue::Unreadable);
    }
}
