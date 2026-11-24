//! macOS `NSAccessibilityElement` bridge with persistent Objective-C element identity across 120 Hz Metal redraws.

use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::sync::Mutex;

use objc2::rc::Retained;
use objc2::runtime::{AnyObject, Sel};
use objc2::{AnyThread, DefinedClass, define_class, msg_send};
use objc2_app_kit::{
    NSAccessibility, NSAccessibilityActionName, NSAccessibilityButtonRole, NSAccessibilityCheckBoxRole,
    NSAccessibilityElement, NSAccessibilityGroupRole, NSAccessibilityImageRole, NSAccessibilityMenuItemRole,
    NSAccessibilityMenuRole, NSAccessibilityPopUpButtonRole, NSAccessibilityPressAction,
    NSAccessibilityRadioButtonRole, NSAccessibilityRole, NSAccessibilityRowRole,
    NSAccessibilityScrollAreaRole, NSAccessibilitySliderRole, NSAccessibilityStaticTextRole,
    NSAccessibilityTableRole, NSAccessibilityTextAreaRole, NSAccessibilityTextFieldRole,
    NSAccessibilityToolbarRole, NSView, NSWindow,
};
use objc2_foundation::{NSArray, NSNumber, NSPoint, NSRect, NSSize, NSString};

use crate::a11y::{A11yActionQueue, A11yEvent, A11yNode, A11yRole, flip_top_left_to_cocoa};

thread_local! {
    static AX_POOL: RefCell<HashMap<(usize, String), Retained<RotaAxElement>>> =
        RefCell::new(HashMap::new());
}

pub struct AxIvars {
    state: Mutex<AxState>,
}

struct AxState {
    node: A11yNode,
    initializing: bool,
    _children: Vec<Retained<RotaAxElement>>,
    queue: A11yActionQueue,
}

fn str_to_any(s: &str) -> Retained<AnyObject> {
    Retained::into_super(Retained::into_super(NSString::from_str(s)))
}

fn ns_role(role: A11yRole) -> &'static NSAccessibilityRole {
    // SAFETY: AppKit role globals are immortal `NSString` constants.
    unsafe {
        match role {
            A11yRole::Button => NSAccessibilityButtonRole,
            A11yRole::TextField => NSAccessibilityTextFieldRole,
            A11yRole::TextArea => NSAccessibilityTextAreaRole,
            A11yRole::StaticText | A11yRole::Heading => NSAccessibilityStaticTextRole,
            A11yRole::CheckBox => NSAccessibilityCheckBoxRole,
            A11yRole::RadioButton => NSAccessibilityRadioButtonRole,
            A11yRole::PopUpButton => NSAccessibilityPopUpButtonRole,
            A11yRole::Slider => NSAccessibilitySliderRole,
            A11yRole::Menu => NSAccessibilityMenuRole,
            A11yRole::MenuItem => NSAccessibilityMenuItemRole,
            A11yRole::Row => NSAccessibilityRowRole,
            A11yRole::Group => NSAccessibilityGroupRole,
            A11yRole::ScrollArea => NSAccessibilityScrollAreaRole,
            A11yRole::Toolbar => NSAccessibilityToolbarRole,
            A11yRole::Table => NSAccessibilityTableRole,
            A11yRole::Image => NSAccessibilityImageRole,
        }
    }
}

