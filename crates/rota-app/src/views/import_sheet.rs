//! `ImportSheet` modal (`id: "importSheet"`): subtitle, search icon, `importEmpty` state, and two-row footer (`ImportSheet.swift` parity).

use rota_core::import::RoutineImport;
use rota_core::schedule::ScheduleText;
use rota_ui::{A11yRole, A11ySpec, Edges, IconKind, Point, Size, Theme, UiElement};

use crate::actions::{AppAction, FocusTarget, MenuId};
use crate::app_state::AppState;
use crate::views::placeholders::build_import_empty_box;
use crate::views::widgets::{
    borderless_text_editor, button, hairline_h, interactive_scrollbar_overlay, label_1line,
    label_semibold_1line, label_wrapped, modal_card, popup_button_with_value, toggle_switch,
};

pub fn build_import_sheet_modal(
    state: &mut AppState,
    theme: &Theme,
    viewport: Size,
    now_seconds: f64,
) -> UiElement {
    let modal_w = (viewport.width - 48.0).clamp(480.0, 620.0);
    let modal_h = (viewport.height - 48.0).clamp(380.0, 520.0);
    let pad_x = theme.ui_px(20.0);
    let inner_w = (modal_w - pad_x * 2.0).max(240.0);

    let Some((scans_opt, chosen, search_ed, show_imported, target_harness, scroll_y)) =
        state.import_modal.as_ref().map(|m| {
            (
                m.scans.clone(),
                m.chosen.clone(),
                m.search_input.clone(),
                m.show_imported,
                m.target_harness,
                m.scroll.effective_scroll_y(),
            )
        })
    else {
        return UiElement::column();
    };

    let imported_count: usize = scans_opt.as_ref().map_or(0, |scans| {
        scans
            .iter()
            .flat_map(|s| &s.candidates)
            .filter(|c| RoutineImport::is_imported(c, &state.routines))
            .count()
    });

    let hov = state.hovered_id.clone();
    let ftr_h = theme.ui_px(82.0);
    let body_est_h = (modal_h - theme.ui_px(116.0) - ftr_h - 2.0).max(130.0);

    let f_search = state
        .actions
        .register(AppAction::FocusField(FocusTarget::ImportSearch));
    let search_focused = state.focus == Some(FocusTarget::ImportSearch);
    let search_w = if imported_count > 0 {
        (inner_w - theme.ui_px(176.0)).max(160.0)
    } else {
        inner_w
    };

    let search_bar = UiElement::row()
        .width(search_w)
        .min_height(theme.ui_px(34.0))
        .align_center()
        .gap(theme.ui_px(6.0))
        .padding(Edges::xy(theme.ui_px(10.0), theme.ui_px(5.0)))
        .rounded(theme.ui_px(8.0))
        .bg(theme.elevated)
        .border(
            if search_focused { 1.5 } else { 1.0 },
            if search_focused {
                theme.selection_fill
            } else {
                theme.border
            },
        )
        .clip()
        .child(UiElement::icon(
            IconKind::Search,
            theme.ui_px(13.0),
            theme.text_muted,
        ))
        .child(borderless_text_editor(
            theme,
            "importSearch",
            "Search routines",
            "Search Claude Desktop or Codex routines…",
            &search_ed,
            search_focused,
            false,
            (search_w - theme.ui_px(38.0)).max(80.0),
            theme.ui_px(28.0),
            f_search,
        ));

    let mut search_row = UiElement::row()
        .width(inner_w)
        .align_center()
        .justify_between()
        .gap(theme.ui_px(10.0))
        .child(search_bar);
    if imported_count > 0 {
        let toggle_imp = state
            .actions
            .register_named("showImported", AppAction::ImportToggleShowImported);
        search_row = search_row.child(toggle_switch(
            theme,
            "showImported",
            &format!("Show imported ({imported_count})"),
            show_imported,
            true,
            toggle_imp,
        ));
    }

    let header = UiElement::column()
        .width(modal_w)
        .padding(Edges::xy(pad_x, theme.ui_px(12.0)))
        .gap(theme.ui_px(6.0))
        .flex_shrink(0.0)
        .clip()
        .child(label_semibold_1line(
            "Import Routines",
            theme.title_size(),
            theme.text_primary,
            inner_w,
        ))
        .child(label_1line(
            "Choose routines to copy into Rota. They start paused.",
            theme.caption_size(),
            theme.text_secondary,
            inner_w,
        ))
        .child(search_row);

    let query = search_ed.text().trim().to_ascii_lowercase();
    let mut body_col = UiElement::column()
        .width(modal_w)
        .padding(Edges::xy(pad_x, theme.ui_px(12.0)))
        .gap(theme.ui_px(12.0));

    let mut row_count = 0usize;
    let mut active_source_selected = 0usize;

    match scans_opt {
        None => {
            body_col = body_col.child(label_1line(
                "Scanning Claude Desktop and Codex…",
                theme.body_size(),
                theme.text_muted,
                inner_w,
            ));
        }
        Some(scans) => {
            let mut any_visible_or_problem = false;
            for (src_idx, scan) in scans.iter().enumerate() {
                let visible_cands: Vec<_> = scan
                    .candidates
                    .iter()
                    .filter(|c| {
                        let already = RoutineImport::is_imported(c, &state.routines);
                        (show_imported || !already)
                            && (query.is_empty()
                                || c.routine.name.to_ascii_lowercase().contains(&query)
                                || c.routine.working_directory.to_ascii_lowercase().contains(&query))
                    })
                    .collect();

                for c in &scan.candidates {
                    if chosen.contains(&c.id()) && c.routine.enabled {
                        active_source_selected += 1;
                    }
                }

                if visible_cands.is_empty() && scan.problem.is_none() {
                    continue;
                }
                any_visible_or_problem = true;

                let mut src_hdr = UiElement::row()
                    .width(inner_w)
                    .align_center()
                    .justify_between()
                    .child(label_semibold_1line(
                        format!("{} ({})", scan.source.title(), visible_cands.len()),
                        theme.body_size(),
                        theme.text_primary,
                        inner_w - 110.0,
                    ));
                if !visible_cands.is_empty() {
                    let sel_all_id = format!("importSelect-{}", scan.source.as_str());
                    let sel_all_hov = hov.as_deref() == Some(sel_all_id.as_str());
                    let sel_all_act = state
                        .actions
                        .register_named(&sel_all_id, AppAction::ImportSelectAllSource(src_idx));
                    src_hdr = src_hdr.child(button(
                        theme,
                        sel_all_id,
                        "Select All",
                        None,
                        sel_all_act,
                        false,
                        false,
                        true,
                        sel_all_hov,
                    ));
                }
                body_col = body_col.child(src_hdr);

                if let Some(prob) = &scan.problem
                    && visible_cands.is_empty()
                {
                    body_col =
                        body_col.child(label_1line(prob, theme.caption_size(), theme.text_muted, inner_w));
                }

                for cand in visible_cands {
                    row_count += 1;
                    let cid = cand.id();
                    let in_rota = RoutineImport::is_imported(cand, &state.routines);
                    let is_sel = in_rota || chosen.contains(&cid);
                    let can_pick = !in_rota && cand.unsupported.is_none();
                    let choice_id = format!("importChoice-{cid}");
                    let toggle_c = state
                        .actions
                        .register_named(&choice_id, AppAction::ImportToggleCandidate(cid.clone()));
                    let sched = ScheduleText::describe(&cand.routine.schedule)
                        .unwrap_or_else(|| cand.routine.schedule.clone());
                    let detail = format!("{} · {sched}", cand.routine.working_directory);

                    let mut cand_col = UiElement::column()
                        .width(inner_w - theme.ui_px(44.0))
                        .gap(2.0)
                        .clip()
                        .child(label_semibold_1line(
                            &cand.routine.name,
                            theme.body_size(),
                            if can_pick {
                                theme.text_primary
                            } else {
                                theme.text_muted
                            },
                            inner_w - 48.0,
                        ))
                        .child(label_1line(
                            &detail,
                            theme.caption_size(),
                            theme.text_secondary,
                            inner_w - 48.0,
                        ));
                    if let Some(unsup) = &cand.unsupported {
                        cand_col = cand_col.child(label_wrapped(
                            unsup,
                            theme.caption_size(),
                            theme.danger,
                            inner_w - 48.0,
                            Some(2),
                        ));
                    }

                    let choice_hov = hov.as_deref() == Some(choice_id.as_str());
                    let mut row = UiElement::row()
                        .id(choice_id)
                        .width(inner_w)
                        .align_center()
                        .gap(theme.ui_px(10.0))
                        .padding(Edges::xy(theme.ui_px(10.0), theme.ui_px(8.0)))
                        .rounded(theme.ui_px(8.0))
                        .bg(if is_sel && can_pick {
                            theme.selected
                        } else if choice_hov && can_pick {
                            theme.subtle_hover
                        } else {
                            theme.elevated
                        })
                        .border(1.0, theme.border)
                        .clip()
                        .a11y(A11ySpec {
                            role: A11yRole::CheckBox,
                            title: cand.routine.name.clone(),
                            value: Some(if is_sel { "1" } else { "0" }.to_string()),
                            selected: is_sel,
                            enabled: can_pick,
                            focused: false,
                        })
                        .child(
                            UiElement::row()
                                .width(theme.ui_px(16.0))
                                .height(theme.ui_px(16.0))
                                .align_center()
                                .justify_center()
                                .rounded(4.0)
                                .bg(if is_sel {
                                    theme.selection_fill
                                } else {
                                    theme.surface
                                })
                                .border(
                                    1.0,
                                    if is_sel {
                                        theme.selection_fill
                                    } else {
                                        theme.control_track
                                    },
                                )
                                .flex_shrink(0.0)
                                .child(if is_sel {
                                    UiElement::icon(IconKind::Check, theme.ui_px(11.0), rota_ui::Color::WHITE)
                                } else {
                                    UiElement::row()
                                }),
                        )
                        .child(cand_col);
                    if can_pick {
                        row = row.on_click(toggle_c);
                    }
                    body_col = body_col.child(row);
                }
            }

            if !any_visible_or_problem {
                body_col = body_col.child(build_import_empty_box(theme, inner_w, &query, imported_count));
            }
        }
    }

    let total_h = if let Some(m) = &mut state.import_modal {
        if m.scroll.item_count() == 0 {
            m.scroll
                .set_heights(&[140.0 + (row_count as f32) * 64.0], body_est_h);
        }
        m.scroll.total_height()
    } else {
        body_est_h
    };

    let open_target = state
        .actions
        .register_named("importAgent", AppAction::OpenMenu(MenuId::ImportAgent));
    let cancel_act = state.actions.register_named("Cancel", AppAction::CloseModal);
    let confirm_act = state
        .actions
        .register_named("confirmImport", AppAction::ConfirmImportSelected);
    let target_label = target_harness.map_or("Original agent", |h| h.title());
    let sel_count_lbl = format!("{} selected", chosen.len());
    let import_btn_label = if chosen.is_empty() {
        "Import".to_string()
    } else {
        format!("Import {}", chosen.len())
    };
    let (notice_txt, notice_col) = if active_source_selected > 0 {
        (
            format!("Still active in source: {active_source_selected}. Pause there before enabling in Rota."),
            theme.warning,
        )
    } else {
        ("Source apps stay unchanged.".to_string(), theme.text_muted)
    };

    // Authentic two-row footer (`ImportSheet.swift:130-163`)
    let footer = UiElement::column()
        .width(modal_w)
        .height(ftr_h)
        .justify_between()
        .padding(Edges::xy(pad_x, theme.ui_px(10.0)))
        .flex_shrink(0.0)
        .clip()
        .child(
            UiElement::row()
                .width(inner_w)
                .align_center()
                .justify_between()
                .child(
                    UiElement::row()
                        .align_center()
                        .gap(theme.ui_px(8.0))
                        .child(label_1line(
                            "Agent",
                            theme.body_size(),
                            theme.text_secondary,
                            52.0,
                        ))
                        .child(popup_button_with_value(
                            theme,
                            "importAgent",
                            target_label,
                            target_label,
                            None,
                            open_target,
                            row_count > 0,
                            hov.as_deref() == Some("importAgent"),
                        )),
                )
                .child(
                    label_1line(&sel_count_lbl, theme.caption_size(), theme.text_secondary, 100.0)
                        .id("importSelectionCount"),
                ),
        )
        .child(
            UiElement::row()
                .width(inner_w)
                .align_center()
                .justify_between()
                .child(
                    label_1line(&notice_txt, theme.caption_size(), notice_col, inner_w - 190.0)
                        .id("importNotice"),
                )
                .child(
                    UiElement::row()
                        .align_center()
                        .gap(theme.ui_px(8.0))
                        .child(button(
                            theme,
                            "Cancel",
                            "Cancel",
                            None,
                            cancel_act,
                            false,
                            false,
                            true,
                            hov.as_deref() == Some("Cancel"),
                        ))
                        .child(button(
                            theme,
                            "confirmImport",
                            &import_btn_label,
                            Some(IconKind::Import),
                            confirm_act,
                            true,
                            false,
                            !chosen.is_empty(),
                            hov.as_deref() == Some("confirmImport"),
                        )),
                ),
        );

    let sb_active = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == "import")
        || hov.as_deref() == Some("scrollbarThumb-import");
    let sb_opt = state
        .import_modal
        .as_ref()
        .map(|m| m.scroll.clone())
        .and_then(|sc| {
            interactive_scrollbar_overlay(
                theme,
                "import",
                &sc,
                body_est_h,
                total_h,
                modal_w - 1.0,
                sb_active,
                now_seconds,
                &mut state.activity_clock,
            )
        });
    let mut results_box = UiElement::column()
        .id("importResults")
        .width(modal_w)
        .flex_grow(1.0)
        .bg(theme.canvas)
        .clip()
        .scroll_offset(Point::new(0.0, scroll_y))
        .a11y(A11ySpec::new(A11yRole::ScrollArea, "Import Candidates"))
        .child(body_col.id("importSheetContent"));
    if let Some(sb) = sb_opt {
        results_box = results_box.child(sb);
    }

    modal_card(theme, "importSheet", "Import Routines", modal_w, modal_h)
        .child(header)
        .child(hairline_h(theme))
        .child(results_box)
        .child(hairline_h(theme))
        .child(footer)
}
