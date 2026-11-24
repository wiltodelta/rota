//! Single-pass instanced `wgpu 30` Metal renderer supporting windowed 120 Hz and headless RGBA.

use std::path::Path;
use std::sync::Arc;

use rota_platform::Logger;

use crate::atlas::TextureAtlas;
use crate::color::Color;
use crate::geometry::{Corners, Point, Rect};
use crate::icons::{IconCache, IconKind};
use crate::image_cache::ImageCache;
use crate::pipeline::{
    begin_clear_pass, create_atlas_texture, create_bind_group, create_bind_group_layout, create_pipeline,
    create_primitive_buffer, execute_offscreen_rgba,
};
use crate::primitives::{GpuGlobals, GpuPrimitive, QuadSpec, as_byte_slice};
use crate::scene::Scene;
use crate::text::{ShapedParagraph, TextLayoutOpts, TextSpan, TextSystem};

const LOG: Logger = Logger::new("ui");

/// Swapchain surface state for a live 120 Hz ProMotion window.
pub struct WindowSurface {
    surface: wgpu::Surface<'static>,
    config: wgpu::SurfaceConfiguration,
    srgb_view_format: wgpu::TextureFormat,
}

impl WindowSurface {
    pub fn resize(&mut self, device: &wgpu::Device, width: u32, height: u32) {
        let (w, h) = (width.max(1), height.max(1));
        if self.config.width != w || self.config.height != h {
            self.config.width = w;
            self.config.height = h;
            self.surface.configure(device, &self.config);
        }
    }

    #[inline]
    pub fn pixel_size(&self) -> (u32, u32) {
        (self.config.width, self.config.height)
    }

    #[inline]
    pub fn target_format(&self) -> wgpu::TextureFormat {
        self.srgb_view_format
    }
}

/// Metal / `wgpu 30` GPU UI engine owning pipelines, dynamic buffers, atlases, text, icons, and images.
pub struct GpuRenderer {
    instance: wgpu::Instance,
    adapter: wgpu::Adapter,
    device: wgpu::Device,
    queue: wgpu::Queue,
    shader: wgpu::ShaderModule,
    bind_group_layout: wgpu::BindGroupLayout,
    pipeline_layout: wgpu::PipelineLayout,
    offscreen_pipeline: wgpu::RenderPipeline,
    surface_pipeline: Option<(wgpu::TextureFormat, wgpu::RenderPipeline)>,
    globals_buffer: wgpu::Buffer,
    primitive_buffer: wgpu::Buffer,
    primitive_capacity: usize,
    mask_gpu_tex: wgpu::Texture,
    color_gpu_tex: wgpu::Texture,
    bind_group: wgpu::BindGroup,
    pub mask_atlas: TextureAtlas,
    pub color_atlas: TextureAtlas,
    pub text: TextSystem,
    pub icons: IconCache,
    pub images: ImageCache,
}

