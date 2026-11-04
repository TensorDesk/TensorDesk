//! Tile-based frame differential comparison.
//!
//! Compares consecutive screen frames at tile granularity and classifies the
//! difference so that callers can skip encoding fully-static frames or feed
//! the encoder a "dirty" buffer where untouched regions reuse previous pixels,
//! letting the video encoder's own inter-frame compressor do the rest.

use crate::{EncodeYuvFormat, Pixfmt};

/// Tile size in pixels. 32 is a sweet spot: fine enough for cursor/mouse
/// movement (~4 tiles) and coarse enough that each tile is cheap to compare
/// (4096 BGRA bytes).
pub const TILE_SIZE: usize = 32;

/// Per-channel tolerance. A pixel is considered unchanged if R, G, B, A all
/// differ from the previous frame by at most this value. Tolerates anti-aliased
/// font rendering and subtle compositor noise without flagging them as changes.
pub const PIXEL_TOLERANCE: u8 = 2;

/// When the fraction of changed tiles exceeds this threshold the whole-frame
/// path is cheaper (tile bookkeeping overhead wins over the savings).
pub const FULL_FRAME_THRESHOLD: f32 = 0.5;

/// Describes the change between two consecutive frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiffResult {
    /// Every tile is identical (within tolerance). The caller can skip
    /// encoding entirely; no bytes need to be sent.
    Static,
    /// Only a subset of tiles changed. The caller may feed the encoder a
    /// dirty buffer where untouched tiles are filled from the previous
    /// frame, letting the video encoder's inter-frame compression naturally
    /// zero them out.
    Partial { changed_tiles: usize, total_tiles: usize },
    /// Too many tiles changed (e.g. window drag, scroll). Fall back to the
    /// original full-frame encode path — the overhead of diff bookkeeping
    /// would exceed the savings.
    FullFrame,
}

impl DiffResult {
    pub fn is_static(&self) -> bool {
        matches!(self, DiffResult::Static)
    }

    /// True when the change touches less than `1 / divisor` of all tiles
    /// (e.g. a blinking caret, a ticking clock, a cursor-sized repaint).
    pub fn is_small_change(&self, divisor: usize) -> bool {
        match self {
            DiffResult::Partial {
                changed_tiles,
                total_tiles,
            } => divisor > 0 && *total_tiles > 0 && *changed_tiles * divisor < *total_tiles,
            _ => false,
        }
    }
}

/// Per-tile change map for a frame pair.
#[derive(Debug, Clone)]
pub struct TileMask {
    pub cols: usize,
    pub rows: usize,
    /// Source pixel dimensions the mask was built for.
    pub width: usize,
    pub height: usize,
    changed: Vec<bool>,
}

impl TileMask {
    pub fn is_changed(&self, col: usize, row: usize) -> bool {
        self.changed
            .get(row * self.cols + col)
            .copied()
            .unwrap_or(true)
    }
}

/// Compare two BGRA pixel buffers of identical dimensions.
///
/// `cur` and `prev` must be length `width * height * 4` (no row padding /
/// stride — callers that have padded input must strip the padding first).
pub fn diff_bgra(cur: &[u8], prev: &[u8], width: usize, height: usize) -> DiffResult {
    diff_bgra_with_mask(cur, prev, width, height).0
}

