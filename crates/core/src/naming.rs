//! File naming templates for exported captures.
//!
//! Tokens: `{yyyy}` `{MM}` `{dd}` `{HH}` `{mm}` `{ss}`. Unknown tokens are kept
//! literally. Characters that are invalid in macOS file names are replaced.

use chrono::{DateTime, Datelike, Local, TimeZone, Timelike};

pub const DEFAULT_TEMPLATE: &str = "Snapora {yyyy}-{MM}-{dd} at {HH}.{mm}.{ss}";

/// Renders `template` for `time` and appends `.{extension}`.
pub fn file_name<Tz: TimeZone>(template: &str, time: &DateTime<Tz>, extension: &str) -> String {
    let mut out = String::with_capacity(template.len() + 8);
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        out.push_str(&rest[..start]);
        let after = &rest[start..];
        match after.find('}') {
            Some(end) => {
                let token = &after[1..end];
                match render_token(token, time) {
                    Some(v) => out.push_str(&v),
                    None => out.push_str(&after[..=end]),
                }
                rest = &after[end + 1..];
            }
            None => {
                out.push_str(after);
                rest = "";
            }
        }
    }
    out.push_str(rest);

    let mut name = sanitize(out.trim());
    if name.is_empty() {
        name = "Snapora".to_owned();
    }
    let ext = extension.trim_start_matches('.');
    if ext.is_empty() { name } else { format!("{name}.{ext}") }
}

/// Renders a file name for the current local time.
pub fn file_name_now(template: &str, extension: &str) -> String {
    file_name(template, &Local::now(), extension)
}

fn render_token<Tz: TimeZone>(token: &str, t: &DateTime<Tz>) -> Option<String> {
    Some(match token {
        "yyyy" => format!("{:04}", t.year()),
        "MM" => format!("{:02}", t.month()),
        "dd" => format!("{:02}", t.day()),
        "HH" => format!("{:02}", t.hour()),
        "mm" => format!("{:02}", t.minute()),
        "ss" => format!("{:02}", t.second()),
        _ => return None,
    })
}

fn sanitize(s: &str) -> String {
    let s: String = s
        .chars()
        .map(|c| match c {
            '/' | ':' | '\0' => '-',
            c if c.is_control() => '-',
            c => c,
        })
        .collect();
    // A leading dot would hide the file in Finder.
    s.trim_start_matches('.').to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{FixedOffset, TimeZone};

    fn t() -> DateTime<FixedOffset> {
        FixedOffset::east_opt(0)
            .unwrap()
            .with_ymd_and_hms(2026, 3, 7, 9, 5, 2)
            .unwrap()
    }

    #[test]
    fn default_template() {
        assert_eq!(
            file_name(DEFAULT_TEMPLATE, &t(), "png"),
            "Snapora 2026-03-07 at 09.05.02.png"
        );
    }

    #[test]
    fn unknown_and_unclosed_tokens_are_literal() {
        assert_eq!(file_name("a {foo} {yyyy", &t(), ".png"), "a {foo} {yyyy.png");
    }

    #[test]
    fn invalid_characters_replaced() {
        assert_eq!(file_name("{HH}:{mm} a/b", &t(), "png"), "09-05 a-b.png");
        assert_eq!(file_name("..hidden", &t(), "png"), "hidden.png");
    }

    #[test]
    fn empty_template_falls_back() {
        assert_eq!(file_name("  ", &t(), "png"), "Snapora.png");
        assert_eq!(file_name("x", &t(), ""), "x");
    }
}
