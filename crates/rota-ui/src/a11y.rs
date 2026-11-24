//! Semantic Accessibility (`A11yNode`) and macOS `NSAccessibilityElement` bridge (`ui-driver.swift` + VoiceOver).

use std::sync::{Arc, Mutex};

use crate::geometry::Rect;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct UiActionId(pub u64);

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum A11yRole {
    Button,
    TextField,
    TextArea,
    StaticText,
    Heading,
    CheckBox,
    RadioButton,
    PopUpButton,
    Slider,
    Menu,
    MenuItem,
    Row,
    Group,
    ScrollArea,
    Toolbar,
    Table,
    Image,
}

#[derive(Debug, Clone)]
pub struct A11yNode {
    pub id: String,
    pub role: A11yRole,
    pub title: String,
    pub value: Option<String>,
    pub selected: bool,
    pub enabled: bool,
    pub focused: bool,
    pub bounds_in_window: Rect,
    pub action: Option<UiActionId>,
    pub children: Vec<A11yNode>,
}

impl A11yNode {
    pub fn new(
        id: impl Into<String>,
        role: A11yRole,
        title: impl Into<String>,
        bounds_in_window: Rect,
    ) -> Self {
        Self {
            id: id.into(),
            role,
            title: title.into(),
            value: None,
            selected: false,
            enabled: true,
            focused: false,
            bounds_in_window,
            action: None,
            children: Vec::new(),
        }
    }

    pub fn with_action(mut self, action: UiActionId) -> Self {
        self.action = Some(action);
        self
    }

    pub fn with_value(mut self, value: impl Into<String>) -> Self {
        self.value = Some(value.into());
        self
    }

    pub fn with_selected(mut self, selected: bool) -> Self {
        self.selected = selected;
        self
    }

    pub fn with_enabled(mut self, enabled: bool) -> Self {
        self.enabled = enabled;
        self
    }

    pub fn with_focused(mut self, focused: bool) -> Self {
        self.focused = focused;
        self
    }

    pub fn with_children(mut self, children: Vec<A11yNode>) -> Self {
        self.children = children;
        self
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum A11yEvent {
    Press(UiActionId),
    SetValue {
        id: String,
        action: Option<UiActionId>,
        value: String,
    },
    SetSelected {
        id: String,
        action: Option<UiActionId>,
        selected: bool,
    },
    SetFocused {
        id: String,
        action: Option<UiActionId>,
        focused: bool,
    },
}

type WakerFn = Arc<dyn Fn() + Send + Sync>;

#[derive(Clone, Default)]
pub struct A11yActionQueue {
    events: Arc<Mutex<Vec<A11yEvent>>>,
    waker: Arc<Mutex<Option<WakerFn>>>,
}

impl std::fmt::Debug for A11yActionQueue {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("A11yActionQueue").finish()
    }
}

impl A11yActionQueue {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_waker(&self, waker: WakerFn) {
        if let Ok(mut guard) = self.waker.lock() {
            *guard = Some(waker);
        }
    }

    pub fn push(&self, event: A11yEvent) {
        if let Ok(mut guard) = self.events.lock() {
            guard.push(event);
        }
        if let Some(wake) = self.waker.lock().ok().and_then(|g| g.clone()) {
            wake();
        }
    }

    pub fn drain(&self) -> Vec<A11yEvent> {
        self.events
            .lock()
            .map_or_else(|_| Vec::new(), |mut g| std::mem::take(&mut *g))
    }
}

/// Converts top-left window logical bounds into Cocoa bottom-left window logical coordinates.
#[inline]
pub fn flip_top_left_to_cocoa(bounds: Rect, window_content_height: f32) -> Rect {
    Rect::new(
        bounds.x,
        window_content_height - (bounds.y + bounds.height),
        bounds.width,
        bounds.height,
    )
}

pub fn sync_window_a11y(window: &winit::window::Window, nodes: &[A11yNode], queue: &A11yActionQueue) {
    #[cfg(target_os = "macos")]
    crate::a11y_macos::sync_to_winit_window(window, nodes, queue);
    #[cfg(not(target_os = "macos"))]
    let _ = (window, nodes, queue);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cocoa_y_flip_and_ax_press_dispatch() {
        let r = flip_top_left_to_cocoa(Rect::new(20.0, 30.0, 120.0, 40.0), 600.0);
        assert_eq!(r, Rect::new(20.0, 530.0, 120.0, 40.0));
        #[cfg(target_os = "macos")]
        {
            use objc2::msg_send;
            use objc2_app_kit::NSAccessibility;
            let q = A11yActionQueue::new();
            let node = A11yNode::new(
                "new-routine-btn",
                A11yRole::Button,
                "New Routine",
                Rect::new(16.0, 12.0, 96.0, 28.0),
            )
            .with_action(UiActionId(42));
            let el = crate::a11y_macos::RotaAxElement::build_tree(&node, None, 500.0, None, &q);
            assert_eq!(
                el.accessibilityIdentifier().map(|s| s.to_string()),
                Some("new-routine-btn".to_string())
            );
            let ok: bool = unsafe { msg_send![&el, accessibilityPerformPress] };
            assert!(ok);
            assert_eq!(q.drain(), vec![A11yEvent::Press(UiActionId(42))]);
        }
    }
}