/// Same as [`diff_bgra`], but also returns the per-tile change map.
///
/// The mask is only returned for `Partial`; the other outcomes abort early and
/// the caller has no use for it.
pub fn diff_bgra_with_mask(
    cur: &[u8],
    prev: &[u8],
    width: usize,
    height: usize,
) -> (DiffResult, Option<TileMask>) {
    let pixel_bytes = 4;
    let expected = width * height * pixel_bytes;
    if cur.len() != expected || prev.len() != expected {
        // Mismatched dimensions — treat as full frame change rather than panic.
        return (DiffResult::FullFrame, None);
    }

    let cols = (width + TILE_SIZE - 1) / TILE_SIZE;
    let rows = (height + TILE_SIZE - 1) / TILE_SIZE;
    let total = cols * rows;
    let mut changed = vec![false; total];

    let mut changed_count = 0usize;
    let mut row_start = 0usize;
    for row in 0..rows {
        let tile_h = TILE_SIZE.min(height - row * TILE_SIZE);
        let col_start = row_start;
        for col in 0..cols {
            let tile_w = TILE_SIZE.min(width - col * TILE_SIZE);
            let offset = col_start + col * TILE_SIZE * pixel_bytes;
            let row_bytes = width * pixel_bytes;

            if tile_changed(&cur[offset..], &prev[offset..], tile_w, tile_h, row_bytes) {
                changed[row * cols + col] = true;
                changed_count += 1;
                // Early exit: once we pass the threshold there is no point
                // counting further — we are going FullFrame anyway.
                if changed_count as f32 / total as f32 > FULL_FRAME_THRESHOLD {
                    return (DiffResult::FullFrame, None);
                }
            }
        }
        row_start += tile_h * width * pixel_bytes;
    }

    if changed_count == 0 {
        (DiffResult::Static, None)
    } else {
        (
            DiffResult::Partial {
                changed_tiles: changed_count,
                total_tiles: total,
            },
            Some(TileMask {
                cols,
                rows,
                width,
                height,
                changed,
            }),
        )
    }
}

/// Return true if any pixel inside a tile differs by more than PIXEL_TOLERANCE
/// from the previous frame.
#[inline]
fn tile_changed(cur: &[u8], prev: &[u8], w: usize, h: usize, row_bytes: usize) -> bool {
    for y in 0..h {
        let mut p = y * row_bytes;
        let row_end = p + w * 4;
        while p < row_end {
            // BGRA: compare all 4 channels; a single over-tolerance channel
            // flags the pixel as changed and the whole tile as dirty.
            let dc = cur[p].abs_diff(prev[p]);
            let dc1 = cur[p + 1].abs_diff(prev[p + 1]);
            let dc2 = cur[p + 2].abs_diff(prev[p + 2]);
            let dc3 = cur[p + 3].abs_diff(prev[p + 3]);
            if dc > PIXEL_TOLERANCE || dc1 > PIXEL_TOLERANCE || dc2 > PIXEL_TOLERANCE || dc3 > PIXEL_TOLERANCE {
                return true;
            }
            p += 4;
        }
    }
    false
}

