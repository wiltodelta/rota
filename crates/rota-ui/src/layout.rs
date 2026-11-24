//! `taffy 0.15` layout computation, wrapped-text leaf measurement, z-layer hit-testing, and painting.

use std::collections::HashMap;

use taffy::prelude::*;

use crate::a11y::{A11yNode, UiActionId};
use crate::color::Color;
use crate::element::{CursorKind, UiContent, UiElement};
use crate::geometry::{Corners, Edges, Point, Rect, Size};
use crate::primitives::QuadSpec;
use crate::renderer::GpuRenderer;
use crate::scene::Scene;
use crate::text::{ShapedParagraph, TextSystem};

#[derive(Debug, Clone, PartialEq)]
pub struct HitTarget {
    pub id: Option<String>,
    pub action: Option<UiActionId>,
    pub cursor: CursorKind,
    pub tooltip: Option<String>,
    pub bounds: Rect,
    pub z_layer: u8,
}

struct LayoutNodeEntry {
    element: UiElement,
    taffy_id: NodeId,
    bounds: Rect,
    clip_rect: Rect,
    effective_z: u8,
    shaped_text: Option<ShapedParagraph>,
    child_indices: Vec<usize>,
}

/// Computed frame layout supporting O(1) ID bounds lookup, clip-aware hit-testing, and GPU painting.
pub struct ComputedUiTree {
    nodes: Vec<LayoutNodeEntry>,
    by_id: HashMap<String, usize>,
}

impl ComputedUiTree {
    pub fn compute(text_system: &mut TextSystem, root: UiElement, viewport: Size, scale_factor: f32) -> Self {
        let mut taffy: TaffyTree<usize> = TaffyTree::new();
        let mut nodes = Vec::with_capacity(128);
        let root_idx = insert_recursive(&mut taffy, &mut nodes, root);
        let root_taffy = nodes[root_idx].taffy_id;

        let avail = taffy::Size {
            width: AvailableSpace::Definite(viewport.width),
            height: AvailableSpace::Definite(viewport.height),
        };
        let _ = taffy.compute_layout_with_measure(root_taffy, avail, |inputs, _node_id, node_ctx, style| {
            taffy::compute_leaf_layout(
                inputs,
                style,
                |_, _| 0.0,
                |known_dims, avail_space| {
                    let Some(&mut idx) = node_ctx else {
                        return taffy::Size::ZERO;
                    };
                    match &nodes[idx].element.content {
                        UiContent::Text { spans, opts } => {
                            let mut measure_opts = *opts;
                            let no_shrink_1line =
                                opts.max_lines == Some(1) && nodes[idx].element.style.flex_shrink == 0.0;
                            let width_constraint = known_dims.width.or(match avail_space.width {
                                AvailableSpace::Definite(w) => Some(w),
                                AvailableSpace::MinContent if no_shrink_1line => opts.max_width,
                                AvailableSpace::MinContent => Some(36.0),
                                AvailableSpace::MaxContent => opts.max_width,
                            });
                            if let Some(w) = width_constraint {
                                measure_opts.max_width =
                                    Some(opts.max_width.map_or(w, |m| m.min(w)).max(1.0));
                            }
                            let shaped = text_system.shape_paragraph(spans, measure_opts, scale_factor);
                            let sz = taffy::Size {
                                width: known_dims.width.unwrap_or((shaped.size.width + 0.5).ceil()),
                                height: known_dims.height.unwrap_or((shaped.size.height + 0.5).ceil()),
                            };
                            nodes[idx].shaped_text = Some(shaped);
                            sz
                        }
                        UiContent::Icon { size, .. } => taffy::Size {
                            width: known_dims.width.unwrap_or(*size),
                            height: known_dims.height.unwrap_or(*size),
                        },
                        UiContent::Image { display_size, .. } => taffy::Size {
                            width: known_dims.width.unwrap_or(display_size.width),
                            height: known_dims.height.unwrap_or(display_size.height),
                        },
                        UiContent::None => taffy::Size::ZERO,
                    }
                },
            )
        });

        let mut by_id = HashMap::new();
        resolve_geometry(
            &taffy,
            &mut nodes,
            &mut by_id,
            root_idx,
            Point::ZERO,
            Rect::from_origin_size(Point::ZERO, viewport),
            0,
            text_system,
            scale_factor,
        );
        Self { nodes, by_id }
    }

    pub fn bounds_by_id(&self, id: &str) -> Option<Rect> {
        let &idx = self.by_id.get(id)?;
        Some(self.nodes[idx].bounds)
    }

