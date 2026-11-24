//! macOS AppKit window integration: unified full-size titlebar, `NSVisualEffectView` vibrancy, & appearance.

#![cfg(target_os = "macos")]

use objc2::rc::Retained;
use objc2::{MainThreadOnly, Message, msg_send};
use objc2_app_kit::{
    NSAppearance, NSAppearanceCustomization, NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSApplication,
    NSAutoresizingMaskOptions, NSColor, NSToolbar, NSView, NSVisualEffectBlendingMode,
    NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindow, NSWindowOrderingMode,
    NSWindowStyleMask, NSWindowTitleVisibility, NSWindowToolbarStyle, NSWorkspace,
};
use objc2_foundation::{MainThreadMarker, NSObjectProtocol, NSString};
use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
use winit::window::Window;

use crate::window::WindowAppearance;

pub fn macos_reduce_transparency() -> bool {
    NSWorkspace::sharedWorkspace().accessibilityDisplayShouldReduceTransparency()
}

pub fn macos_increase_contrast() -> bool {
    NSWorkspace::sharedWorkspace().accessibilityDisplayShouldIncreaseContrast()
}

pub fn macos_reduce_motion() -> bool {
    NSWorkspace::sharedWorkspace().accessibilityDisplayShouldReduceMotion()
}

pub fn apply_macos_appearance(window: &Window, appearance: WindowAppearance) {
    let Some(ns_win) = macos_ns_window(window) else {
        return;
    };
    let ns_app = match appearance {
        WindowAppearance::System => None,
        // SAFETY: AppKit appearance name globals are valid static constants.
        WindowAppearance::Light => unsafe { NSAppearance::appearanceNamed(NSAppearanceNameAqua) },
        WindowAppearance::Dark => unsafe { NSAppearance::appearanceNamed(NSAppearanceNameDarkAqua) },
    };
    ns_win.setAppearance(ns_app.as_deref());
}

pub fn configure_macos_unified_window(window: &Window, fullsize_content: bool, vibrant: bool) {
    let (Some(ns_win), Some(winit_view)) = (macos_ns_window(window), macos_ns_view(window)) else {
        return;
    };
    if fullsize_content {
        ns_win.setStyleMask(ns_win.styleMask() | NSWindowStyleMask::FullSizeContentView);
        ns_win.setTitlebarAppearsTransparent(true);
        ns_win.setTitleVisibility(NSWindowTitleVisibility::Hidden);
        if let Some(mtm) = MainThreadMarker::new() {
            // Attach an empty unified NSToolbar so macOS Tahoe positions traffic lights at (20, 19)
            // cleanly inside the floating sidebar card instead of (7, 7) on the top border.
            let tb = NSToolbar::initWithIdentifier(mtm.alloc(), &NSString::from_str("RotaMainToolbar"));
            ns_win.setToolbar(Some(&tb));
            ns_win.setToolbarStyle(NSWindowToolbarStyle::Unified);
        }
    }
    if vibrant {
        winit_view.setWantsLayer(true);
        if let Some(mtm) = MainThreadMarker::new()
            && let Some(superview) = unsafe { winit_view.superview() }
        {
            let bounds = superview.bounds();
            let effect: Retained<NSVisualEffectView> =
                unsafe { msg_send![NSVisualEffectView::alloc(mtm), initWithFrame: bounds] };
            effect.setMaterial(NSVisualEffectMaterial::Sidebar);
            effect.setBlendingMode(NSVisualEffectBlendingMode::BehindWindow);
            effect.setState(NSVisualEffectState::FollowsWindowActiveState);
            effect.setAutoresizingMask(
                NSAutoresizingMaskOptions::ViewWidthSizable | NSAutoresizingMaskOptions::ViewHeightSizable,
            );
            superview.addSubview_positioned_relativeTo(
                &effect,
                NSWindowOrderingMode::Below,
                Some(&winit_view),
            );
        }
        sync_macos_window_vibrancy(window, !macos_reduce_transparency());
    }
}

pub fn ensure_metal_layer_non_opaque(window: &Window) {
    let vibrant = !macos_reduce_transparency();
    sync_macos_window_vibrancy(window, vibrant);
}

pub fn sync_macos_window_vibrancy(window: &Window, effective_vibrant: bool) {
    let (Some(ns_win), Some(winit_view)) = (macos_ns_window(window), macos_ns_view(window)) else {
        return;
    };
    if ns_win.isOpaque() == !effective_vibrant {
        return;
    }
    ns_win.setOpaque(!effective_vibrant);
    if effective_vibrant {
        ns_win.setBackgroundColor(Some(&NSColor::clearColor()));
    } else {
        ns_win.setBackgroundColor(Some(&NSColor::windowBackgroundColor()));
    }
    if let Some(layer) = winit_view.layer() {
        layer.setOpaque(!effective_vibrant);
    }
    if let Some(superview) = unsafe { winit_view.superview() } {
        let subs = superview.subviews();
        for idx in 0..subs.count() {
            let sub = subs.objectAtIndex(idx);
            if sub.isKindOfClass(<NSVisualEffectView as objc2::ClassType>::class()) {
                sub.setHidden(!effective_vibrant);
            }
        }
    }
}

pub fn activate_macos_window(window: &Window) {
    let Some(mtm) = MainThreadMarker::new() else {
        return;
    };
    let app = NSApplication::sharedApplication(mtm);
    #[allow(deprecated)]
    app.activateIgnoringOtherApps(true);
    if let Some(ns_win) = macos_ns_window(window) {
        ns_win.makeKeyAndOrderFront(None);
    }
}

pub fn macos_ns_view(window: &Window) -> Option<Retained<NSView>> {
    let RawWindowHandle::AppKit(appkit) = window.window_handle().ok()?.as_raw() else {
        return None;
    };
    // SAFETY: `ns_view` from `winit` on macOS is a valid main-thread `NSView`.
    let view_ref = unsafe { appkit.ns_view.cast::<NSView>().as_ref() };
    Some(view_ref.retain())
}

fn macos_ns_window(window: &Window) -> Option<Retained<NSWindow>> {
    macos_ns_view(window)?.window()
}