define_class!(
    #[unsafe(super(NSAccessibilityElement))]
    #[ivars = AxIvars]
    pub struct RotaAxElement;

    impl RotaAxElement {
        #[unsafe(method(isAccessibilitySelectorAllowed:))]
        fn is_selector_allowed(&self, _selector: Sel) -> bool {
            true
        }

        #[unsafe(method(setAccessibilityValue:))]
        fn set_ax_value(&self, val: Option<&AnyObject>) {
            let _: () = unsafe { msg_send![super(self), setAccessibilityValue: val] };
            let Some(obj) = val else { return };
            let (initializing, id, action, queue) = {
                let st = self.ivars().state.lock().expect("ax lock");
                (st.initializing, st.node.id.clone(), st.node.action, st.queue.clone())
            };
            if initializing {
                return;
            }
            // SAFETY: `description` is implemented by every NSObject.
            let desc: Retained<NSString> = unsafe { msg_send![obj, description] };
            let text = desc.to_string();
            self.ivars().state.lock().expect("ax lock").node.value = Some(text.clone());
            queue.push(A11yEvent::SetValue {
                id,
                action,
                value: text,
            });
        }

        #[unsafe(method(setAccessibilitySelected:))]
        fn set_ax_selected(&self, selected: bool) {
            let _: () = unsafe { msg_send![super(self), setAccessibilitySelected: selected] };
            let (initializing, id, action, queue) = {
                let mut st = self.ivars().state.lock().expect("ax lock");
                st.node.selected = selected;
                (st.initializing, st.node.id.clone(), st.node.action, st.queue.clone())
            };
            if !initializing {
                queue.push(A11yEvent::SetSelected {
                    id,
                    action,
                    selected,
                });
            }
        }

        #[unsafe(method(setAccessibilityFocused:))]
        fn set_ax_focused(&self, focused: bool) {
            let _: () = unsafe { msg_send![super(self), setAccessibilityFocused: focused] };
            let (initializing, id, action, queue) = {
                let mut st = self.ivars().state.lock().expect("ax lock");
                st.node.focused = focused;
                (st.initializing, st.node.id.clone(), st.node.action, st.queue.clone())
            };
            if !initializing {
                queue.push(A11yEvent::SetFocused {
                    id,
                    action,
                    focused,
                });
            }
        }

        #[unsafe(method(accessibilityPerformPress))]
        fn ax_perform_press(&self) -> bool {
            let (enabled, action, queue) = {
                let st = self.ivars().state.lock().expect("ax lock");
                (st.node.enabled, st.node.action, st.queue.clone())
            };
            if let (true, Some(act)) = (enabled, action) {
                queue.push(A11yEvent::Press(act));
                true
            } else {
                false
            }
        }

        #[unsafe(method_id(accessibilityActionNames))]
        fn ax_action_names(&self) -> Retained<NSArray<NSAccessibilityActionName>> {
            let has_action = self.ivars().state.lock().expect("ax lock").node.action.is_some();
            if has_action {
                // SAFETY: `NSAccessibilityPressAction` is an immortal AppKit constant.
                unsafe { NSArray::from_slice(&[NSAccessibilityPressAction]) }
            } else {
                NSArray::new()
            }
        }

        #[unsafe(method(accessibilityPerformAction:))]
        fn ax_perform_action(&self, action: &NSAccessibilityActionName) {
            // SAFETY: `NSAccessibilityPressAction` is an immortal AppKit constant.
            let is_press = unsafe { action == NSAccessibilityPressAction };
            if is_press {
                let _: bool = unsafe { msg_send![self, accessibilityPerformPress] };
            }
        }
    }
);

struct BuildCtx<'a> {
    view_key: usize,
    content_h: f32,
    ns_window: Option<&'a NSWindow>,
    queue: &'a A11yActionQueue,
    pool: Option<&'a mut HashMap<(usize, String), Retained<RotaAxElement>>>,
    seen: &'a mut HashSet<String>,
}

impl RotaAxElement {
    #[cfg(test)]
    pub fn build_tree(
        node: &A11yNode,
        parent_obj: Option<&AnyObject>,
        content_h: f32,
        ns_window: Option<&NSWindow>,
        queue: &A11yActionQueue,
    ) -> Retained<Self> {
        let mut seen = HashSet::new();
        let mut ctx = BuildCtx {
            view_key: 0,
            content_h,
            ns_window,
            queue,
            pool: None,
            seen: &mut seen,
        };
        Self::build_or_reuse(node, parent_obj, &mut ctx)
    }

