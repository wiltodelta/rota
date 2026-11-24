//! Shelf-packing 2D RGBA8 texture atlas allocator and dirty-upload tracker.

/// Pixel rectangle within an atlas texture.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct AtlasRegion {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
    pub generation: u32,
}

impl AtlasRegion {
    /// Returns `[u0, v0, u1, v1]` normalized texture coordinates for an atlas of `(atlas_w, atlas_h)`.
    #[inline]
    pub fn uv_rect(self, atlas_w: u32, atlas_h: u32) -> [f32; 4] {
        let inv_w = 1.0 / (atlas_w.max(1) as f32);
        let inv_h = 1.0 / (atlas_h.max(1) as f32);
        [
            self.x as f32 * inv_w,
            self.y as f32 * inv_h,
            (self.x + self.width) as f32 * inv_w,
            (self.y + self.height) as f32 * inv_h,
        ]
    }
}

#[derive(Debug, Clone, Copy)]
struct Shelf {
    y: u32,
    height: u32,
    cursor_x: u32,
}

/// Pending upload queued since the previous GPU frame.
#[derive(Debug, Clone)]
pub struct PendingUpload {
    pub region: AtlasRegion,
    pub rgba: Vec<u8>,
}

/// Fast shelf-packing 2D RGBA8 texture atlas with automatic generation reset when full.
#[derive(Debug)]
pub struct TextureAtlas {
    width: u32,
    height: u32,
    padding: u32,
    generation: u32,
    shelves: Vec<Shelf>,
    next_shelf_y: u32,
    pending_uploads: Vec<PendingUpload>,
    needs_clear_on_gpu: bool,
}

