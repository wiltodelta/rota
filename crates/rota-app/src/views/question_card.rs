//! Interactive `QuestionCard` (`id: "questionCard"`): calm Tahoe elevated card, clean borderless selectable rows, `Cmd+1..9` numbers, and pill actions.

use rota_core::model::{AgentQuestion, QuestionDraft, QuestionField, QuestionFieldKind, QuestionOption};
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontWeight, IconKind, ReturnBehavior, TextEditState, TextLayoutOpts,
    TextSpan, Theme, UiElement,
};
use uuid::Uuid;

use crate::actions::{AppAction, FocusTarget};
use crate::app_state::AppState;
use crate::views::widgets::{
    button, label_1line, label_semibold_1line, label_wrapped, mono_text, text_field_box,
};

pub fn build_question_card(
    state: &mut AppState,
    theme: &Theme,
    session_id: Uuid,
    question: &AgentQuestion,
    width: f32,
) -> UiElement {
    let (draft, ctx_expanded) = {
        let tr = state.transcripts.entry(session_id).or_default();
        let d = tr
            .question_drafts
            .entry(question.id.clone())
            .or_insert_with(|| QuestionDraft::new(question.clone()))
            .clone();
        (d, tr.question_context_expanded)
    };

    let pad = theme.ui_px(18.0);
    let inner_w = (width - pad * 2.0).max(160.0);

    let mut hdr = UiElement::row()
        .width(inner_w)
        .align_center()
        .justify_between()
        .clip()
        .child(
            label_1line(
                &question.title,
                theme.caption_size(),
                theme.text_secondary,
                inner_w - 84.0,
            )
            .id("questionTitle")
            .a11y(A11ySpec::new(A11yRole::Heading, &question.title)),
        );

    if question.fields.len() > 1 {
        let prog = format!("{} of {}", draft.field_index() + 1, question.fields.len());
        hdr = hdr.child(
            label_1line(&prog, theme.caption_size(), theme.text_muted, 76.0)
                .id("questionProgress")
                .a11y(A11ySpec::new(A11yRole::StaticText, prog)),
        );
    }

    let mut card = UiElement::column()
        .id("questionCard")
        .width(width)
        .padding(Edges::all(pad))
        .gap(theme.ui_px(12.0))
        .rounded(theme.ui_px(12.0))
        .bg(theme.text_primary.with_alpha(0.03))
        .border(1.0, theme.border)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, &question.title))
        .child(hdr);

    if !question.detail.is_empty() {
        card = card.child(label_wrapped(
            &question.detail,
            theme.body_size(),
            theme.text_secondary,
            inner_w,
            Some(4),
        ));
    }

    if let Some(ctx) = &question.context
        && !ctx.is_empty()
    {
        let toggle_ctx = state
            .actions
            .register(AppAction::ToggleQuestionContext(session_id));
        let ctx_hov = state.is_hovered("questionContext");
        let mut ctx_spec = A11ySpec::new(A11yRole::Button, "Tool details");
        ctx_spec.selected = ctx_expanded;
        ctx_spec.value = Some(if ctx_expanded { "Expanded" } else { "Collapsed" }.to_string());
        card = card.child(
            UiElement::row()
                .id("questionContext")
                .min_height(theme.ui_px(24.0))
                .align_center()
                .gap(theme.ui_px(5.0))
                .padding(Edges::xy(theme.ui_px(6.0), theme.ui_px(3.0)))
                .rounded(theme.ui_px(6.0))
                .bg(if ctx_hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(toggle_ctx)
                .a11y(ctx_spec)
                .child(UiElement::icon(
                    if ctx_expanded {
                        IconKind::ChevronDown
                    } else {
                        IconKind::ChevronRight
                    },
                    theme.ui_px(11.5),
                    theme.text_muted,
                ))
                .child(label_1line(
                    "Tool details",
                    theme.caption_size(),
                    theme.text_secondary,
                    160.0,
                )),
        );
        if ctx_expanded {
            card = card.child(
                UiElement::column()
                    .id("questionContextText")
                    .width(inner_w)
                    .padding(Edges::all(theme.ui_px(10.0)))
                    .rounded(theme.ui_px(8.0))
                    .bg(theme.code_bg)
                    .border(1.0, theme.subtle_border)
                    .clip()
                    .child(mono_text(
                        ctx,
                        theme.caption_size(),
                        theme.text_secondary,
                        inner_w - 20.0,
                        Some(8),
                    )),
            );
        }
    }

    if let Some(url) = &question.url
        && (url.starts_with("https://") || url.starts_with("http://"))
    {
        let open_act = state.actions.register(AppAction::OpenUrlOrPath(url.clone()));
        let url_hov = state.is_hovered("questionOpenUrl");
        card = card.child(button(
            theme,
            "questionOpenUrl",
            "Open in Browser",
            Some(IconKind::ExternalLink),
            open_act,
            false,
            false,
            true,
            url_hov,
        ));
    }

    if let Some(field) = draft.current_field() {
        card = card.child(build_question_field(
            state,
            theme,
            session_id,
            &question.id,
            &draft,
            field,
            inner_w,
        ));
    }

    if let Some(err) = &draft.failure {
        card = card.child(
            label_wrapped(err, theme.caption_size(), theme.danger, inner_w, Some(2))
                .id("questionError")
                .a11y(A11ySpec::new(A11yRole::StaticText, err)),
        );
    }

    card.child(build_question_actions(state, theme, question, &draft, inner_w))
}