/// Build the encoder's dirty buffer: for every tile that did NOT change, the
/// matching Y/U/V planes of `prev` are copied back into `cur`, so the encoder
/// sees bit-identical input and spends no bits on static regions.
///
/// `cur` and `prev` must use the same `fmt` layout and have the same length;
/// anything else is ignored (the frame is left untouched and encodes normally).
pub fn restore_unchanged_yuv(
    cur: &mut [u8],
    prev: &[u8],
    fmt: &EncodeYuvFormat,
    mask: &TileMask,
) {
    if cur.len() != prev.len() || mask.width == 0 || mask.height == 0 {
        return;
    }
    let (width, height) = (mask.width, mask.height);
    let Some(y_stride) = fmt.stride.first().copied() else {
        return;
    };
    if y_stride == 0 {
        return;
    }

    for row in 0..mask.rows {
        let ty = row * TILE_SIZE;
        if ty >= height {
            break;
        }
        let th = TILE_SIZE.min(height - ty);
        for col in 0..mask.cols {
            let tx = col * TILE_SIZE;
            if tx >= width {
                break;
            }
            if mask.is_changed(col, row) {
                continue;
            }
            let tw = TILE_SIZE.min(width - tx);

            copy_plane_block(cur, prev, ty * y_stride + tx, tw, th, y_stride);

            // Chroma planes are subsampled 2x2 for I420/NV12 and full-size for
            // I444. A 32px tile therefore maps to a 16x16 (or 32x32) block;
            // rounding up covers the odd edge tile at the right/bottom border.
            let (cw, ch) = match fmt.pixfmt {
                Pixfmt::I420 | Pixfmt::NV12 => ((tw + 1) / 2, (th + 1) / 2),
                Pixfmt::I444 => (tw, th),
                _ => return,
            };
            let cx = tx / 2;
            let cy = ty / 2;

            match fmt.pixfmt {
                Pixfmt::I420 => {
                    let (u_stride, v_stride) = (
                        fmt.stride.get(1).copied().unwrap_or(0),
                        fmt.stride.get(2).copied().unwrap_or(0),
                    );
                    if u_stride == 0 || v_stride == 0 {
                        return;
                    }
                    copy_plane_block(cur, prev, fmt.u + cy * u_stride + cx, cw, ch, u_stride);
                    copy_plane_block(cur, prev, fmt.v + cy * v_stride + cx, cw, ch, v_stride);
                }
                Pixfmt::NV12 => {
                    // Interleaved UV: two bytes per chroma sample, so the byte
                    // offset is cx * 2 and each copied row is cw * 2 bytes.
                    let uv_stride = fmt.stride.get(1).copied().unwrap_or(0);
                    if uv_stride == 0 {
                        return;
                    }
                    copy_plane_block(
                        cur,
                        prev,
                        fmt.u + cy * uv_stride + cx * 2,
                        cw * 2,
                        ch,
                        uv_stride,
                    );
                }
                Pixfmt::I444 => {
                    let (u_stride, v_stride) = (
                        fmt.stride.get(1).copied().unwrap_or(0),
                        fmt.stride.get(2).copied().unwrap_or(0),
                    );
                    if u_stride == 0 || v_stride == 0 {
                        return;
                    }
                    copy_plane_block(cur, prev, fmt.u + ty * u_stride + tx, cw, ch, u_stride);
                    copy_plane_block(cur, prev, fmt.v + ty * v_stride + tx, cw, ch, v_stride);
                }
                _ => return,
            }
        }
    }
}