    pub fn shaped_text_by_id(&self, id: &str) -> Option<(Rect, &ShapedParagraph)> {
        let &idx = self.by_id.get(id)?;
        let n = &self.nodes[idx];
        Some((n.bounds, n.shaped_text.as_ref()?))
    }

    /// Hit-tests `point` from highest `z_layer` down to `0`, honoring nested `clip_rect` and modal blockers.
    pub fn hit_test(&self, point: Point) -> Option<HitTarget> {
        let max_z = self.nodes.iter().map(|n| n.effective_z).max()?;
        for layer in (0..=max_z).rev() {
            if let Some(hit) = self.hit_node_in_layer(0, point, layer) {
                return Some(hit);
            }
        }
        None
    }

    fn hit_node_in_layer(&self, idx: usize, point: Point, target_layer: u8) -> Option<HitTarget> {
        let entry = &self.nodes[idx];
        for &ch in entry.child_indices.iter().rev() {
            if let Some(mut hit) = self.hit_node_in_layer(ch, point, target_layer) {
                if hit.action.is_none() && entry.effective_z == target_layer && entry.element.action.is_some()
                {
                    hit.action = entry.element.action;
                    hit.bounds = entry.bounds;
                    if entry.element.id.is_some() {
                        hit.id = entry.element.id.clone();
                    }
                    if hit.cursor == CursorKind::Arrow {
                        hit.cursor = entry.element.cursor;
                    }
                    if hit.tooltip.is_none() {
                        hit.tooltip = entry.element.tooltip.clone();
                    }
                }
                return Some(hit);
            }
        }
        if entry.effective_z != target_layer || !entry.bounds.intersect(entry.clip_rect).contains(point) {
            return None;
        }
        let interactive = entry.element.action.is_some()
            || entry.element.hit_testable
            || entry.element.cursor != CursorKind::Arrow
            || entry.element.tooltip.is_some()
            || entry.element.blocks_lower_layers;
        interactive.then(|| HitTarget {
            id: entry.element.id.clone(),
            action: entry.element.action,
            cursor: entry.element.cursor,
            tooltip: entry.element.tooltip.clone(),
            bounds: entry.bounds,
            z_layer: entry.effective_z,
        })
    }

    pub fn paint(&self, renderer: &mut GpuRenderer, scene: &mut Scene, scale_factor: f32) -> Vec<A11yNode> {
        if self.nodes.is_empty() {
            Vec::new()
        } else {
            self.paint_recursive(0, renderer, scene, scale_factor)
        }
    }

    fn paint_recursive(
        &self,
        idx: usize,
        renderer: &mut GpuRenderer,
        scene: &mut Scene,
        scale_factor: f32,
    ) -> Vec<A11yNode> {
        let entry = &self.nodes[idx];
        let el = &entry.element;
        let paint_body = |renderer: &mut GpuRenderer, scene: &mut Scene| -> Vec<A11yNode> {
            if el.background.is_some() || el.border_width > 0.0 || el.shadow_blur > 0.0 {
                scene.push_quad(QuadSpec {
                    bounds: entry.bounds,
                    corners: el.corners,
                    fill: el.background.unwrap_or(Color::TRANSPARENT),
                    border_width: el.border_width,
                    border_color: el.border_color,
                    shadow_blur: el.shadow_blur,
                    shadow_offset: el.shadow_offset,
                    shadow_color: el.shadow_color,
                });
            }
            match &el.content {
                UiContent::None => {}
                UiContent::Text { .. } => {
                    if let Some(para) = &entry.shaped_text {
                        renderer.draw_shaped_paragraph(scene, entry.bounds.origin(), para);
                    }
                }
                UiContent::Icon { kind, color, .. } => {
                    renderer.draw_icon(scene, *kind, entry.bounds, *color, scale_factor);
                }
                UiContent::Image {
                    path,
                    corners,
                    opacity,
                    ..
                } => {
                    let _ = renderer.draw_image_path(scene, path, entry.bounds, *corners, *opacity);
                }
            }
            if el.clip_children {
                let bw = el.border_width.max(0.0);
                let inner_bounds = if bw > 0.0 {
                    entry.bounds.inset(Edges::all(bw))
                } else {
                    entry.bounds
                };
                let inner_corners = Corners {
                    top_left: (el.corners.top_left - bw).max(0.0),
                    top_right: (el.corners.top_right - bw).max(0.0),
                    bottom_right: (el.corners.bottom_right - bw).max(0.0),
                    bottom_left: (el.corners.bottom_left - bw).max(0.0),
                };
                scene.push_rounded_clip(inner_bounds, inner_corners);
            }
            let mut child_a11y = Vec::new();
            for &ch in &entry.child_indices {
                child_a11y.extend(self.paint_recursive(ch, renderer, scene, scale_factor));
            }
            if el.clip_children {
                scene.pop_clip();
            }
            let Some(meta) = &el.a11y else {
                return child_a11y;
            };
            let id = el.id.clone().unwrap_or_else(|| meta.title.clone());
            let mut a11y_node = A11yNode::new(id, meta.role, meta.title.clone(), entry.bounds)
                .with_selected(meta.selected)
                .with_enabled(meta.enabled)
                .with_focused(meta.focused)
                .with_children(child_a11y);
            if let Some(v) = &meta.value {
                a11y_node = a11y_node.with_value(v.clone());
            }
            if let Some(act) = el.action {
                a11y_node = a11y_node.with_action(act);
            }
            vec![a11y_node]
        };

        if idx > 0 && el.z_layer > 0 && !scene.is_in_overlay() {
            let mut out = Vec::new();
            scene.with_overlay(|s| out = paint_body(renderer, s));
            out
        } else {
            paint_body(renderer, scene)
        }
    }
}

