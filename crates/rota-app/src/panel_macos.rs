//! Fast vibrant macOS Tahoe `MenuBarPanel` (`NSPanel` + `NSVisualEffectView` + zero-disk-IO `NSBitmapImageRep` + `MouseUp` activation).

#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

#[cfg(target_os = "macos")]
mod macos {
    use std::ptr::NonNull;
    use std::sync::Mutex;
    use std::sync::mpsc::Sender;

    use objc2::rc::Retained;
    use objc2::runtime::AnyObject;
    use objc2::{AnyThread, DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
    use objc2_app_kit::{
        NSAccessibility, NSAccessibilityButtonRole, NSAccessibilityElement, NSAutoresizingMaskOptions,
        NSBackingStoreType, NSBitmapImageRep, NSColor, NSDeviceRGBColorSpace, NSEvent, NSEventModifierFlags,
        NSImage, NSImageView, NSPanel, NSScreen, NSStatusItem, NSTrackingArea, NSTrackingAreaOptions, NSView,
        NSVisualEffectBlendingMode, NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView,
        NSWindowCollectionBehavior, NSWindowOrderingMode, NSWindowStyleMask,
    };
    use objc2_foundation::{NSArray, NSCopying, NSPoint, NSRect, NSSize, NSString};
    use rota_ui::{A11yNode, ComputedUiTree, GpuRenderer, Point, Rect, Scene, Size, flip_top_left_to_cocoa};

    use crate::actions::{ActionRegistry, PanelInput, ShellEvent};
    use crate::app_state::AppState;
    use crate::shell_macos::wake_app_event_loop;
    use crate::views::panel_view::build_panel_tree;

    pub struct PanelWindowIvars {
        tx: Sender<ShellEvent>,
    }

    define_class!(
        #[unsafe(super(NSPanel, objc2_app_kit::NSWindow, objc2_app_kit::NSResponder, objc2_foundation::NSObject))]
        #[thread_kind = MainThreadOnly]
        #[ivars = PanelWindowIvars]
        pub struct RotaStatusPanel;

        impl RotaStatusPanel {
            #[unsafe(method(canBecomeKeyWindow))]
            fn can_become_key(&self) -> bool {
                true
            }

            #[unsafe(method(canBecomeMainWindow))]
            fn can_become_main(&self) -> bool {
                false
            }

            #[unsafe(method(resignKeyWindow))]
            fn resign_key_window(&self) {
                let _: () = unsafe { msg_send![super(self), resignKeyWindow] };
                let _ = self.ivars().tx.send(ShellEvent::PanelAction(PanelInput::ClosePanel));
                wake_app_event_loop();
            }
        }
    );

    pub struct PanelViewIvars {
        tx: Sender<ShellEvent>,
        hit_boxes: Mutex<Vec<(String, Rect, PanelInput)>>,
        last_hovered: Mutex<Option<String>>,
        pressed_id: Mutex<Option<String>>,
    }

    define_class!(
        #[unsafe(super(NSView, objc2_app_kit::NSResponder, objc2_foundation::NSObject))]
        #[thread_kind = MainThreadOnly]
        #[ivars = PanelViewIvars]
        pub struct RotaPanelView;

        impl RotaPanelView {
            #[unsafe(method(acceptsFirstResponder))]
            fn accepts_first(&self) -> bool {
                true
            }

            #[unsafe(method(isFlipped))]
            fn is_flipped(&self) -> bool {
                true
            }

            #[unsafe(method(mouseMoved:))]
            fn mouse_moved(&self, event: &NSEvent) {
                let win_pt = event.locationInWindow();
                let local = self.convertPoint_fromView(win_pt, None);
                let pt = Point::new(local.x as f32, local.y as f32);
                let hov = self.ivars().hit_boxes.lock().ok().and_then(|list| {
                    list.iter()
                        .rev()
                        .find(|(_, r, _)| r.contains(pt))
                        .map(|(id, _, _)| id.clone())
                });
                if let Ok(mut prev) = self.ivars().last_hovered.lock()
                    && *prev != hov
                {
                    *prev = hov.clone();
                    let _ = self.ivars().tx.send(ShellEvent::PanelAction(PanelInput::Hover(hov)));
                    wake_app_event_loop();
                }
            }

            #[unsafe(method(mouseExited:))]
            fn mouse_exited(&self, _event: &NSEvent) {
                if let Ok(mut prev) = self.ivars().last_hovered.lock()
                    && prev.is_some()
                {
                    *prev = None;
                    let _ = self.ivars().tx.send(ShellEvent::PanelAction(PanelInput::Hover(None)));
                    wake_app_event_loop();
                }
            }

            #[unsafe(method(mouseDown:))]
            fn mouse_down(&self, event: &NSEvent) {
                let win_pt = event.locationInWindow();
                let local = self.convertPoint_fromView(win_pt, None);
                let pt = Point::new(local.x as f32, local.y as f32);
                let hit_id = self.ivars().hit_boxes.lock().ok().and_then(|list| {
                    list.iter()
                        .rev()
                        .find(|(_, r, _)| r.contains(pt))
                        .map(|(id, _, _)| id.clone())
                });
                if let Ok(mut p) = self.ivars().pressed_id.lock() {
                    *p = hit_id;
                }
            }

            #[unsafe(method(mouseUp:))]
            fn mouse_up(&self, event: &NSEvent) {
                let pressed = self
                    .ivars()
                    .pressed_id
                    .lock()
                    .ok()
                    .and_then(|mut g| g.take());
                let Some(expected_id) = pressed else {
                    return;
                };
                let win_pt = event.locationInWindow();
                let local = self.convertPoint_fromView(win_pt, None);
                let pt = Point::new(local.x as f32, local.y as f32);
                let hit = self.ivars().hit_boxes.lock().ok().and_then(|list| {
                    list.iter()
                        .rev()
                        .find(|(id, r, _)| id == &expected_id && r.contains(pt))
                        .map(|(_, _, a)| a.clone())
                });
                if let Some(act) = hit {
                    let _ = self.ivars().tx.send(ShellEvent::PanelAction(act));
                    wake_app_event_loop();
                }
            }

            #[unsafe(method(keyDown:))]
            fn key_down(&self, event: &NSEvent) {
                let code = event.keyCode();
                let cmd = event.modifierFlags().contains(NSEventModifierFlags::Command);
                let action = match (cmd, code) {
                    (false, 126) => Some(PanelInput::MoveHighlight(-1)),
                    (false, 125) => Some(PanelInput::MoveHighlight(1)),
                    (false, 36) => Some(PanelInput::ActivateHighlighted),
                    (false, 53) => Some(PanelInput::ClosePanel),
                    (true, 15) => Some(PanelInput::RunHighlighted),
                    (true, 47) => Some(PanelInput::StopHighlighted),
                    _ => None,
                };
                if let Some(pa) = action {
                    let _ = self.ivars().tx.send(ShellEvent::PanelAction(pa));
                    wake_app_event_loop();
                }
            }
        }
    );

    pub struct PanelAxIvars {
        tx: Sender<ShellEvent>,
        id: String,
        title: String,
        frame: NSRect,
        action: Option<PanelInput>,
    }

    define_class!(
        #[unsafe(super(NSAccessibilityElement, objc2_foundation::NSObject))]
        #[ivars = PanelAxIvars]
        pub struct PanelAxItem;

        impl PanelAxItem {
            #[unsafe(method_id(accessibilityIdentifier))]
            fn ax_id(&self) -> Retained<NSString> {
                NSString::from_str(&self.ivars().id)
            }

            #[unsafe(method_id(accessibilityLabel))]
            fn ax_label(&self) -> Retained<NSString> {
                NSString::from_str(&self.ivars().title)
            }

            #[unsafe(method_id(accessibilityTitle))]
            fn ax_title(&self) -> Retained<NSString> {
                NSString::from_str(&self.ivars().title)
            }

            #[unsafe(method_id(accessibilityRole))]
            fn ax_role(&self) -> Retained<NSString> {
                unsafe { NSAccessibilityButtonRole.copy() }
            }

            #[unsafe(method(accessibilityFrame))]
            fn ax_frame(&self) -> NSRect {
                self.ivars().frame
            }

            #[unsafe(method(isAccessibilityElement))]
            fn is_ax(&self) -> bool {
                true
            }

            #[unsafe(method(accessibilityPerformPress))]
            fn ax_press(&self) -> bool {
                self.ivars().action.as_ref().is_some_and(|pa| {
                    let _ = self.ivars().tx.send(ShellEvent::PanelAction(pa.clone()));
                    wake_app_event_loop();
                    true
                })
            }
        }
    );

    pub struct MenuBarPanel {
        panel: Retained<RotaStatusPanel>,
        view: Retained<RotaPanelView>,
        effect_view: Retained<NSVisualEffectView>,
        image_view: Retained<NSImageView>,
        renderer: Option<GpuRenderer>,
        tx: Sender<ShellEvent>,
        shown: bool,
    }

    impl MenuBarPanel {
        const WIDTH: f32 = 340.0;

        pub fn new(mtm: MainThreadMarker, tx: Sender<ShellEvent>) -> Self {
            let rect = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(340.0, 320.0));
            let style = NSWindowStyleMask::Borderless | NSWindowStyleMask::NonactivatingPanel;
            let panel_alloc = RotaStatusPanel::alloc(mtm).set_ivars(PanelWindowIvars { tx: tx.clone() });
            // SAFETY: Standard `NSPanel` designated initializer on the main thread.
            let panel: Retained<RotaStatusPanel> = unsafe {
                msg_send![
                    super(panel_alloc),
                    initWithContentRect: rect,
                    styleMask: style,
                    backing: NSBackingStoreType::Buffered,
                    defer: false
                ]
            };
            panel.setTitle(&NSString::from_str(""));
            panel.setOpaque(false);
            panel.setBackgroundColor(Some(&NSColor::clearColor()));
            panel.setHasShadow(true);
            panel.setFloatingPanel(true);
            panel.setAcceptsMouseMovedEvents(true);
            panel.setLevel(25);
            panel.setCollectionBehavior(
                NSWindowCollectionBehavior::CanJoinAllSpaces
                    | NSWindowCollectionBehavior::FullScreenAuxiliary,
            );

            let view_alloc = RotaPanelView::alloc(mtm).set_ivars(PanelViewIvars {
                tx: tx.clone(),
                hit_boxes: Mutex::new(Vec::new()),
                last_hovered: Mutex::new(None),
                pressed_id: Mutex::new(None),
            });
            let view: Retained<RotaPanelView> = unsafe { msg_send![super(view_alloc), initWithFrame: rect] };
            view.setWantsLayer(true);
            if let Some(layer) = view.layer() {
                layer.setCornerRadius(14.0);
                layer.setMasksToBounds(true);
            }

            let tracking_opts = NSTrackingAreaOptions::MouseEnteredAndExited
                | NSTrackingAreaOptions::MouseMoved
                | NSTrackingAreaOptions::ActiveAlways
                | NSTrackingAreaOptions::InVisibleRect;
            let tracking: Retained<NSTrackingArea> = unsafe {
                NSTrackingArea::initWithRect_options_owner_userInfo(
                    mtm.alloc(),
                    rect,
                    tracking_opts,
                    Some(&view),
                    None,
                )
            };
            view.addTrackingArea(&tracking);

            let effect_view: Retained<NSVisualEffectView> =
                unsafe { msg_send![NSVisualEffectView::alloc(mtm), initWithFrame: rect] };
            effect_view.setMaterial(NSVisualEffectMaterial::Popover);
            effect_view.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
            effect_view.setState(NSVisualEffectState::Active);
            effect_view.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
            );

            let image_view = NSImageView::initWithFrame(mtm.alloc(), rect);
            view.addSubview(&effect_view);
            view.addSubview_positioned_relativeTo(
                &image_view,
                NSWindowOrderingMode::Above,
                Some(&effect_view),
            );
            panel.setContentView(Some(&view));

            Self {
                panel,
                view,
                effect_view,
                image_view,
                renderer: None,
                tx,
                shown: false,
            }
        }

