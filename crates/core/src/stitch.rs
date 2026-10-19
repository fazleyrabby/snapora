//! Scrolling-capture stitcher.
//!
//! The user scrolls a fixed region downward while frames are captured. Each
//! new frame is matched against the previous one to find how far the content
//! moved, and only the newly revealed rows are appended. Rows that do not move
//! between frames at the top (sticky headers) and bottom (sticky footers) are
//! kept once: the header from the first frame, the footer from the last.
//!
//! Matching uses per-row luminance signatures, so it is independent of pixel
//! channel order (RGBA or BGRA). Joins whose match is weak or ambiguous are
//! counted as uncertain so the UI can warn instead of silently producing a
//! misleading image.

use thiserror::Error;

/// Columns per row signature.
const BINS: usize = 64;
/// Mean absolute bin difference below which two rows are "the same".
const SAME_ROW: f32 = 1.5;
/// Mean absolute difference accepted for a match.
const MATCH_THRESHOLD: f32 = 4.0;
/// Header/footer may each cover at most this fraction of the frame.
const MAX_STICKY_FRACTION: f32 = 0.3;
/// Overlap must cover at least this fraction of the scrolling body.
const MIN_OVERLAP_FRACTION: f32 = 0.15;
/// Rows sampled for the coarse offset search.
const COARSE_SAMPLES: usize = 48;
/// Candidates refined with a full comparison.
const REFINE_CANDIDATES: usize = 6;