fn insert_recursive(
    taffy: &mut TaffyTree<usize>,
    nodes: &mut Vec<LayoutNodeEntry>,
    mut element: UiElement,
) -> usize {
    let raw_children = std::mem::take(&mut element.children);
    let idx = nodes.len();
    let placeholder_id = taffy.new_leaf(Style::default()).expect("taffy leaf");
    nodes.push(LayoutNodeEntry {
        element,
        taffy_id: placeholder_id,
        bounds: Rect::ZERO,
        clip_rect: Rect::INFINITE_CLIP,
        effective_z: 0,
        shaped_text: None,
        child_indices: Vec::with_capacity(raw_children.len()),
    });
    let mut taffy_children = Vec::with_capacity(raw_children.len());
    let mut child_indices = Vec::with_capacity(raw_children.len());
    for ch in raw_children {
        let ch_idx = insert_recursive(taffy, nodes, ch);
        taffy_children.push(nodes[ch_idx].taffy_id);
        child_indices.push(ch_idx);
    }
    let style = nodes[idx].element.style.clone();
    let real_id = if taffy_children.is_empty() {
        taffy.new_leaf_with_context(style, idx).expect("taffy leaf ctx")
    } else {
        taffy
            .new_with_children(style, &taffy_children)
            .expect("taffy parent")
    };
    let _ = taffy.remove(placeholder_id);
    nodes[idx].taffy_id = real_id;
    nodes[idx].child_indices = child_indices;
    idx
}

#[allow(clippy::too_many_arguments)]
fn resolve_geometry(
    taffy: &TaffyTree<usize>,
    nodes: &mut [LayoutNodeEntry],
    by_id: &mut HashMap<String, usize>,
    idx: usize,
    parent_origin: Point,
    inherited_clip: Rect,
    inherited_z: u8,
    text_system: &mut TextSystem,
    scale_factor: f32,
) {
    let lay = taffy.layout(nodes[idx].taffy_id).expect("computed layout");
    let bounds = Rect::new(
        parent_origin.x + lay.location.x,
        parent_origin.y + lay.location.y,
        lay.size.width,
        lay.size.height,
    );
    let effective_z = inherited_z.max(nodes[idx].element.z_layer);
    let clip = if nodes[idx].element.z_layer > inherited_z {
        Rect::INFINITE_CLIP
    } else {
        inherited_clip
    };
    if let UiContent::Text { spans, opts } = &nodes[idx].element.content {
        let mut final_opts = *opts;
        final_opts.max_width = Some((bounds.width + 0.5).max(1.0));
        nodes[idx].shaped_text = Some(text_system.shape_paragraph(spans, final_opts, scale_factor));
    }
    nodes[idx].bounds = bounds;
    nodes[idx].clip_rect = clip;
    nodes[idx].effective_z = effective_z;
    if let Some(id) = &nodes[idx].element.id {
        by_id.insert(id.clone(), idx);
    }
    let next_clip = if nodes[idx].element.clip_children {
        clip.intersect(bounds)
    } else {
        clip
    };
    let scroll = nodes[idx].element.scroll_offset;
    let child_origin = Point::new(bounds.x - scroll.x, bounds.y - scroll.y);
    let children = nodes[idx].child_indices.clone();
    for ch in children {
        resolve_geometry(
            taffy,
            nodes,
            by_id,
            ch,
            child_origin,
            next_clip,
            effective_z,
            text_system,
            scale_factor,
        );
    }
}
