//! GPU-accelerated 120 Hz Metal / `wgpu 30` UI engine for Rota.

pub mod a11y;
#[cfg(target_os = "macos")]
mod a11y_macos;
pub mod atlas;
pub mod color;
pub mod element;
#[cfg(target_os = "macos")]
mod font_macos;
pub mod geometry;
pub mod icons;
#[cfg(target_os = "macos")]
mod icons_macos;
pub mod image_cache;
pub mod layout;
mod pipeline;
pub mod primitives;
pub mod renderer;
pub mod scene;
pub mod scroll;
pub mod scroll_physics;
pub mod selection;
pub mod spring;
pub mod text;
pub mod text_input;
#[cfg(target_os = "macos")]
mod text_macos;
pub mod text_nav;
pub mod theme;
pub mod window;
#[cfg(target_os = "macos")]
pub mod window_macos;
pub mod window_types;

pub use a11y::{
    A11yActionQueue, A11yEvent, A11yNode, A11yRole, UiActionId, flip_top_left_to_cocoa, sync_window_a11y,
};
pub use atlas::{AtlasRegion, TextureAtlas};
pub use color::{Color, contrast_ratio, linear_to_srgb, srgb_to_linear};
pub use element::{A11ySpec, CursorKind, UiContent, UiElement};
pub use geometry::{Corners, Edges, Point, Rect, Size, snap_half_px, snap_px};
pub use icons::{IconCache, IconKind, rasterize_icon_rgba};
pub use image_cache::{ImageCache, ResolvedImage, decode_image_rgba8};
pub use layout::{ComputedUiTree, HitTarget};
pub use primitives::{GpuGlobals, GpuPrimitive, PrimitiveKind, QuadSpec};
pub use renderer::{GpuRenderer, WindowSurface, save_png};
pub use scene::Scene;
pub use scroll::{VirtualScrollState, VirtualVisibleRange};
pub use scroll_physics::{ScrollPhysics, scroll_y_from_track_pointer};
pub use selection::{SelectableBlock, SelectionEndpoint, TranscriptSelection};
pub use spring::{SpringSet, lerp_color};
pub use text::{
    FontFamily, FontStyle, FontWeight, ShapedLine, ShapedParagraph, TextAlign, TextLayoutOpts, TextSpan,
    TextSystem,
};
pub use text_input::{EditKey, EditOutcome, Modifiers, ReturnBehavior, TextEditState};
pub use theme::{Appearance, Theme, UiScales};
pub use window::{
    ActivityClock, FrameContext, FrameOutput, RotaWindowDelegate, UiInputEvent, WindowAppearance,
    WindowConfig, WindowRunner, apply_macos_appearance,
};
pub use winit::event::{MouseButton, MouseScrollDelta, TouchPhase};
pub use winit::window::Window as NativeWindow;

#[cfg(test)]
mod tests;