impl TextureAtlas {
    pub const DEFAULT_SIZE: u32 = 2048;

    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width: width.max(64),
            height: height.max(64),
            padding: 1,
            generation: 1,
            shelves: Vec::with_capacity(64),
            next_shelf_y: 1,
            pending_uploads: Vec::new(),
            needs_clear_on_gpu: true,
        }
    }

    #[inline]
    pub fn width(&self) -> u32 {
        self.width
    }

    #[inline]
    pub fn height(&self) -> u32 {
        self.height
    }

    #[inline]
    pub fn generation(&self) -> u32 {
        self.generation
    }

    #[inline]
    pub fn uv_for(&self, region: AtlasRegion) -> [f32; 4] {
        region.uv_rect(self.width, self.height)
    }

    /// Resets all shelves and bumps `generation` so callers know cached regions were evicted.
    pub fn clear_and_bump_generation(&mut self) {
        self.generation = self.generation.wrapping_add(1).max(1);
        self.shelves.clear();
        self.next_shelf_y = self.padding;
        self.pending_uploads.clear();
        self.needs_clear_on_gpu = true;
    }

    /// Allocates space for a `width x height` RGBA8 bitmap (`width * height * 4` bytes) and queues upload.
    pub fn allocate_and_upload(&mut self, width: u32, height: u32, rgba: Vec<u8>) -> Option<AtlasRegion> {
        if width == 0 || height == 0 {
            return Some(AtlasRegion {
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                generation: self.generation,
            });
        }
        let expected_bytes = (width as usize).checked_mul(height as usize)?.checked_mul(4)?;
        if rgba.len() != expected_bytes {
            return None;
        }
        let max_inner_w = self.width.saturating_sub(self.padding * 2);
        let max_inner_h = self.height.saturating_sub(self.padding * 2);
        if width > max_inner_w || height > max_inner_h {
            return None;
        }

        let region = if let Some(r) = self.try_pack(width, height) {
            r
        } else {
            self.clear_and_bump_generation();
            self.try_pack(width, height)?
        };

        self.pending_uploads.push(PendingUpload { region, rgba });
        Some(region)
    }

    fn try_pack(&mut self, width: u32, height: u32) -> Option<AtlasRegion> {
        let padded_w = width + self.padding;
        let padded_h = height + self.padding;
        let bucket_h = padded_h.next_power_of_two().min(padded_h + 16).max(padded_h);

        // Best-fit existing shelf with enough horizontal space and reasonable vertical slack.
        let mut best_idx = None;
        let mut best_slack = u32::MAX;
        for (idx, shelf) in self.shelves.iter().enumerate() {
            if shelf.height >= padded_h && shelf.cursor_x + padded_w <= self.width {
                let slack = shelf.height - padded_h;
                if slack < best_slack && slack <= padded_h {
                    best_slack = slack;
                    best_idx = Some(idx);
                }
            }
        }

        if let Some(idx) = best_idx {
            let shelf = &mut self.shelves[idx];
            let x = shelf.cursor_x;
            let y = shelf.y;
            shelf.cursor_x += padded_w;
            return Some(AtlasRegion {
                x,
                y,
                width,
                height,
                generation: self.generation,
            });
        }

        if self.next_shelf_y + bucket_h > self.height {
            if self.next_shelf_y + padded_h > self.height {
                return None;
            }
            let y = self.next_shelf_y;
            self.shelves.push(Shelf {
                y,
                height: padded_h,
                cursor_x: self.padding + padded_w,
            });
            self.next_shelf_y += padded_h;
            return Some(AtlasRegion {
                x: self.padding,
                y,
                width,
                height,
                generation: self.generation,
            });
        }

        let y = self.next_shelf_y;
        self.shelves.push(Shelf {
            y,
            height: bucket_h,
            cursor_x: self.padding + padded_w,
        });
        self.next_shelf_y += bucket_h;
        Some(AtlasRegion {
            x: self.padding,
            y,
            width,
            height,
            generation: self.generation,
        })
    }

    /// Flushes all pending CPU uploads into `gpu_texture`.
    pub fn flush_to_gpu(&mut self, queue: &wgpu::Queue, gpu_texture: &wgpu::Texture) {
        if self.needs_clear_on_gpu {
            self.needs_clear_on_gpu = false;
            // Clear first texel (0, 0) used by empty regions.
            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: gpu_texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                &[0u8; 4],
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(4),
                    rows_per_image: Some(1),
                },
                wgpu::Extent3d {
                    width: 1,
                    height: 1,
                    depth_or_array_layers: 1,
                },
            );
        }

        for upload in self.pending_uploads.drain(..) {
            queue.write_texture(
                wgpu::TexelCopyTextureInfo {
                    texture: gpu_texture,
                    mip_level: 0,
                    origin: wgpu::Origin3d {
                        x: upload.region.x,
                        y: upload.region.y,
                        z: 0,
                    },
                    aspect: wgpu::TextureAspect::All,
                },
                &upload.rgba,
                wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(upload.region.width * 4),
                    rows_per_image: Some(upload.region.height),
                },
                wgpu::Extent3d {
                    width: upload.region.width,
                    height: upload.region.height,
                    depth_or_array_layers: 1,
                },
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shelf_packing_non_overlapping_and_generation_wrap() {
        let mut atlas = TextureAtlas::new(128, 128);
        let r1 = atlas
            .allocate_and_upload(32, 24, vec![255; 32 * 24 * 4])
            .expect("r1");
        let r2 = atlas
            .allocate_and_upload(32, 24, vec![255; 32 * 24 * 4])
            .expect("r2");
        assert_eq!(r1.generation, 1);
        assert_eq!(r2.generation, 1);
        assert!(r2.x >= r1.x + r1.width || r2.y >= r1.y + r1.height);

        // Fill beyond 128x128 to trigger clean generation bump.
        let mut bumped = false;
        for _ in 0..30 {
            let r = atlas
                .allocate_and_upload(40, 40, vec![128; 40 * 40 * 4])
                .expect("alloc after bump");
            if r.generation > 1 {
                bumped = true;
                break;
            }
        }
        assert!(bumped);
    }
}
