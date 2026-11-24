//! 2D logical coordinate geometry and `@2x` physical-pixel snapping primitives.

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

impl Point {
    pub const ZERO: Self = Self { x: 0.0, y: 0.0 };

    #[inline]
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }

    #[inline]
    pub fn offset(self, dx: f32, dy: f32) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
        }
    }

    #[inline]
    pub fn snap_to_pixels(self, scale_factor: f32) -> Self {
        Self {
            x: snap_px(self.x, scale_factor),
            y: snap_px(self.y, scale_factor),
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Size {
    pub width: f32,
    pub height: f32,
}

impl Size {
    pub const ZERO: Self = Self {
        width: 0.0,
        height: 0.0,
    };

    #[inline]
    pub const fn new(width: f32, height: f32) -> Self {
        Self { width, height }
    }

    #[inline]
    pub const fn square(side: f32) -> Self {
        Self {
            width: side,
            height: side,
        }
    }

    #[inline]
    pub fn is_empty(self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Edges {
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
    pub left: f32,
}

impl Edges {
    pub const ZERO: Self = Self::all(0.0);

    #[inline]
    pub const fn all(v: f32) -> Self {
        Self {
            top: v,
            right: v,
            bottom: v,
            left: v,
        }
    }

    #[inline]
    pub const fn symmetric(vertical: f32, horizontal: f32) -> Self {
        Self {
            top: vertical,
            right: horizontal,
            bottom: vertical,
            left: horizontal,
        }
    }

    #[inline]
    pub const fn xy(horizontal: f32, vertical: f32) -> Self {
        Self {
            top: vertical,
            right: horizontal,
            bottom: vertical,
            left: horizontal,
        }
    }

    #[inline]
    pub const fn new(top: f32, right: f32, bottom: f32, left: f32) -> Self {
        Self {
            top,
            right,
            bottom,
            left,
        }
    }

    #[inline]
    pub fn horizontal(self) -> f32 {
        self.left + self.right
    }

    #[inline]
    pub fn vertical(self) -> f32 {
        self.top + self.bottom
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Corners {
    pub top_left: f32,
    pub top_right: f32,
    pub bottom_right: f32,
    pub bottom_left: f32,
}

impl Corners {
    pub const ZERO: Self = Self::all(0.0);

    #[inline]
    pub const fn all(radius: f32) -> Self {
        Self {
            top_left: radius,
            top_right: radius,
            bottom_right: radius,
            bottom_left: radius,
        }
    }

    #[inline]
    pub const fn new(top_left: f32, top_right: f32, bottom_right: f32, bottom_left: f32) -> Self {
        Self {
            top_left,
            top_right,
            bottom_right,
            bottom_left,
        }
    }

    #[inline]
    pub const fn to_array(self) -> [f32; 4] {
        [self.top_left, self.top_right, self.bottom_right, self.bottom_left]
    }
}

/// Top-left origin rectangle in logical window points.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    pub const ZERO: Self = Self::new(0.0, 0.0, 0.0, 0.0);
    pub const INFINITE_CLIP: Self = Self::new(-1.0e6, -1.0e6, 2.0e6, 2.0e6);

    #[inline]
    pub const fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self { x, y, width, height }
    }

    #[inline]
    pub const fn from_origin_size(origin: Point, size: Size) -> Self {
        Self {
            x: origin.x,
            y: origin.y,
            width: size.width,
            height: size.height,
        }
    }

    #[inline]
    pub fn from_min_max(min_x: f32, min_y: f32, max_x: f32, max_y: f32) -> Self {
        Self {
            x: min_x,
            y: min_y,
            width: (max_x - min_x).max(0.0),
            height: (max_y - min_y).max(0.0),
        }
    }

    #[inline]
    pub const fn origin(self) -> Point {
        Point::new(self.x, self.y)
    }

    #[inline]
    pub const fn size(self) -> Size {
        Size::new(self.width, self.height)
    }

    #[inline]
    pub fn min_x(self) -> f32 {
        self.x
    }

    #[inline]
    pub fn min_y(self) -> f32 {
        self.y
    }

    #[inline]
    pub fn max_x(self) -> f32 {
        self.x + self.width
    }

    #[inline]
    pub fn max_y(self) -> f32 {
        self.y + self.height
    }

    #[inline]
    pub fn center(self) -> Point {
        Point::new(self.x + self.width * 0.5, self.y + self.height * 0.5)
    }

    #[inline]
    pub fn is_empty(self) -> bool {
        self.width <= 0.0 || self.height <= 0.0
    }

    #[inline]
    pub fn contains(self, p: Point) -> bool {
        !self.is_empty()
            && p.x >= self.x
            && p.x <= self.x + self.width
            && p.y >= self.y
            && p.y <= self.y + self.height
    }

    #[inline]
    pub fn intersect(self, other: Self) -> Self {
        let x0 = self.min_x().max(other.min_x());
        let y0 = self.min_y().max(other.min_y());
        let x1 = self.max_x().min(other.max_x());
        let y1 = self.max_y().min(other.max_y());
        Self::from_min_max(x0, y0, x1, y1)
    }

    #[inline]
    pub fn intersects(self, other: Self) -> bool {
        !self.intersect(other).is_empty()
    }

    #[inline]
    pub fn contains_rect(self, inner: Self) -> bool {
        inner.is_empty()
            || (inner.min_x() >= self.min_x()
                && inner.min_y() >= self.min_y()
                && inner.max_x() <= self.max_x()
                && inner.max_y() <= self.max_y())
    }

    #[inline]
    pub fn inset(self, edges: Edges) -> Self {
        Self {
            x: self.x + edges.left,
            y: self.y + edges.top,
            width: (self.width - edges.left - edges.right).max(0.0),
            height: (self.height - edges.top - edges.bottom).max(0.0),
        }
    }

    #[inline]
    pub fn inset_uniform(self, delta: f32) -> Self {
        self.inset(Edges::all(delta))
    }

    #[inline]
    pub fn expand_uniform(self, delta: f32) -> Self {
        Self {
            x: self.x - delta,
            y: self.y - delta,
            width: (self.width + delta * 2.0).max(0.0),
            height: (self.height + delta * 2.0).max(0.0),
        }
    }

    #[inline]
    pub fn offset(self, dx: f32, dy: f32) -> Self {
        Self {
            x: self.x + dx,
            y: self.y + dy,
            width: self.width,
            height: self.height,
        }
    }

    /// Snaps rectangle edges to physical device pixel boundaries for crisp `@2x` borders.
    #[inline]
    pub fn snap_to_pixels(self, scale_factor: f32) -> Self {
        let min_x = snap_px(self.min_x(), scale_factor);
        let min_y = snap_px(self.min_y(), scale_factor);
        let max_x = snap_px(self.max_x(), scale_factor);
        let max_y = snap_px(self.max_y(), scale_factor);
        Self::from_min_max(min_x, min_y, max_x, max_y)
    }

    #[inline]
    pub fn to_xywh(self) -> [f32; 4] {
        [self.x, self.y, self.width, self.height]
    }

    #[inline]
    pub fn to_clip_array(self) -> [f32; 4] {
        [self.min_x(), self.min_y(), self.max_x(), self.max_y()]
    }
}

/// Snaps a logical coordinate to the nearest physical device pixel.
#[inline]
pub fn snap_px(value: f32, scale_factor: f32) -> f32 {
    let s = scale_factor.max(1.0);
    (value * s).round() / s
}

/// Snaps a 1-device-pixel hairline stroke center to `(n + 0.5) / scale_factor`.
#[inline]
pub fn snap_half_px(value: f32, scale_factor: f32) -> f32 {
    let s = scale_factor.max(1.0);
    ((value * s).floor() + 0.5) / s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rect_intersection_inset_and_pixel_snapping() {
        let a = Rect::new(10.0, 20.0, 100.0, 80.0);
        let b = Rect::new(50.0, 60.0, 100.0, 80.0);
        assert_eq!(a.intersect(b), Rect::new(50.0, 60.0, 60.0, 40.0));
        assert!(a.contains(Point::new(55.0, 65.0)));
        assert!(!a.contains(Point::new(5.0, 65.0)));

        let inset = a.inset(Edges::symmetric(5.0, 10.0));
        assert_eq!(inset, Rect::new(20.0, 25.0, 80.0, 70.0));

        let unsnapped = Rect::new(10.24, 20.76, 50.02, 30.0);
        let snapped = unsnapped.snap_to_pixels(2.0);
        assert_eq!(snapped, Rect::new(10.0, 21.0, 50.5, 30.0));
    }
}
