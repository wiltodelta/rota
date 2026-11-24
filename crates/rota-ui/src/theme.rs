//! Rota design tokens: Daylight Instrument (Light) & Night Watch (Dark) themes and UI scales.

use crate::color::Color;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Appearance {
    Light,
    Dark,
}

impl Appearance {
    pub const fn name(self) -> &'static str {
        match self {
            Self::Light => "Daylight Instrument",
            Self::Dark => "Night Watch",
        }
    }
}

/// Adjustable interface (`0.8..=1.5`) and chat transcript (`0.7..=2.0`) typography scales.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UiScales {
    pub interface_scale: f32,
    pub chat_scale: f32,
}

impl Default for UiScales {
    fn default() -> Self {
        Self {
            interface_scale: 1.0,
            chat_scale: 1.0,
        }
    }
}

impl UiScales {
    pub const MIN_INTERFACE: f32 = 0.8;
    pub const MAX_INTERFACE: f32 = 1.5;
    pub const MIN_CHAT: f32 = 0.7;
    pub const MAX_CHAT: f32 = 2.0;

    #[inline]
    pub fn clamped(interface_scale: f32, chat_scale: f32) -> Self {
        Self {
            interface_scale: interface_scale.clamp(Self::MIN_INTERFACE, Self::MAX_INTERFACE),
            chat_scale: chat_scale.clamp(Self::MIN_CHAT, Self::MAX_CHAT),
        }
    }

    #[inline]
    pub fn ui(self, base_pt: f32) -> f32 {
        (base_pt * self.interface_scale * 2.0).round() * 0.5
    }