fn build_question_field(
    state: &mut AppState,
    theme: &Theme,
    session_id: Uuid,
    question_id: &str,
    draft: &QuestionDraft,
    field: &QuestionField,
    width: f32,
) -> UiElement {
    let heading = if field.required {
        field.title.clone()
    } else {
        format!("{} (optional)", field.title)
    };
    let mut col = UiElement::column()
        .width(width)
        .gap(theme.ui_px(4.0))
        .clip()
        .child(
            UiElement::row()
                .width(width)
                .padding(Edges::new(0.0, 0.0, theme.ui_px(4.0), 0.0))
                .child(label_semibold_1line(
                    &heading,
                    theme.heading_size(),
                    theme.text_primary,
                    width,
                )),
        );

    if !field.detail.is_empty() {
        col = col.child(label_wrapped(
            &field.detail,
            theme.caption_size(),
            theme.text_secondary,
            width,
            Some(3),
        ));
    }

    let options: Vec<QuestionOption> = if field.kind == QuestionFieldKind::Boolean {
        vec![
            QuestionOption::new("true", "Yes"),
            QuestionOption::new("false", "No"),
        ]
    } else {
        field.options.clone()
    };

    let is_multi = field.kind == QuestionFieldKind::Multiple;
    for (idx, opt) in options.iter().enumerate() {
        let selected = draft.values.get(&field.id).is_some_and(|v| v.contains(&opt.id));
        let opt_el_id = format!("questionOption-{}-{}", field.id, opt.id);
        let act = state.actions.register_named(
            &opt_el_id,
            AppAction::SelectQuestionOption {
                field_id: field.id.clone(),
                option_id: opt.id.clone(),
            },
        );
        col = col.child(build_option_row(
            theme,
            &opt_el_id,
            idx + 1,
            &opt.label,
            &opt.detail,
            selected,
            is_multi,
            act,
            state.hovered_id.as_deref() == Some(opt_el_id.as_str()),
            width,
        ));
    }

    if !options.is_empty() && field.allows_other && field.kind != QuestionFieldKind::Boolean {
        let other_sel = draft.custom_fields.contains(&field.id);
        let other_id = format!("questionOther-{}", field.id);
        let other_preview = draft.other.get(&field.id).map_or("", String::as_str).trim();
        let act = state.actions.register_named(
            &other_id,
            AppAction::SelectQuestionOther {
                field_id: field.id.clone(),
            },
        );
        col = col.child(build_option_row(
            theme,
            &other_id,
            options.len() + 1,
            "Something else…",
            if other_sel { other_preview } else { "" },
            other_sel,
            is_multi,
            act,
            state.hovered_id.as_deref() == Some(other_id.as_str()),
            width,
        ));
    }

    if (options.is_empty() && field.kind != QuestionFieldKind::Boolean)
        || draft.custom_fields.contains(&field.id)
    {
        let cur_val = draft.other.get(&field.id).cloned().unwrap_or_default();
        let ed = state
            .transcripts
            .entry(session_id)
            .or_default()
            .question_editors
            .entry((question_id.to_string(), field.id.clone()))
            .or_insert_with(|| TextEditState::multi_line(cur_val, ReturnBehavior::InsertNewline))
            .clone();
        let focused = state.focus == Some(FocusTarget::QuestionField(field.id.clone()));
        let focus_act = state
            .actions
            .register(AppAction::FocusField(FocusTarget::QuestionField(
                field.id.clone(),
            )));
        col = col.child(text_field_box(
            theme,
            format!("questionField-{}", field.id),
            &field.title,
            "Your answer…",
            &ed,
            focused,
            false,
            width,
            theme.ui_px(36.0),
            focus_act,
        ));
    }

    col
}