    fn build_or_reuse(
        node: &A11yNode,
        parent_obj: Option<&AnyObject>,
        ctx: &mut BuildCtx<'_>,
    ) -> Retained<Self> {
        let flipped = flip_top_left_to_cocoa(node.bounds_in_window, ctx.content_h);
        let win_rect = NSRect::new(
            NSPoint::new(f64::from(flipped.x), f64::from(flipped.y)),
            NSSize::new(f64::from(flipped.width), f64::from(flipped.height)),
        );
        let screen_frame = ctx
            .ns_window
            .map_or(win_rect, |w| w.convertRectToScreen(win_rect));

        let reused = if !node.id.is_empty() && ctx.seen.insert(node.id.clone()) {
            ctx.pool
                .as_ref()
                .and_then(|p| p.get(&(ctx.view_key, node.id.clone())).cloned())
        } else {
            None
        };

        let retained = if let Some(existing) = reused {
            {
                let mut st = existing.ivars().state.lock().expect("ax lock");
                st.initializing = true;
                st.node = node.clone();
                st.queue = ctx.queue.clone();
            }
            existing
        } else {
            let this = Self::alloc().set_ivars(AxIvars {
                state: Mutex::new(AxState {
                    node: node.clone(),
                    initializing: true,
                    _children: Vec::new(),
                    queue: ctx.queue.clone(),
                }),
            });
            // SAFETY: `NSAccessibilityElement` `-init` is standard designated initializer.
            let fresh: Retained<Self> = unsafe { msg_send![super(this), init] };
            if !node.id.is_empty()
                && let Some(pool) = ctx.pool.as_mut()
            {
                pool.insert((ctx.view_key, node.id.clone()), fresh.clone());
            }
            fresh
        };

        let is_container = !node.children.is_empty()
            && matches!(
                node.role,
                A11yRole::Group | A11yRole::ScrollArea | A11yRole::Toolbar | A11yRole::Table | A11yRole::Menu
            );
        retained.setAccessibilityElement(!is_container);
        if node.role == A11yRole::Heading {
            retained.setAccessibilityRole(Some(&NSString::from_str("AXHeading")));
        } else {
            retained.setAccessibilityRole(Some(ns_role(node.role)));
        }
        if !node.id.is_empty() {
            retained.setAccessibilityIdentifier(Some(&NSString::from_str(&node.id)));
        }
        let ns_title = NSString::from_str(&node.title);
        retained.setAccessibilityTitle(if node.title.is_empty() {
            None
        } else {
            Some(&ns_title)
        });
        retained.setAccessibilityLabel(if node.title.is_empty() {
            None
        } else {
            Some(&ns_title)
        });
        retained.setAccessibilityFrame(screen_frame);
        retained.setAccessibilityEnabled(node.enabled);
        retained.setAccessibilitySelected(node.selected);
        retained.setAccessibilityFocused(node.focused);

        let val_obj: Option<Retained<AnyObject>> = match node.role {
            A11yRole::CheckBox | A11yRole::RadioButton => {
                let num = NSNumber::new_i32(i32::from(node.selected));
                Some(Retained::into_super(Retained::into_super(Retained::into_super(
                    num,
                ))))
            }
            A11yRole::Slider => {
                let v = node
                    .value
                    .as_deref()
                    .and_then(|s| s.parse::<f64>().ok())
                    .unwrap_or(1.0);
                let num = NSNumber::new_f64(v);
                Some(Retained::into_super(Retained::into_super(Retained::into_super(
                    num,
                ))))
            }
            A11yRole::StaticText | A11yRole::Heading => {
                Some(str_to_any(node.value.as_deref().unwrap_or(&node.title)))
            }
            _ => node.value.as_deref().map(str_to_any),
        };
        // SAFETY: `parent_obj` and `val_obj` are valid Objective-C objects.
        unsafe {
            retained.setAccessibilityParent(parent_obj);
            retained.setAccessibilityValue(val_obj.as_deref());
        }

        if node.children.is_empty() {
            unsafe { retained.setAccessibilityChildren(None) };
            retained.ivars().state.lock().expect("ax lock")._children.clear();
        } else {
            let self_any: &AnyObject = retained.as_ref();
            let built: Vec<Retained<Self>> = node
                .children
                .iter()
                .map(|ch| Self::build_or_reuse(ch, Some(self_any), ctx))
                .collect();
            let refs: Vec<&AnyObject> = built.iter().map(|c| c.as_ref() as &AnyObject).collect();
            let ns_arr = NSArray::from_slice(&refs);
            // SAFETY: `ns_arr` contains valid `NSAccessibilityElement` instances.
            unsafe { retained.setAccessibilityChildren(Some(&ns_arr)) };
            retained.ivars().state.lock().expect("ax lock")._children = built;
        }
        retained.ivars().state.lock().expect("ax lock").initializing = false;
        retained
    }
}

pub fn sync_to_winit_window(window: &winit::window::Window, nodes: &[A11yNode], queue: &A11yActionQueue) {
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    let Ok(handle) = window.window_handle() else {
        return;
    };
    let RawWindowHandle::AppKit(appkit) = handle.as_raw() else {
        return;
    };
    let view_key = appkit.ns_view.as_ptr() as usize;
    // SAFETY: `winit` guarantees `ns_view` is a live `NSView` on the main thread.
    let ns_view: &NSView = unsafe { appkit.ns_view.cast::<NSView>().as_ref() };
    ns_view.setAccessibilityElement(false);
    let ns_window = ns_view.window();
    let content_h = ns_view.bounds().size.height as f32;
    let view_any: &AnyObject = ns_view.as_ref();

    let elements: Vec<Retained<RotaAxElement>> = AX_POOL.with(|cell| {
        let mut pool = cell.borrow_mut();
        let mut seen = HashSet::new();
        let built: Vec<Retained<RotaAxElement>> = {
            let mut ctx = BuildCtx {
                view_key,
                content_h,
                ns_window: ns_window.as_deref(),
                queue,
                pool: Some(&mut pool),
                seen: &mut seen,
            };
            nodes
                .iter()
                .map(|n| RotaAxElement::build_or_reuse(n, Some(view_any), &mut ctx))
                .collect()
        };
        pool.retain(|(vk, id), _| *vk != view_key || seen.contains(id));
        built
    });

    let obj_refs: Vec<&AnyObject> = elements.iter().map(|e| e.as_ref() as &AnyObject).collect();
    let ns_array = NSArray::from_slice(&obj_refs);
    // SAFETY: `ns_array` contains valid `NSAccessibilityElement` instances.
    unsafe { ns_view.setAccessibilityChildren(Some(&ns_array)) };
}