    #[inline]
    pub fn chat(self, base_pt: f32) -> f32 {
        (base_pt * self.chat_scale * self.interface_scale * 2.0).round() * 0.5
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Theme {
    pub appearance: Appearance,
    pub scales: UiScales,
    pub canvas: Color,
    pub surface: Color,
    pub elevated: Color,
    pub sidebar: Color,
    pub subtle_hover: Color,
    pub selected: Color,
    pub selection_fill: Color,
    pub selection_text: Color,
    pub border: Color,
    pub subtle_border: Color,
    pub control_track: Color,
    pub control_thumb_border: Color,
    pub text_primary: Color,
    pub text_secondary: Color,
    pub text_muted: Color,
    pub accent: Color,
    pub accent_hover: Color,
    pub accent_text: Color,
    pub success: Color,
    pub warning: Color,
    pub danger: Color,
    pub code_bg: Color,
    pub focus_ring: Color,
    pub shadow_color: Color,
    pub modal_scrim: Color,
    pub badge_claude: Color,
    pub badge_codex: Color,
    pub badge_grok: Color,
    pub badge_antigravity: Color,
    pub badge_shell: Color,
}

impl Theme {
    /// Daylight Instrument — Rota Light palette (Tahoe Floating Glass & Crisp Paper).
    pub const fn light() -> Self {
        Self {
            appearance: Appearance::Light,
            scales: UiScales {
                interface_scale: 1.0,
                chat_scale: 1.0,
            },
            canvas: Color::rgb_hex(0xF5F5F7),
            surface: Color::rgb_hex(0xFFFFFF),
            elevated: Color::rgb_hex(0xFFFFFF),
            sidebar: Color::rgb_hex(0xF6F6F8),
            subtle_hover: Color::rgb_hex(0xEBEBEF),
            selected: Color::rgb_hex(0xE8F0FE),
            selection_fill: Color::rgb_hex(0x0A6CFF),
            selection_text: Color::rgb_hex(0xFFFFFF),
            border: Color::rgb_hex(0x000000).with_alpha(0.10),
            subtle_border: Color::rgb_hex(0x000000).with_alpha(0.085),
            control_track: Color::rgb_hex(0x7B818E),
            control_thumb_border: Color::rgb_hex(0x6C727F),
            text_primary: Color::rgb_hex(0x14171F),
            text_secondary: Color::rgb_hex(0x4A5160),
            // Calibrated for >= 4.5:1 WCAG AA contrast across canvas, surface, and sidebar.
            text_muted: Color::rgb_hex(0x5B6373),
            accent: Color::rgb_hex(0x0B57D0),
            accent_hover: Color::rgb_hex(0x0846AD),
            accent_text: Color::rgb_hex(0xFFFFFF),
            success: Color::rgb_hex(0x137333),
            warning: Color::rgb_hex(0x995000),
            danger: Color::rgb_hex(0xC5221F),
            code_bg: Color::rgb_hex(0xF5F6F8),
            focus_ring: Color::rgb_hex(0x0A6CFF).with_alpha(0.35),
            shadow_color: Color::rgb_hex(0x0F172A).with_alpha(0.09),
            modal_scrim: Color::rgb_hex(0x0F172A).with_alpha(0.28),
            badge_claude: Color::rgb_hex(0xC65A2E),
            badge_codex: Color::rgb_hex(0x14171F),
            badge_grok: Color::rgb_hex(0x14171F),
            badge_antigravity: Color::rgb_hex(0x14171F),
            badge_shell: Color::rgb_hex(0x14171F),
        }
    }

    /// Night Watch — Rota Dark palette (Tahoe Neutral Graphite & Liquid Glass).
    pub const fn dark() -> Self {
        Self {
            appearance: Appearance::Dark,
            scales: UiScales {
                interface_scale: 1.0,
                chat_scale: 1.0,
            },
            canvas: Color::rgb_hex(0x19191B),
            surface: Color::rgb_hex(0x1E1E1E),
            elevated: Color::rgb_hex(0x2A2A2D),
            sidebar: Color::rgb_hex(0x252527),
            subtle_hover: Color::rgb_hex(0x333338),
            selected: Color::rgb_hex(0x22334D),
            selection_fill: Color::rgb_hex(0x147CE5),
            selection_text: Color::rgb_hex(0xFFFFFF),
            border: Color::rgb_hex(0xFFFFFF).with_alpha(0.12),
            subtle_border: Color::rgb_hex(0xFFFFFF).with_alpha(0.095),
            control_track: Color::rgb_hex(0x82848E),
            control_thumb_border: Color::rgb_hex(0x9496A0),
            text_primary: Color::rgb_hex(0xF2F2F5),
            text_secondary: Color::rgb_hex(0xB0B0B8),
            // Calibrated for >= 4.5:1 WCAG AA contrast across canvas, surface, and elevated.
            text_muted: Color::rgb_hex(0x9A9AA4),
            accent: Color::rgb_hex(0x5CA3FF),
            accent_hover: Color::rgb_hex(0x78B4FF),
            accent_text: Color::rgb_hex(0x080C14),
            success: Color::rgb_hex(0x4CD97B),
            warning: Color::rgb_hex(0xFFAE33),
            danger: Color::rgb_hex(0xFF7575),
            code_bg: Color::rgb_hex(0x171719),
            focus_ring: Color::rgb_hex(0x5CA3FF).with_alpha(0.45),
            shadow_color: Color::rgb_hex(0x000000).with_alpha(0.44),
            modal_scrim: Color::rgb_hex(0x000000).with_alpha(0.54),
            badge_claude: Color::rgb_hex(0xEB8358),
            badge_codex: Color::rgb_hex(0xF2F2F5),
            badge_grok: Color::rgb_hex(0xF2F2F5),
            badge_antigravity: Color::rgb_hex(0xF2F2F5),
            badge_shell: Color::rgb_hex(0xF2F2F5),
        }
    }

    #[inline]
    pub const fn for_appearance(appearance: Appearance) -> Self {
        match appearance {
            Appearance::Light => Self::light(),
            Appearance::Dark => Self::dark(),
        }
    }

    #[inline]
    pub fn with_scales(mut self, interface_scale: f32, chat_scale: f32) -> Self {
        self.scales = UiScales::clamped(interface_scale, chat_scale);
        self
    }

    #[inline]
    pub fn with_high_contrast(mut self, high_contrast: bool) -> Self {
        if high_contrast {
            match self.appearance {
                Appearance::Light => {
                    self.border = Color::rgb_hex(0x6D7380);
                    self.subtle_border = Color::rgb_hex(0x7B818E);
                    self.control_track = Color::rgb_hex(0x5E6472);
                }
                Appearance::Dark => {
                    self.border = Color::rgb_hex(0x8D8F99);
                    self.subtle_border = Color::rgb_hex(0x82848E);
                    self.control_track = Color::rgb_hex(0x9496A0);
                }
            }
        }
        self
    }

    #[inline]
    pub fn ui_px(&self, base_pt: f32) -> f32 {
        self.scales.ui(base_pt)
    }

    #[inline]
    pub fn chat_px(&self, base_pt: f32) -> f32 {
        self.scales.chat(base_pt)
    }

    #[inline]
    pub fn title_size(&self) -> f32 {
        self.ui_px(17.0)
    }

    #[inline]
    pub fn heading_size(&self) -> f32 {
        self.ui_px(14.0)
    }

    #[inline]
    pub fn body_size(&self) -> f32 {
        self.ui_px(13.0)
    }

    #[inline]
    pub fn caption_size(&self) -> f32 {
        self.ui_px(11.5)
    }

    #[inline]
    pub fn chat_body_size(&self) -> f32 {
        self.chat_px(14.0)
    }

    #[inline]
    pub fn chat_code_size(&self) -> f32 {
        self.chat_px(12.5)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::color::contrast_ratio;

    #[test]
    fn wcag_aa_contrast_holds_for_light_and_dark_themes() {
        for theme in [Theme::light(), Theme::dark()] {
            for bg in [theme.canvas, theme.surface, theme.elevated, theme.sidebar] {
                for (label, fg) in [
                    ("text_primary", theme.text_primary),
                    ("text_secondary", theme.text_secondary),
                    ("text_muted", theme.text_muted),
                    ("danger", theme.danger),
                    ("success", theme.success),
                    ("warning", theme.warning),
                    ("accent", theme.accent),
                ] {
                    let ratio = contrast_ratio(fg, bg);
                    assert!(
                        ratio >= 4.5,
                        "{:?} {label} contrast {ratio:.2}:1 < 4.5:1 on bg {:?}",
                        theme.appearance,
                        bg
                    );
                }
            }
            let button_ratio = contrast_ratio(theme.accent_text, theme.accent);
            assert!(
                button_ratio >= 4.5,
                "{:?} accent_text on accent {button_ratio:.2}:1 < 4.5:1",
                theme.appearance
            );
            for bg in [theme.canvas, theme.surface, theme.elevated] {
                for (label, fg) in [
                    ("control_track", theme.control_track),
                    ("control_thumb_border", theme.control_thumb_border),
                    ("hc_border", theme.with_high_contrast(true).border),
                ] {
                    let ratio = contrast_ratio(fg, bg);
                    assert!(
                        ratio >= 3.0,
                        "{:?} {label} non-text contrast {ratio:.2}:1 < 3.0:1 on bg {:?}",
                        theme.appearance,
                        bg
                    );
                }
            }
        }
    }

    #[test]
    fn scale_clamping_respects_bounds() {
        let t = Theme::dark().with_scales(0.3, 9.0);
        assert_eq!(t.scales.interface_scale, UiScales::MIN_INTERFACE);
        assert_eq!(t.scales.chat_scale, UiScales::MAX_CHAT);
    }
}