        pub fn show_at_top_of_screen(&mut self, mtm: MainThreadMarker, state: &mut AppState) -> isize {
            let h = self.render_contents(state);
            if let Some(screen) = NSScreen::mainScreen(mtm) {
                let vf = screen.visibleFrame();
                let origin = NSPoint::new(
                    vf.origin.x + vf.size.width * 0.5 - 170.0,
                    vf.origin.y + vf.size.height - 40.0 - f64::from(h),
                );
                self.panel.setFrameOrigin(origin);
            }
            self.present_key();
            self.panel.windowNumber()
        }

        pub fn sync_and_present(
            &mut self,
            mtm: MainThreadMarker,
            status_item: &NSStatusItem,
            state: &mut AppState,
        ) {
            let prev_top = self.shown.then(|| {
                let f = self.panel.frame();
                f.origin.y + f.size.height
            });
            let h = self.render_contents(state);
            if let Some(top_y) = prev_top {
                let cur = self.panel.frame();
                self.panel
                    .setFrameOrigin(NSPoint::new(cur.origin.x, top_y - f64::from(h)));
            } else {
                if let Some(btn) = status_item.button(mtm)
                    && let Some(btn_win) = btn.window()
                {
                    let b_rect = btn.convertRect_toView(btn.bounds(), None);
                    let s_rect = btn_win.convertRectToScreen(b_rect);
                    let mut x = s_rect.origin.x + s_rect.size.width * 0.5 - 170.0;
                    if let Some(scr) = NSScreen::mainScreen(mtm) {
                        let vf = scr.visibleFrame();
                        x = x.clamp(vf.origin.x + 8.0, vf.origin.x + vf.size.width - 348.0);
                    }
                    self.panel
                        .setFrameOrigin(NSPoint::new(x, s_rect.origin.y - f64::from(h) - 6.0));
                }
                self.present_key();
            }
        }