impl GpuRenderer {
    pub fn new_headless() -> Result<Self, String> {
        let instance = wgpu::Instance::default();
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        }))
        .map_err(|e| format!("Failed to request GPU adapter: {e}"))?;
        Self::from_adapter(instance, adapter)
    }

    pub fn new_with_window(window: Arc<winit::window::Window>) -> Result<(Self, WindowSurface), String> {
        let instance = wgpu::Instance::default();
        let surface = instance
            .create_surface(window.clone())
            .map_err(|e| format!("Failed to create window surface: {e}"))?;
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: Some(&surface),
            force_fallback_adapter: false,
            apply_limit_buckets: false,
        }))
        .map_err(|e| format!("Failed to request compatible GPU adapter: {e}"))?;

        let mut renderer = Self::from_adapter(instance, adapter)?;
        let win_surface = renderer.configure_window_surface(surface, &window)?;
        Ok((renderer, win_surface))
    }

    pub fn create_secondary_surface(
        &mut self,
        window: Arc<winit::window::Window>,
    ) -> Result<WindowSurface, String> {
        let surface = self
            .instance
            .create_surface(window.clone())
            .map_err(|e| format!("Failed to create secondary surface: {e}"))?;
        self.configure_window_surface(surface, &window)
    }

    fn configure_window_surface(
        &mut self,
        surface: wgpu::Surface<'static>,
        window: &winit::window::Window,
    ) -> Result<WindowSurface, String> {
        let size = window.inner_size();
        let mut config = surface
            .get_default_config(&self.adapter, size.width.max(1), size.height.max(1))
            .ok_or_else(|| "Surface incompatible with GPU adapter".to_string())?;
        let caps = surface.get_capabilities(&self.adapter);
        if let Some(srgb_fmt) = caps.formats.iter().copied().find(wgpu::TextureFormat::is_srgb) {
            config.format = srgb_fmt;
        }
        let srgb_view_format = config.format.add_srgb_suffix();
        if srgb_view_format != config.format {
            config.view_formats = vec![srgb_view_format];
        }
        if let Some(alpha) = caps
            .alpha_modes
            .iter()
            .copied()
            .find(|m| *m == wgpu::CompositeAlphaMode::PreMultiplied)
            .or_else(|| {
                caps.alpha_modes
                    .iter()
                    .copied()
                    .find(|m| *m == wgpu::CompositeAlphaMode::PostMultiplied)
            })
        {
            config.alpha_mode = alpha;
        }
        config.present_mode = wgpu::PresentMode::AutoVsync;
        surface.configure(&self.device, &config);
        self.ensure_surface_pipeline(srgb_view_format);
        Ok(WindowSurface {
            surface,
            config,
            srgb_view_format,
        })
    }

    fn from_adapter(instance: wgpu::Instance, adapter: wgpu::Adapter) -> Result<Self, String> {
        let info = adapter.get_info();
        LOG.info(&format!(
            "Initialized GPU adapter: {} ({:?})",
            info.name, info.backend
        ));
        let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("rota-ui-device"),
            required_features: wgpu::Features::empty(),
            required_limits: wgpu::Limits::default(),
            memory_hints: wgpu::MemoryHints::Performance,
            ..Default::default()
        }))
        .map_err(|e| format!("Failed to request GPU device: {e}"))?;

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("rota-ui-shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });
        let bind_group_layout = create_bind_group_layout(&device);
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("rota-ui-pipeline-layout"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            immediate_size: 0,
        });
        let offscreen_pipeline = create_pipeline(
            &device,
            &pipeline_layout,
            &shader,
            wgpu::TextureFormat::Rgba8UnormSrgb,
        );
        let globals_buffer = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("rota-ui-globals"),
            size: std::mem::size_of::<GpuGlobals>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let initial_cap = 2048usize;
        let primitive_buffer = create_primitive_buffer(&device, initial_cap);
        let mask_gpu_tex = create_atlas_texture(
            &device,
            "rota-mask-atlas",
            TextureAtlas::DEFAULT_SIZE,
            wgpu::TextureFormat::Rgba8Unorm,
        );
        let color_gpu_tex = create_atlas_texture(
            &device,
            "rota-color-atlas",
            TextureAtlas::DEFAULT_SIZE,
            wgpu::TextureFormat::Rgba8UnormSrgb,
        );
        let bind_group = create_bind_group(
            &device,
            &bind_group_layout,
            &globals_buffer,
            &primitive_buffer,
            &mask_gpu_tex,
            &color_gpu_tex,
        );

        Ok(Self {
            instance,
            adapter,
            device,
            queue,
            shader,
            bind_group_layout,
            pipeline_layout,
            offscreen_pipeline,
            surface_pipeline: None,
            globals_buffer,
            primitive_buffer,
            primitive_capacity: initial_cap,
            mask_gpu_tex,
            color_gpu_tex,
            bind_group,
            mask_atlas: TextureAtlas::new(TextureAtlas::DEFAULT_SIZE, TextureAtlas::DEFAULT_SIZE),
            color_atlas: TextureAtlas::new(TextureAtlas::DEFAULT_SIZE, TextureAtlas::DEFAULT_SIZE),
            text: TextSystem::new(),
            icons: IconCache::new(),
            images: ImageCache::default(),
        })
    }

    #[inline]
    pub fn device(&self) -> &wgpu::Device {
        &self.device
    }

    pub fn draw_icon(
        &mut self,
        scene: &mut Scene,
        kind: IconKind,
        bounds: Rect,
        color: Color,
        scale_factor: f32,
    ) {
        let sf = scale_factor.max(1.0);
        let snapped = Rect::new(
            (bounds.x * sf).round() / sf,
            (bounds.y * sf).round() / sf,
            (bounds.width * sf).round().max(1.0) / sf,
            (bounds.height * sf).round().max(1.0) / sf,
        );
        let clip = scene.current_clip();
        if clip.intersects(snapped)
            && let Some(uv) =
                self.icons
                    .resolve(kind, snapped.width.max(snapped.height), sf, &mut self.mask_atlas)
        {
            scene.push_raw(GpuPrimitive::icon_mask(snapped, uv, color, clip));
        }
    }

    pub fn draw_text(
        &mut self,
        scene: &mut Scene,
        origin: Point,
        spans: &[TextSpan],
        opts: TextLayoutOpts,
        scale_factor: f32,
    ) -> ShapedParagraph {
        let shaped = self.text.shape_paragraph(spans, opts, scale_factor);
        self.draw_shaped_paragraph(scene, origin, &shaped);
        shaped
    }

    pub fn draw_shaped_paragraph(&mut self, scene: &mut Scene, origin: Point, paragraph: &ShapedParagraph) {
        let clip = scene.current_clip();
        if !clip.intersects(Rect::from_origin_size(origin, paragraph.size).expand_uniform(4.0)) {
            return;
        }
        let sf = paragraph.scale_factor.max(1.0);
        for line in &paragraph.lines {
            for dec in &line.decorations {
                if dec.is_background {
                    scene.push_quad(
                        QuadSpec::solid(dec.rect.offset(origin.x, origin.y), dec.color).rounded(4.0),
                    );
                }
            }
            for g in &line.glyphs {
                let pen_px_x = (origin.x + line.x_offset + g.pen_x) * sf;
                let snapped_pen_px_x = pen_px_x.floor();
                let subpx_bin = if g.key.is_color {
                    0
                } else {
                    (((pen_px_x - snapped_pen_px_x).clamp(0.0, 0.999) * 4.0).floor() as u8).min(3)
                };
                let mut key = g.key;
                key.subpx_x = subpx_bin;
                let Some(entry) = self
                    .text
                    .resolve_glyph(key, &mut self.mask_atlas, &mut self.color_atlas)
                else {
                    continue;
                };
                if entry.region.width == 0 || entry.region.height == 0 {
                    continue;
                }
                let base_px_y = ((origin.y + g.baseline_y) * sf).round();
                let gx = (snapped_pen_px_x + entry.pixel_offset.x) / sf;
                let gy = (base_px_y + entry.pixel_offset.y) / sf;
                let bounds = Rect::from_origin_size(Point::new(gx, gy), entry.logical_size);
                if !clip.intersects(bounds) {
                    continue;
                }
                if entry.is_color {
                    let uv = self.color_atlas.uv_for(entry.region);
                    scene.push_raw(GpuPrimitive::color_bitmap(
                        bounds,
                        uv,
                        Corners::ZERO,
                        Color::WHITE.with_alpha(g.color.a),
                        true,
                        clip,
                    ));
                } else {
                    let uv = self.mask_atlas.uv_for(entry.region);
                    scene.push_raw(GpuPrimitive::mask(bounds, uv, g.color, clip));
                }
            }
            for dec in &line.decorations {
                if !dec.is_background {
                    scene.push_quad(QuadSpec::solid(dec.rect.offset(origin.x, origin.y), dec.color));
                }
            }
        }
    }

    pub fn draw_image_path(
        &mut self,
        scene: &mut Scene,
        path: &Path,
        bounds: Rect,
        corners: Corners,
        opacity: f32,
    ) -> bool {
        let clip = scene.current_clip();
        if !clip.intersects(bounds) {
            return true;
        }
        let Some(img) = self.images.resolve_path(path, &mut self.color_atlas) else {
            return false;
        };
        scene.push_raw(GpuPrimitive::color_bitmap(
            bounds,
            img.uv_rect,
            corners,
            Color::WHITE.with_alpha(opacity),
            false,
            clip,
        ));
        true
    }

    fn ensure_surface_pipeline(&mut self, format: wgpu::TextureFormat) {
        if self.surface_pipeline.as_ref().is_none_or(|(f, _)| *f != format) {
            let p = create_pipeline(&self.device, &self.pipeline_layout, &self.shader, format);
            self.surface_pipeline = Some((format, p));
        }
    }

    fn prepare_draw(&mut self, logical_w: f32, logical_h: f32, scale_factor: f32, scene: &Scene) -> u32 {
        self.mask_atlas.flush_to_gpu(&self.queue, &self.mask_gpu_tex);
        self.color_atlas.flush_to_gpu(&self.queue, &self.color_gpu_tex);
        let globals = [GpuGlobals {
            viewport_size: [logical_w.max(1.0), logical_h.max(1.0)],
            scale_factor: scale_factor.max(1.0),
            _pad: 0.0,
        }];
        self.queue
            .write_buffer(&self.globals_buffer, 0, as_byte_slice(&globals));

        let total = scene.primitive_count();
        if total > self.primitive_capacity {
            self.primitive_capacity = total.next_power_of_two().max(2048);
            self.primitive_buffer = create_primitive_buffer(&self.device, self.primitive_capacity);
            self.bind_group = create_bind_group(
                &self.device,
                &self.bind_group_layout,
                &self.globals_buffer,
                &self.primitive_buffer,
                &self.mask_gpu_tex,
                &self.color_gpu_tex,
            );
        }
        let base = scene.base_primitives();
        let base_bytes = as_byte_slice(base);
        if !base_bytes.is_empty() {
            self.queue.write_buffer(&self.primitive_buffer, 0, base_bytes);
        }
        let overlay_bytes = as_byte_slice(scene.overlay_primitives());
        if !overlay_bytes.is_empty() {
            self.queue
                .write_buffer(&self.primitive_buffer, base_bytes.len() as u64, overlay_bytes);
        }
        total as u32
    }

    pub fn render_to_surface(
        &mut self,
        win_surface: &mut WindowSurface,
        scale_factor: f32,
        scene: &Scene,
    ) -> Result<(), String> {
        let (pw, ph) = win_surface.pixel_size();
        let sf = scale_factor.max(1.0);
        let count = self.prepare_draw(pw as f32 / sf, ph as f32 / sf, sf, scene);
        self.ensure_surface_pipeline(win_surface.target_format());

        let frame = match win_surface.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(f) | wgpu::CurrentSurfaceTexture::Suboptimal(f) => f,
            wgpu::CurrentSurfaceTexture::Lost | wgpu::CurrentSurfaceTexture::Outdated => {
                win_surface.surface.configure(&self.device, &win_surface.config);
                return Ok(());
            }
            wgpu::CurrentSurfaceTexture::Timeout | wgpu::CurrentSurfaceTexture::Occluded => {
                return Ok(());
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                return Err("Surface acquire validation error".to_string());
            }
        };
        let view = frame.texture.create_view(&wgpu::TextureViewDescriptor {
            format: Some(win_surface.target_format()),
            ..Default::default()
        });
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("rota-surface-encoder"),
            });
        {
            let (_, pipeline) = self.surface_pipeline.as_ref().expect("pipeline ready");
            let mut rpass = begin_clear_pass(&mut encoder, &view, scene.clear_color);
            if count > 0 {
                rpass.set_pipeline(pipeline);
                rpass.set_bind_group(0, &self.bind_group, &[]);
                rpass.draw(0..6, 0..count);
            }
        }
        self.queue.submit(std::iter::once(encoder.finish()));
        self.queue.present(frame);
        Ok(())
    }

    /// Renders `scene` offscreen on Metal GPU without opening any window and reads back straight sRGB RGBA8.
    pub fn render_to_rgba(
        &mut self,
        logical_width: u32,
        logical_height: u32,
        scale_factor: f32,
        scene: &Scene,
    ) -> Result<(u32, u32, Vec<u8>), String> {
        let sf = scale_factor.max(1.0);
        let px_w = ((logical_width.max(1) as f32) * sf).round() as u32;
        let px_h = ((logical_height.max(1) as f32) * sf).round() as u32;
        let count = self.prepare_draw(logical_width as f32, logical_height as f32, sf, scene);
        execute_offscreen_rgba(
            &self.device,
            &self.queue,
            &self.offscreen_pipeline,
            &self.bind_group,
            (px_w, px_h),
            scene.clear_color,
            count,
        )
    }
}

/// Saves an RGBA8 buffer to a PNG file.
pub fn save_png(path: &Path, width: u32, height: u32, rgba: &[u8]) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| e.to_string())?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), width, height);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(rgba).map_err(|e| e.to_string())
}
