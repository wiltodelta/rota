//! Declarative Flexbox & CSS Grid `UiElement` builder types.

use std::path::PathBuf;

use taffy::Overflow;
use taffy::prelude::*;

use crate::a11y::{A11yRole, UiActionId};
use crate::color::Color;
use crate::geometry::{Corners, Edges, Point, Rect, Size};
use crate::icons::IconKind;
use crate::text::{TextLayoutOpts, TextSpan};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CursorKind {
    #[default]
    Arrow,
    PointingHand,
    IBeam,
    ResizeColumn,
    Crosshair,
}

#[derive(Debug, Clone)]
pub enum UiContent {
    None,
    Text {
        spans: Vec<TextSpan>,
        opts: TextLayoutOpts,
    },
    Icon {
        kind: IconKind,
        size: f32,
        color: Color,
    },
    Image {
        path: PathBuf,
        display_size: Size,
        corners: Corners,
        opacity: f32,
    },
}

#[derive(Debug, Clone)]
pub struct A11ySpec {
    pub role: A11yRole,
    pub title: String,
    pub value: Option<String>,
    pub selected: bool,
    pub enabled: bool,
    pub focused: bool,
}

impl A11ySpec {
    pub fn new(role: A11yRole, title: impl Into<String>) -> Self {
        Self {
            role,
            title: title.into(),
            value: None,
            selected: false,
            enabled: true,
            focused: false,
        }
    }
}

/// Declarative Flexbox / Grid UI element node compiled via `taffy`.
#[derive(Debug, Clone)]
pub struct UiElement {
    pub id: Option<String>,
    pub style: Style,
    pub content: UiContent,
    pub background: Option<Color>,
    pub corners: Corners,
    pub border_width: f32,
    pub border_color: Color,
    pub shadow_blur: f32,
    pub shadow_offset: Point,
    pub shadow_color: Color,
    pub clip_children: bool,
    pub z_layer: u8,
    pub blocks_lower_layers: bool,
    pub hit_testable: bool,
    pub action: Option<UiActionId>,
    pub cursor: CursorKind,
    pub tooltip: Option<String>,
    pub a11y: Option<A11ySpec>,
    pub scroll_offset: Point,
    pub children: Vec<UiElement>,
}

impl Default for UiElement {
    fn default() -> Self {
        Self {
            id: None,
            style: Style::default(),
            content: UiContent::None,
            background: None,
            corners: Corners::ZERO,
            border_width: 0.0,
            border_color: Color::TRANSPARENT,
            shadow_blur: 0.0,
            shadow_offset: Point::ZERO,
            shadow_color: Color::TRANSPARENT,
            clip_children: false,
            z_layer: 0,
            blocks_lower_layers: false,
            hit_testable: false,
            action: None,
            cursor: CursorKind::Arrow,
            tooltip: None,
            a11y: None,
            scroll_offset: Point::ZERO,
            children: Vec::new(),
        }
    }
}

impl UiElement {
    pub fn row() -> Self {
        let mut el = Self::default();
        el.style.display = Display::Flex;
        el.style.flex_direction = FlexDirection::Row;
        el
    }

    pub fn column() -> Self {
        let mut el = Self::default();
        el.style.display = Display::Flex;
        el.style.flex_direction = FlexDirection::Column;
        el
    }

    pub fn grid(columns: Vec<GridTemplateComponent<String>>) -> Self {
        let mut el = Self::default();
        el.style.display = Display::Grid;
        el.style.grid_template_columns = columns;
        el
    }

    pub fn text(spans: Vec<TextSpan>, opts: TextLayoutOpts) -> Self {
        Self {
            content: UiContent::Text { spans, opts },
            ..Self::default()
        }
    }

    pub fn icon(kind: IconKind, size: f32, color: Color) -> Self {
        let mut el = Self {
            content: UiContent::Icon { kind, size, color },
            ..Self::default()
        };
        el.style.size = taffy::Size {
            width: Dimension::length(size),
            height: Dimension::length(size),
        };
        el.style.flex_shrink = 0.0;
        el
    }

    pub fn id(mut self, id: impl Into<String>) -> Self {
        self.id = Some(id.into());
        self
    }

    pub fn width(mut self, w: f32) -> Self {
        self.style.size.width = Dimension::length(w);
        self
    }

    pub fn max_width(mut self, w: f32) -> Self {
        self.style.max_size.width = LengthPercentageAuto::length(w);
        self
    }