        fn present_key(&mut self) {
            self.shown = true;
            self.panel.makeKeyAndOrderFront(None);
            let _ = self.panel.makeFirstResponder(Some(&self.view));
        }

        pub fn hide(&mut self) {
            if self.shown {
                self.shown = false;
                self.panel.orderOut(None);
            }
        }

        fn render_contents(&mut self, state: &mut AppState) -> f32 {
            if self.renderer.is_none() {
                self.renderer = GpuRenderer::new_headless().ok();
            }
            let theme = state.theme();
            let rows = state.routines.len().clamp(1, 8);
            let more_h = if state.routines.len() > 8 { 28.0 } else { 0.0 };
            let extra = usize::from(state.attention_count > 0) + usize::from(state.unread_count > 0);
            let panel_h = (58.0 + (rows as f32) * 44.0 + more_h + (extra as f32) * 35.0).clamp(136.0, 468.0);

            let size = NSSize::new(f64::from(Self::WIDTH), f64::from(panel_h));
            self.panel.setContentSize(size);
            let frame = NSRect::new(NSPoint::new(0.0, 0.0), size);
            self.view.setFrame(frame);
            self.effect_view.setFrame(frame);
            self.effect_view.setHidden(!state.window_vibrant);
            self.image_view.setFrame(frame);

            let mut reg = ActionRegistry::new();
            let mut panel_map: Vec<(String, PanelInput)> = Vec::new();
            let root = build_panel_tree(state, &theme, panel_h, &mut reg, &mut panel_map);

            let Some(renderer) = self.renderer.as_mut() else {
                return panel_h;
            };
            let tree =
                ComputedUiTree::compute(&mut renderer.text, root, Size::new(Self::WIDTH, panel_h), 2.0);
            let mut scene = Scene::new(rota_ui::Color::TRANSPARENT);
            let a11y_nodes = tree.paint(renderer, &mut scene, 2.0);

            let mut hits = Vec::new();
            let mut ax_items: Vec<Retained<PanelAxItem>> = Vec::new();
            for (el_id, pa) in panel_map {
                if let Some(bounds) = tree.bounds_by_id(&el_id) {
                    hits.push((el_id.clone(), bounds, pa.clone()));
                    let title = find_node_title(&a11y_nodes, &el_id).unwrap_or_else(|| el_id.clone());
                    let fl = flip_top_left_to_cocoa(bounds, panel_h);
                    let win_r = NSRect::new(
                        NSPoint::new(f64::from(fl.x), f64::from(fl.y)),
                        NSSize::new(f64::from(fl.width), f64::from(fl.height)),
                    );
                    let scr_r = self.panel.convertRectToScreen(win_r);
                    let item_alloc = PanelAxItem::alloc().set_ivars(PanelAxIvars {
                        tx: self.tx.clone(),
                        id: el_id,
                        title,
                        frame: scr_r,
                        action: Some(pa),
                    });
                    let item: Retained<PanelAxItem> = unsafe { msg_send![super(item_alloc), init] };
                    ax_items.push(item);
                }
            }
            if let Ok(mut g) = self.view.ivars().hit_boxes.lock() {
                *g = hits;
            }
            let refs: Vec<&AnyObject> = ax_items.iter().map(|i| i.as_ref() as &AnyObject).collect();
            unsafe {
                self.view
                    .setAccessibilityChildren(Some(&NSArray::from_slice(&refs)))
            };

            if let Ok((pw, ph, rgba)) =
                renderer.render_to_rgba(Self::WIDTH as u32, panel_h as u32, 2.0, &scene)
                && let Some(img) = rgba_to_nsimage(pw, ph, &rgba, size)
            {
                self.image_view.setImage(Some(&img));
            }
            panel_h
        }
    }

    fn rgba_to_nsimage(pw: u32, ph: u32, rgba: &[u8], logical_size: NSSize) -> Option<Retained<NSImage>> {
        if rgba.len() < (pw as usize) * (ph as usize) * 4 {
            return None;
        }
        // SAFETY: `NSBitmapImageRep` with `planes = null` allocates its own internal buffer; we copy unpremultiplied/premultiplied RGBA directly into `bitmapData`.
        unsafe {
            let rep = NSBitmapImageRep::initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel(
                NSBitmapImageRep::alloc(),
                std::ptr::null_mut::<*mut u8>(),
                pw as isize,
                ph as isize,
                8,
                4,
                true,
                false,
                NSDeviceRGBColorSpace,
                (pw as isize) * 4,
                32,
            )?;
            let dst = NonNull::new(rep.bitmapData())?;
            std::ptr::copy_nonoverlapping(rgba.as_ptr(), dst.as_ptr(), (pw as usize) * (ph as usize) * 4);
            let img = NSImage::initWithSize(NSImage::alloc(), logical_size);
            img.addRepresentation(&rep);
            Some(img)
        }
    }

    fn find_node_title(nodes: &[A11yNode], id: &str) -> Option<String> {
        nodes.iter().find_map(|n| {
            (n.id == id)
                .then(|| n.title.clone())
                .or_else(|| find_node_title(&n.children, id))
        })
    }
}

#[cfg(target_os = "macos")]
pub use macos::MenuBarPanel;