#[derive(Debug, Clone, Copy)]
pub struct Frame<'a> {
    pub width: usize,
    pub height: usize,
    pub bytes_per_row: usize,
    /// 4 bytes per pixel.
    pub data: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum StitchError {
    #[error("frame buffer is smaller than its dimensions")]
    BadBuffer,
    #[error("frame is too small to stitch")]
    TooSmall,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FrameOutcome {
    /// New rows were appended.
    Appended { rows: usize, uncertain: bool },
    /// Content did not move.
    NoMovement,
    /// The frame could not be matched (scrolled up, jumped too far, or
    /// changed too much). It is ignored.
    NoMatch,
    /// Frame size differs from the first frame.
    SizeChanged,
    /// Maximum output height reached; further frames are ignored.
    LimitReached,
}

#[derive(Debug, Clone)]
pub struct Stitched {
    pub width: usize,
    pub height: usize,
    /// Tightly packed, `width * 4` bytes per row, same channel order as input.
    pub data: Vec<u8>,
    pub uncertain_joins: u32,
    pub frames_used: u32,
}

type Sig = [f32; BINS];

pub struct Stitcher {
    width: usize,
    height: usize,
    max_rows: usize,
    /// Output so far, tightly packed.
    canvas: Vec<u8>,
    /// The canvas ends at this row of the previous frame.
    end_row: usize,
    prev_sigs: Vec<Sig>,
    /// Previous frame rows, kept to append its footer at the end.
    prev_rows: Vec<u8>,
    uncertain_joins: u32,
    frames_used: u32,
    /// Sticky footer rows of the previous frame.
    footer: usize,
    /// Output was truncated at `max_rows`.
    limited: bool,
}

impl Stitcher {
    /// Starts with the first frame. `max_rows` caps the output height.
    pub fn new(first: Frame<'_>, max_rows: usize) -> Result<Self, StitchError> {
        validate(&first)?;
        let rows = pack(&first);
        Ok(Self {
            width: first.width,
            height: first.height,
            max_rows: max_rows.max(first.height),
            canvas: rows.clone(),
            end_row: first.height,
            prev_sigs: signatures(&first),
            prev_rows: rows,
            uncertain_joins: 0,
            frames_used: 1,
            footer: 0,
            limited: false,
        })
    }

    pub fn height(&self) -> usize {
        self.canvas.len() / self.row_bytes() + (self.height - self.end_row)
    }

    pub fn uncertain_joins(&self) -> u32 {
        self.uncertain_joins
    }

    pub fn push(&mut self, frame: Frame<'_>) -> Result<FrameOutcome, StitchError> {
        validate(&frame)?;
        if self.limited {
            return Ok(FrameOutcome::LimitReached);
        }
        if frame.width != self.width || frame.height != self.height {
            return Ok(FrameOutcome::SizeChanged);
        }
        let sigs = signatures(&frame);
        let h = self.height;

        let (header, footer) = sticky_bands(&self.prev_sigs, &sigs);
        if header + footer >= h {
            return Ok(FrameOutcome::NoMovement);
        }
        let body = h - header - footer;
        if body < 8 {
            return Ok(FrameOutcome::NoMovement);
        }

        let Some(found) = find_offset(&self.prev_sigs, &sigs, header, footer) else {
            return Ok(FrameOutcome::NoMatch);
        };
        if found.dy == 0 {
            return Ok(FrameOutcome::NoMovement);
        }

        let row_bytes = self.row_bytes();
        let canvas_rows = self.canvas.len() / row_bytes;
        let body_end = h - footer;

        // Drop the previous frame's footer rows (and anything below the
        // body) from the canvas; they reappear at the end.
        if self.end_row > body_end {
            let drop = (self.end_row - body_end).min(canvas_rows);
            self.canvas.truncate((canvas_rows - drop) * row_bytes);
            self.end_row = body_end;
        }

        // Canvas ends at previous row `end_row` == new row `end_row - dy`.
        let start = self.end_row.saturating_sub(found.dy);
        let mut rows = body_end.saturating_sub(start);
        let current = self.canvas.len() / row_bytes;
        if current + rows + footer > self.max_rows {
            rows = self.max_rows.saturating_sub(current + footer);
            self.limited = true;
            if rows == 0 {
                self.footer = footer;
                return Ok(FrameOutcome::LimitReached);
            }
        }

        let packed = pack(&frame);
        self.canvas
            .extend_from_slice(&packed[start * row_bytes..(start + rows) * row_bytes]);
        self.end_row = start + rows;
        self.prev_sigs = sigs;
        self.prev_rows = packed;
        self.frames_used += 1;
        self.footer = footer;
        if found.uncertain {
            self.uncertain_joins += 1;
        }
        Ok(FrameOutcome::Appended { rows, uncertain: found.uncertain })
    }

    /// Finishes by appending the last frame's rows below the canvas end
    /// (its sticky footer). If the height limit was hit, only the footer is
    /// appended.
    pub fn finish(mut self) -> Stitched {
        let row_bytes = self.row_bytes();
        let from = if self.limited { self.height - self.footer } else { self.end_row };
        let tail = &self.prev_rows[from * row_bytes..];
        self.canvas.extend_from_slice(tail);
        Stitched {
            width: self.width,
            height: self.canvas.len() / row_bytes,
            data: self.canvas,
            uncertain_joins: self.uncertain_joins,
            frames_used: self.frames_used,
        }
    }

    fn row_bytes(&self) -> usize {
        self.width * 4
    }
}

struct Offset {
    dy: usize,
    uncertain: bool,
}

fn validate(f: &Frame<'_>) -> Result<(), StitchError> {
    if f.width < 8 || f.height < 16 {
        return Err(StitchError::TooSmall);
    }
    if f.bytes_per_row < f.width * 4 || f.data.len() < f.bytes_per_row * (f.height - 1) + f.width * 4 {
        return Err(StitchError::BadBuffer);
    }
    Ok(())
}

fn pack(f: &Frame<'_>) -> Vec<u8> {
    let rb = f.width * 4;
    let mut out = Vec::with_capacity(rb * f.height);
    for y in 0..f.height {
        let start = y * f.bytes_per_row;
        out.extend_from_slice(&f.data[start..start + rb]);
    }
    out
}

fn signatures(f: &Frame<'_>) -> Vec<Sig> {
    (0..f.height)
        .map(|y| {
            let row = &f.data[y * f.bytes_per_row..y * f.bytes_per_row + f.width * 4];
            let mut sig = [0f32; BINS];
            let mut counts = [0u32; BINS];
            for x in 0..f.width {
                let p = &row[x * 4..x * 4 + 3];
                let lum = (p[0] as u32 + p[1] as u32 + p[2] as u32) as f32 / 3.0;
                let bin = x * BINS / f.width;
                sig[bin] += lum;
                counts[bin] += 1;
            }
            for (s, c) in sig.iter_mut().zip(counts) {
                if c > 0 {
                    *s /= c as f32;
                }
            }
            sig
        })
        .collect()
}

fn row_diff(a: &Sig, b: &Sig) -> f32 {
    a.iter().zip(b).map(|(x, y)| (x - y).abs()).sum::<f32>() / BINS as f32
}

/// Rows identical at the same position at the top and bottom of both frames.
fn sticky_bands(prev: &[Sig], next: &[Sig]) -> (usize, usize) {
    let h = prev.len();
    let cap = (h as f32 * MAX_STICKY_FRACTION) as usize;
    let header = (0..cap).take_while(|&y| row_diff(&prev[y], &next[y]) < SAME_ROW).count();
    let footer = (0..cap)
        .take_while(|&i| row_diff(&prev[h - 1 - i], &next[h - 1 - i]) < SAME_ROW)
        .count();
    (header, footer)
}

/// Mean diff between new rows `[header, end - dy)` and previous rows shifted
/// by `dy`, using `samples` evenly spaced rows (all rows when `None`).
fn score(prev: &[Sig], next: &[Sig], header: usize, end: usize, dy: usize, samples: Option<usize>) -> f32 {
    let overlap = end - header - dy;
    let n = samples.map_or(overlap, |s| s.min(overlap)).max(1);
    let mut total = 0.0;
    for i in 0..n {
        let r = header + i * overlap / n;
        total += row_diff(&next[r], &prev[r + dy]);
    }
    total / n as f32
}

/// Variance of the overlap region's signatures; near zero means blank
/// content where any offset matches.
fn texture(sigs: &[Sig], from: usize, to: usize) -> f32 {
    let rows = &sigs[from..to];
    if rows.len() < 2 {
        return 0.0;
    }
    let mean: f32 = rows.iter().map(|s| s.iter().sum::<f32>() / BINS as f32).sum::<f32>() / rows.len() as f32;
    rows.iter()
        .map(|s| {
            let m = s.iter().sum::<f32>() / BINS as f32;
            (m - mean).powi(2)
        })
        .sum::<f32>()
        / rows.len() as f32
}

fn find_offset(prev: &[Sig], next: &[Sig], header: usize, footer: usize) -> Option<Offset> {
    let end = prev.len() - footer;
    let body = end - header;

    if score(prev, next, header, end, 0, None) < SAME_ROW {
        return Some(Offset { dy: 0, uncertain: false });
    }

    let min_overlap = ((body as f32 * MIN_OVERLAP_FRACTION) as usize).max(4);
    let max_dy = body.checked_sub(min_overlap)?;
    if max_dy == 0 {
        return None;
    }

    let mut coarse: Vec<(usize, f32)> = (1..=max_dy)
        .map(|dy| (dy, score(prev, next, header, end, dy, Some(COARSE_SAMPLES))))
        .collect();
    coarse.sort_by(|a, b| a.1.total_cmp(&b.1));

    let mut refined: Vec<(usize, f32)> = coarse
        .iter()
        .take(REFINE_CANDIDATES)
        .map(|&(dy, _)| (dy, score(prev, next, header, end, dy, None)))
        .collect();
    refined.sort_by(|a, b| a.1.total_cmp(&b.1));

    let (dy, best) = refined[0];
    if best > MATCH_THRESHOLD {
        return None;
    }
    let ambiguous = refined
        .iter()
        .skip(1)
        .any(|&(d, s)| d.abs_diff(dy) > 2 && s - best < 0.75);
    let flat = texture(next, header, end - dy) < 1.0;
    Some(Offset { dy, uncertain: ambiguous || flat || best > MATCH_THRESHOLD / 2.0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    const W: usize = 40;
    const BPR: usize = W * 4 + 8; // padded rows

    /// Deterministic "page": each row has a distinct pattern.
    fn page(rows: usize) -> Vec<[u8; 4]> {
        let mut seed = 0x2545_F491_u32;
        (0..rows * W)
            .map(|_| {
                seed ^= seed << 13;
                seed ^= seed >> 17;
                seed ^= seed << 5;
                let v = (seed & 0xFF) as u8;
                [v, v.wrapping_mul(3), v.wrapping_add(40), 255]
            })
            .collect()
    }

    fn solid(color: u8) -> [u8; 4] {
        [color, color, color, 255]
    }

    /// A viewport of `h` rows at `scroll`, with optional sticky header/footer.
    fn viewport(page: &[[u8; 4]], scroll: usize, h: usize, header: usize, footer: usize) -> Vec<u8> {
        let mut out = vec![0u8; BPR * h];
        for y in 0..h {
            for x in 0..W {
                let px = if y < header {
                    solid(10)
                } else if y >= h - footer {
                    solid(240)
                } else {
                    page[(scroll + y) * W + x]
                };
                out[y * BPR + x * 4..y * BPR + x * 4 + 4].copy_from_slice(&px);
            }
        }
        out
    }

    fn frame(data: &[u8], h: usize) -> Frame<'_> {
        Frame { width: W, height: h, bytes_per_row: BPR, data }
    }

    fn expected(page: &[[u8; 4]], h: usize, header: usize, footer: usize, last_scroll: usize) -> Vec<u8> {
        let total = last_scroll + h;
        let mut out = Vec::new();
        for y in 0..total {
            for x in 0..W {
                let px = if y < header {
                    solid(10)
                } else if y >= total - footer {
                    solid(240)
                } else {
                    page[y * W + x]
                };
                out.extend_from_slice(&px);
            }
        }
        out
    }

    fn run(scrolls: &[usize], h: usize, header: usize, footer: usize) -> Stitched {
        let p = page(2000);
        let first = viewport(&p, scrolls[0], h, header, footer);
        let mut s = Stitcher::new(frame(&first, h), 100_000).unwrap();
        for &sc in &scrolls[1..] {
            let v = viewport(&p, sc, h, header, footer);
            s.push(frame(&v, h)).unwrap();
        }
        s.finish()
    }

    #[test]
    fn plain_scroll_reconstructs_page() {
        let r = run(&[0, 30, 75, 120], 100, 0, 0);
        assert_eq!(r.height, 220);
        assert_eq!(r.data, expected(&page(2000), 100, 0, 0, 120));
        assert_eq!(r.uncertain_joins, 0);
        assert_eq!(r.frames_used, 4);
    }

    #[test]
    fn sticky_header_and_footer_kept_once() {
        let r = run(&[0, 40, 90], 120, 12, 8);
        assert_eq!(r.height, 120 + 90);
        assert_eq!(r.data, expected(&page(2000), 120, 12, 8, 90));
    }

    #[test]
    fn no_movement_is_skipped() {
        let p = page(500);
        let a = viewport(&p, 0, 100, 0, 0);
        let mut s = Stitcher::new(frame(&a, 100), 10_000).unwrap();
        assert_eq!(s.push(frame(&a, 100)).unwrap(), FrameOutcome::NoMovement);
        assert_eq!(s.finish().height, 100);
    }

    #[test]
    fn scrolling_up_or_jumping_does_not_match() {
        let p = page(800);
        let a = viewport(&p, 200, 100, 0, 0);
        let mut s = Stitcher::new(frame(&a, 100), 10_000).unwrap();
        let up = viewport(&p, 150, 100, 0, 0);
        assert_eq!(s.push(frame(&up, 100)).unwrap(), FrameOutcome::NoMatch);
        let jump = viewport(&p, 500, 100, 0, 0);
        assert_eq!(s.push(frame(&jump, 100)).unwrap(), FrameOutcome::NoMatch);
        assert_eq!(s.finish().height, 100);
    }

    #[test]
    fn size_change_rejected() {
        let p = page(500);
        let a = viewport(&p, 0, 100, 0, 0);
        let b = viewport(&p, 10, 90, 0, 0);
        let mut s = Stitcher::new(frame(&a, 100), 10_000).unwrap();
        assert_eq!(s.push(frame(&b, 90)).unwrap(), FrameOutcome::SizeChanged);
    }

    #[test]
    fn max_rows_caps_output() {
        let p = page(800);
        let a = viewport(&p, 0, 100, 0, 0);
        let mut s = Stitcher::new(frame(&a, 100), 150).unwrap();
        let b = viewport(&p, 80, 100, 0, 0);
        assert_eq!(s.push(frame(&b, 100)).unwrap(), FrameOutcome::Appended { rows: 50, uncertain: false });
        let c = viewport(&p, 160, 100, 0, 0);
        assert_eq!(s.push(frame(&c, 100)).unwrap(), FrameOutcome::LimitReached);
        assert_eq!(s.finish().height, 150);
    }

    #[test]
    fn blank_content_is_uncertain() {
        // Uniform rows: every offset matches equally well.
        let h = 100;
        let mut a = vec![0u8; BPR * h];
        let mut b = vec![0u8; BPR * h];
        for y in 0..h {
            for x in 0..W {
                let px = solid(if y < 50 { 100 } else { 101 });
                a[y * BPR + x * 4..y * BPR + x * 4 + 4].copy_from_slice(&px);
                let px = solid(if y < 40 { 100 } else { 101 });
                b[y * BPR + x * 4..y * BPR + x * 4 + 4].copy_from_slice(&px);
            }
        }
        let mut s = Stitcher::new(frame(&a, h), 10_000).unwrap();
        match s.push(frame(&b, h)).unwrap() {
            FrameOutcome::Appended { uncertain, .. } => assert!(uncertain),
            FrameOutcome::NoMovement | FrameOutcome::NoMatch => {}
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn rejects_bad_buffers() {
        let tiny = vec![0u8; 16];
        assert_eq!(
            Stitcher::new(Frame { width: 4, height: 4, bytes_per_row: 16, data: &tiny }, 10).err(),
            Some(StitchError::TooSmall)
        );
        let short = vec![0u8; 100];
        assert_eq!(
            Stitcher::new(Frame { width: 40, height: 100, bytes_per_row: 160, data: &short }, 10).err(),
            Some(StitchError::BadBuffer)
        );
    }
}