    pub fn height(mut self, h: f32) -> Self {
        self.style.size.height = Dimension::length(h);
        self
    }

    pub fn min_height(mut self, h: f32) -> Self {
        self.style.min_size.height = LengthPercentageAuto::length(h);
        self
    }

    pub fn fill_size(mut self) -> Self {
        self.style.size = taffy::Size {
            width: Dimension::percent(1.0),
            height: Dimension::percent(1.0),
        };
        self
    }

    pub fn flex_grow(mut self, grow: f32) -> Self {
        self.style.flex_grow = grow;
        self
    }

    pub fn flex_shrink(mut self, shrink: f32) -> Self {
        self.style.flex_shrink = shrink;
        self
    }

    pub fn gap(mut self, gap_pt: f32) -> Self {
        self.style.gap = taffy::Size {
            width: LengthPercentage::length(gap_pt),
            height: LengthPercentage::length(gap_pt),
        };
        self
    }

    pub fn padding(mut self, edges: Edges) -> Self {
        self.style.padding = taffy::Rect {
            top: LengthPercentage::length(edges.top),
            right: LengthPercentage::length(edges.right),
            bottom: LengthPercentage::length(edges.bottom),
            left: LengthPercentage::length(edges.left),
        };
        self
    }

    pub fn align_center(mut self) -> Self {
        self.style.align_items = AlignItems::CENTER;
        self
    }

    pub fn justify_between(mut self) -> Self {
        self.style.justify_content = JustifyContent::SPACE_BETWEEN;
        self
    }

    pub fn justify_center(mut self) -> Self {
        self.style.justify_content = JustifyContent::CENTER;
        self
    }

    pub fn justify_end(mut self) -> Self {
        self.style.justify_content = JustifyContent::FLEX_END;
        self
    }

    pub fn absolute(mut self, rect: Rect) -> Self {
        self.style.position = Position::Absolute;
        self.style.inset = taffy::Rect {
            left: LengthPercentageAuto::length(rect.x),
            top: LengthPercentageAuto::length(rect.y),
            right: LengthPercentageAuto::auto(),
            bottom: LengthPercentageAuto::auto(),
        };
        self.style.size = taffy::Size {
            width: Dimension::length(rect.width),
            height: Dimension::length(rect.height),
        };
        self
    }

    pub fn bg(mut self, color: Color) -> Self {
        self.background = Some(color);
        self
    }

    pub fn rounded(mut self, radius: f32) -> Self {
        self.corners = Corners::all(radius);
        self
    }

    pub fn border(mut self, width: f32, color: Color) -> Self {
        self.border_width = width;
        self.border_color = color;
        self
    }

    pub fn shadow(mut self, blur: f32, offset: Point, color: Color) -> Self {
        self.shadow_blur = blur;
        self.shadow_offset = offset;
        self.shadow_color = color;
        self
    }

    pub fn clip(mut self) -> Self {
        self.clip_children = true;
        self.style.overflow = taffy::Point {
            x: Overflow::Hidden,
            y: Overflow::Hidden,
        };
        self
    }

    pub fn scroll_offset(mut self, offset: Point) -> Self {
        self.scroll_offset = offset;
        self
    }

    pub fn z_layer(mut self, layer: u8, blocks_lower: bool) -> Self {
        self.z_layer = layer;
        self.blocks_lower_layers = blocks_lower;
        self
    }

    pub fn hit_box(mut self) -> Self {
        self.hit_testable = true;
        self
    }

    pub fn on_click(mut self, action: UiActionId) -> Self {
        self.action = Some(action);
        if self.cursor == CursorKind::Arrow {
            self.cursor = CursorKind::PointingHand;
        }
        self
    }

    pub fn cursor(mut self, cursor: CursorKind) -> Self {
        self.cursor = cursor;
        self
    }

    pub fn tooltip(mut self, text: impl Into<String>) -> Self {
        self.tooltip = Some(text.into());
        self
    }

    pub fn a11y(mut self, spec: A11ySpec) -> Self {
        self.a11y = Some(spec);
        self
    }

    pub fn child(mut self, child: UiElement) -> Self {
        self.children.push(child);
        self
    }

    pub fn children(mut self, iter: impl IntoIterator<Item = UiElement>) -> Self {
        self.children.extend(iter);
        self
    }
}
