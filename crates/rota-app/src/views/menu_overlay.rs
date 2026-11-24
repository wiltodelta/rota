//! Tahoe Liquid Glass `AXMenu` / `AXMenuItem` dropdown popover renderer (`menu_items` builds entries).

use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontWeight, IconKind, Point, Rect, Size, TextLayoutOpts, TextSpan,
    Theme, UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::settings_store::SettingsStore;
use crate::views::menu_items::entries_for_menu;
use crate::views::widgets::hairline_h;
use rota_core::model::Harness;

pub struct MenuEntry {
    pub id: String,
    pub title: String,
    pub checked: bool,
    pub enabled: bool,
    pub icon: Option<(IconKind, Color)>,
    pub action: Option<AppAction>,
    pub is_separator: bool,
}

impl MenuEntry {
    pub fn item(
        id: impl Into<String>,
        title: impl Into<String>,
        checked: bool,
        enabled: bool,
        action: AppAction,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            checked,
            enabled,
            icon: None,
            action: Some(action),
            is_separator: false,
        }
    }

    pub fn with_icon(mut self, icon: IconKind, color: Color) -> Self {
        self.icon = Some((icon, color));
        self
    }

    pub fn sep() -> Self {
        Self {
            id: String::new(),
            title: String::new(),
            checked: false,
            enabled: false,
            icon: None,
            action: None,
            is_separator: true,
        }
    }
}

pub fn default_model_label(settings: &SettingsStore, harness: Harness) -> String {
    settings
        .models
        .get(&harness)
        .and_then(|opts| opts.iter().find(|o| o.is_default).or_else(|| opts.first()))
        .map_or_else(|| "Default".to_string(), |o| format!("Default ({})", o.title))
}

pub fn model_efforts_for(
    settings: &SettingsStore,
    harness: Harness,
    model: Option<&str>,
) -> (bool, Vec<String>) {
    let Some(opts) = settings.models.get(&harness) else {
        return (
            false,
            vec![
                "low".to_string(),
                "medium".to_string(),
                "high".to_string(),
                "xhigh".to_string(),
            ],
        );
    };
    if opts.is_empty() {
        return (
            false,
            vec![
                "low".to_string(),
                "medium".to_string(),
                "high".to_string(),
                "xhigh".to_string(),
            ],
        );
    }
    let sel = opts
        .iter()
        .find(|o| o.matches(model))
        .or_else(|| opts.iter().find(|o| o.is_default))
        .or_else(|| opts.first());
    let efforts = sel.map(|o| o.efforts.clone()).unwrap_or_default();
    (efforts.is_empty(), efforts)
}

pub fn build_open_menu(state: &mut AppState, theme: &Theme, viewport: Size) -> Option<UiElement> {
    let (menu_id, anchor) = state.open_menu.clone()?;
    let entries = entries_for_menu(state, theme, &menu_id);
    if entries.is_empty() {
        return None;
    }

    let max_chars = entries
        .iter()
        .filter(|e| !e.is_separator)
        .map(|e| e.title.chars().count())
        .max()
        .unwrap_or(14) as f32;
    let menu_w = (max_chars * theme.ui_px(7.4) + theme.ui_px(64.0))
        .max(anchor.width)
        .clamp(theme.ui_px(184.0), theme.ui_px(320.0));

    let item_h = theme.ui_px(28.0);
    let est_h = entries
        .iter()
        .map(|e| if e.is_separator { 9.0 } else { item_h + 2.0 })
        .sum::<f32>()
        + theme.ui_px(12.0);
    let menu_h = est_h.min(viewport.height - 24.0);

    let x = anchor.x.clamp(8.0, (viewport.width - menu_w - 8.0).max(8.0));
    let below_y = anchor.max_y() + 4.0;
    let y = if below_y + menu_h <= viewport.height - 8.0 {
        below_y
    } else {
        (anchor.y - menu_h - 4.0).max(8.0)
    };

    let mut card = UiElement::column()
        .id("activeDropdownMenu")
        .absolute(Rect::new(x, y, menu_w, menu_h))
        .padding(Edges::all(theme.ui_px(5.0)))
        .gap(theme.ui_px(1.5))
        .rounded(theme.ui_px(11.0))
        .bg(theme.elevated)
        .border(1.0, theme.border)
        .shadow(18.0, Point::new(0.0, 6.0), theme.shadow_color)
        .z_layer(20, true)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Menu, "Menu"));

    let row_w = (menu_w - theme.ui_px(10.0)).max(80.0);
    let hov = state.hovered_id.clone();

    for (idx, entry) in entries.into_iter().enumerate() {
        if entry.is_separator {
            card = card.child(
                UiElement::row()
                    .width(row_w)
                    .padding(Edges::xy(theme.ui_px(6.0), theme.ui_px(3.5)))
                    .child(hairline_h(theme)),
            );
            continue;
        }
        let el_id = if entry.id.is_empty() {
            format!("menuItem-{idx}")
        } else {
            entry.id
        };
        let is_hov = entry.enabled && hov.as_deref() == Some(el_id.as_str());
        let bg = if is_hov {
            theme.selection_fill
        } else {
            Color::TRANSPARENT
        };
        let fg = if !entry.enabled {
            theme.text_muted
        } else if is_hov {
            Color::WHITE
        } else {
            theme.text_primary
        };

        let mut spec = A11ySpec::new(A11yRole::MenuItem, &entry.title);
        spec.selected = entry.checked;
        spec.enabled = entry.enabled;

        let check_slot = UiElement::row()
            .width(theme.ui_px(15.0))
            .height(theme.ui_px(15.0))
            .align_center()
            .justify_center()
            .flex_shrink(0.0)
            .child(if entry.checked {
                UiElement::icon(IconKind::Check, theme.ui_px(11.5), fg)
            } else {
                UiElement::row()
            });

        let mut item_row = UiElement::row()
            .id(el_id.clone())
            .width(row_w)
            .height(item_h)
            .align_center()
            .gap(theme.ui_px(6.0))
            .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(3.0)))
            .rounded(theme.ui_px(6.5))
            .bg(bg)
            .clip()
            .a11y(spec)
            .child(check_slot);

        if let Some((ic, ic_col)) = entry.icon {
            item_row = item_row.child(UiElement::icon(
                ic,
                theme.ui_px(13.5),
                if is_hov { Color::WHITE } else { ic_col },
            ));
        }
        item_row = item_row.child(UiElement::text(
            vec![TextSpan::new(&entry.title, theme.body_size(), fg).weight(FontWeight::Regular)],
            TextLayoutOpts {
                max_width: Some((row_w - theme.ui_px(44.0)).max(40.0)),
                max_lines: Some(1),
                ..Default::default()
            },
        ));
        if entry.enabled
            && let Some(act) = entry.action
        {
            let act_id = state.actions.register_named(&el_id, act);
            item_row = item_row.on_click(act_id);
        }
        card = card.child(item_row);
    }

    Some(card)
}