#[allow(clippy::too_many_arguments)]
fn build_option_row(
    theme: &Theme,
    id: &str,
    number: usize,
    label: &str,
    detail: &str,
    selected: bool,
    is_multi: bool,
    action: rota_ui::UiActionId,
    hovered: bool,
    width: f32,
) -> UiElement {
    let bg = if selected {
        theme.subtle_hover
    } else if hovered {
        theme.text_primary.with_alpha(0.04)
    } else {
        Color::TRANSPARENT
    };
    let text_w = (width - theme.ui_px(64.0)).max(60.0);

    let trailing = UiElement::row()
        .width(theme.ui_px(18.0))
        .height(theme.ui_px(18.0))
        .align_center()
        .padding(Edges::all(2.0))
        .flex_shrink(0.0)
        .child(if selected {
            UiElement::icon(IconKind::Check, theme.ui_px(13.5), theme.text_primary)
        } else if is_multi {
            UiElement::icon(IconKind::Square, theme.ui_px(13.5), theme.text_muted)
        } else {
            UiElement::row()
        });

    let weight = if selected {
        FontWeight::Medium
    } else {
        FontWeight::Regular
    };
    let mut text_col = UiElement::column()
        .width(text_w)
        .gap(theme.ui_px(2.0))
        .clip()
        .child(UiElement::text(
            vec![TextSpan::new(label, theme.body_size(), theme.text_primary).weight(weight)],
            TextLayoutOpts {
                max_width: Some(text_w),
                max_lines: Some(2),
                ..Default::default()
            },
        ));
    if !detail.is_empty() {
        text_col = text_col.child(label_wrapped(
            detail,
            theme.caption_size(),
            theme.text_secondary,
            text_w,
            Some(2),
        ));
    }

    let mut spec = A11ySpec::new(A11yRole::Button, label);
    spec.selected = selected;
    spec.value = Some(if selected { "Selected" } else { "Not selected" }.to_string());

    UiElement::row()
        .id(id.to_string())
        .width(width)
        .align_center()
        .gap(theme.ui_px(10.0))
        .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(9.0)))
        .rounded(theme.ui_px(9.0))
        .bg(bg)
        .clip()
        .on_click(action)
        .a11y(spec)
        .child(
            UiElement::text(
                vec![
                    TextSpan::new(format!("{number}"), theme.body_size(), theme.text_secondary)
                        .weight(FontWeight::Medium),
                ],
                TextLayoutOpts {
                    max_width: Some(theme.ui_px(18.0)),
                    max_lines: Some(1),
                    ..Default::default()
                },
            )
            .width(theme.ui_px(16.0))
            .flex_shrink(0.0),
        )
        .child(text_col)
        .child(trailing)
}

fn build_question_actions(
    state: &mut AppState,
    theme: &Theme,
    question: &AgentQuestion,
    draft: &QuestionDraft,
    width: f32,
) -> UiElement {
    let hov = state.hovered_id.clone();
    let mk = |id: &str, lbl: &str, act, primary: bool, enabled: bool| {
        button(
            theme,
            id,
            lbl,
            None,
            act,
            primary,
            false,
            enabled,
            hov.as_deref() == Some(id),
        )
    };
    let mut left = UiElement::row().align_center().gap(theme.ui_px(8.0));
    if draft.field_index() > 0 {
        let prev_act = state.actions.register(AppAction::QuestionPrev);
        left = left.child(mk("previousQuestion", "Back", prev_act, false, true));
    }
    let cancel_act = state
        .actions
        .register(AppAction::QuestionSubmit("cancel".to_string()));
    left = left.child(mk("cancelQuestion", "Cancel", cancel_act, false, true));
    if question.allows_decline == Some(true) {
        let dec_act = state
            .actions
            .register(AppAction::QuestionSubmit("decline".to_string()));
        left = left.child(mk("declineQuestion", "Decline", dec_act, false, true));
    }

    let mut right = UiElement::row().align_center().gap(theme.ui_px(8.0));
    if !draft.is_last_field() {
        let next_act = state.actions.register(AppAction::QuestionNext);
        right = right.child(mk("nextQuestion", "Next", next_act, true, draft.can_advance()));
    } else {
        for (idx, act_opt) in question.actions.iter().enumerate() {
            let btn_id = format!("answerQuestion-{}", act_opt.id);
            let submit_act = state
                .actions
                .register_named(&btn_id, AppAction::QuestionSubmit(act_opt.id.clone()));
            right = right.child(button(
                theme,
                btn_id.clone(),
                &act_opt.label,
                None,
                submit_act,
                idx == 0,
                false,
                draft.can_submit(&act_opt.id),
                hov.as_deref() == Some(btn_id.as_str()),
            ));
        }
    }

    UiElement::row()
        .width(width)
        .align_center()
        .justify_between()
        .padding(Edges::new(theme.ui_px(4.0), 0.0, 0.0, 0.0))
        .clip()
        .child(left)
        .child(right)
}