/// Copy a `rows x row_bytes` block from `prev` into `cur` starting at
/// `offset`, stepping `stride` bytes per row. Silently stops at the buffer
/// end instead of panicking on a malformed format.
fn copy_plane_block(
    cur: &mut [u8],
    prev: &[u8],
    offset: usize,
    row_bytes: usize,
    rows: usize,
    stride: usize,
) {
    for r in 0..rows {
        let Some(from) = offset.checked_add(r * stride) else {
            return;
        };
        let Some(end) = from.checked_add(row_bytes) else {
            return;
        };
        if end > cur.len() {
            return;
        }
        cur[from..end].copy_from_slice(&prev[from..end]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn blank(w: usize, h: usize, b: u8) -> Vec<u8> {
        vec![b; w * h * 4]
    }

    #[test]
    fn identical_frames_are_static() {
        let cur = blank(64, 64, 0x33);
        let prev = blank(64, 64, 0x33);
        assert_eq!(diff_bgra(&cur, &prev, 64, 64), DiffResult::Static);
    }

    #[test]
    fn whole_frame_change_is_full_frame() {
        let cur = blank(128, 128, 0x11);
        let prev = blank(128, 128, 0x22);
        assert_eq!(diff_bgra(&cur, &prev, 128, 128), DiffResult::FullFrame);
    }

    #[test]
    fn tolerance_absorbs_small_jitter() {
        let mut cur = blank(64, 64, 100);
        // A single channel of a single pixel changes by exactly PIXEL_TOLERANCE.
        cur[0] = 100 + PIXEL_TOLERANCE;
        let prev = blank(64, 64, 100);
        assert_eq!(diff_bgra(&cur, &prev, 64, 64), DiffResult::Static);

        cur[0] = 100 + PIXEL_TOLERANCE + 1;
        // Now the tile changes.
        assert!(matches!(
            diff_bgra(&cur, &prev, 64, 64),
            DiffResult::Partial { .. }
        ));
    }

    #[test]
    fn single_cursor_tile_is_partial() {
        let mut cur = blank(128, 128, 0);
        let prev = blank(128, 128, 0);
        // "Cursor": paint one tile white in cur, one pixel in prev.
        let offset = 16 * 128 * 4 + 16 * 4; // tile (0, 0) region, not aligned, force partial
        cur[offset] = 0xFF;
        assert!(matches!(
            diff_bgra(&cur, &prev, 128, 128),
            DiffResult::Partial { changed_tiles: 1, total_tiles: 16 }
        ));
    }

    #[test]
    fn small_change_is_classified_by_coverage() {
        assert!(DiffResult::Partial {
            changed_tiles: 1,
            total_tiles: 64
        }
        .is_small_change(20));
        assert!(!DiffResult::Partial {
            changed_tiles: 4,
            total_tiles: 64
        }
        .is_small_change(20));
        assert!(!DiffResult::Static.is_small_change(20));
        assert!(!DiffResult::FullFrame.is_small_change(20));
    }

    #[test]
    fn mask_flags_only_changed_tiles() {
        let mut cur = blank(128, 128, 0);
        let prev = blank(128, 128, 0);
        // Pixel (64, 64) sits in tile (2, 2) — 32px tiles over a 128px frame.
        let offset = (64 * 128 + 64) * 4;
        cur[offset] = 0xFF;
        let (result, mask) = diff_bgra_with_mask(&cur, &prev, 128, 128);
        assert!(matches!(
            result,
            DiffResult::Partial { changed_tiles: 1, total_tiles: 16 }
        ));
        let mask = mask.expect("partial frame must yield a mask");
        assert!(mask.is_changed(2, 2));
        for row in 0..mask.rows {
            for col in 0..mask.cols {
                if (col, row) != (2, 2) {
                    assert!(!mask.is_changed(col, row));
                }
            }
        }
    }

    #[test]
    fn restore_yuv_reverts_unchanged_tiles() {
        let (w, h) = (64usize, 64usize);
        let fmt = EncodeYuvFormat {
            pixfmt: Pixfmt::I420,
            w,
            h,
            stride: vec![w, w / 2, w / 2],
            u: w * h,
            v: w * h + (w / 2) * (h / 2),
        };
        let luma_len = w * h;
        let chroma_len = (w / 2) * (h / 2);
        let mut prev_yuv = vec![0u8; luma_len + 2 * chroma_len];
        prev_yuv[..luma_len].fill(0x10);
        prev_yuv[fmt.u..fmt.u + chroma_len].fill(0x20);
        prev_yuv[fmt.v..fmt.v + chroma_len].fill(0x30);

        let mut cur_yuv = vec![0xFFu8; prev_yuv.len()];

        // Only the top-left BGRA tile changed, so only that tile's Y/U/V
        // should survive; every other tile must be reverted from prev.
        let mut cur_bgra = blank(w, h, 0);
        let prev_bgra = blank(w, h, 0);
        cur_bgra[0] = 0xFF;
        let (_, mask) = diff_bgra_with_mask(&cur_bgra, &prev_bgra, w, h);
        let mask = mask.expect("partial frame must yield a mask");

        restore_unchanged_yuv(&mut cur_yuv, &prev_yuv, &fmt, &mask);

        assert_eq!(cur_yuv[0], 0xFF);
        assert_eq!(cur_yuv[31 * w + 31], 0xFF);
        assert_eq!(cur_yuv[32 * w], 0x10);
        assert_eq!(cur_yuv[63 * w + 63], 0x10);
        assert_eq!(cur_yuv[fmt.u], 0xFF);
        assert_eq!(cur_yuv[fmt.u + 16 * (w / 2)], 0x20);
        assert_eq!(cur_yuv[fmt.v + 16 * (w / 2)], 0x30);
    }
}
