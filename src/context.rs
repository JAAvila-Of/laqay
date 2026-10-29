//! Conservative selection of a focused filesystem view for diagnostics.
//! A successful selection does not authorize interception of a later key event.

#[derive(Clone, Copy, Debug)]
pub struct ViewEvidence {
    pub contains_focus: bool,
    pub filesystem: bool,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct ContextEvidence {
    pub foreground_stable: bool,
    pub native_focus_stable: bool,
    pub semantic_focus_stable: bool,
    pub folder_items_focused: bool,
    pub unresolved_entries: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[cfg(any(windows, test))]
pub(crate) enum FocusRole {
    Text,
    List,
    ListItem,
    DataGrid,
    DataItem,
    Pane,
    Group,
    Other,
}

#[derive(Clone, Copy, Debug)]
#[cfg(any(windows, test))]
pub(crate) struct FocusNode {
    pub role: FocusRole,
    pub value_pattern: bool,
}

/// Allow static text only along a bounded, non-editable path to the exact
/// native folder-list element. A list elsewhere in the UI tree is insufficient.
#[cfg(any(windows, test))]
pub(crate) fn static_text_in_folder_list(path: &[FocusNode], native_root_reached: bool) -> bool {
    native_root_reached
        && (2..=32).contains(&path.len())
        && path[0].role == FocusRole::Text
        && matches!(
            path[path.len() - 1].role,
            FocusRole::List | FocusRole::DataGrid
        )
        && path
            .iter()
            .all(|node| !node.value_pattern && node.role != FocusRole::Other)
}

/// Select exactly one focused filesystem view, rejecting uncertainty.
pub fn select_focused_view(views: &[ViewEvidence], context: ContextEvidence) -> Option<usize> {
    if !context.foreground_stable
        || !context.native_focus_stable
        || !context.semantic_focus_stable
        || !context.folder_items_focused
        || context.unresolved_entries != 0
    {
        return None;
    }
    let mut focused = views
        .iter()
        .enumerate()
        .filter(|(_, view)| view.contains_focus);
    let (index, view) = focused.next()?;
    if !view.filesystem || focused.next().is_some() {
        return None;
    }
    Some(index)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(role: FocusRole) -> FocusNode {
        FocusNode {
            role,
            value_pattern: false,
        }
    }

    #[test]
    fn accepts_static_folder_text_only_under_the_native_list() {
        for root in [FocusRole::List, FocusRole::DataGrid] {
            assert!(static_text_in_folder_list(
                &[node(FocusRole::Text), node(root)],
                true
            ));
            for item in [FocusRole::ListItem, FocusRole::DataItem] {
                assert!(static_text_in_folder_list(
                    &[
                        node(FocusRole::Text),
                        node(FocusRole::Group),
                        node(item),
                        node(root)
                    ],
                    true
                ));
            }
            assert!(!static_text_in_folder_list(
                &[node(FocusRole::Text), node(root)],
                false
            ));
        }
    }

    #[test]
    fn rejects_editors_unknown_ancestry_and_value_patterns() {
        for path in [
            vec![node(FocusRole::Other), node(FocusRole::List)],
            vec![
                node(FocusRole::Text),
                node(FocusRole::Other),
                node(FocusRole::List),
            ],
            vec![
                FocusNode {
                    role: FocusRole::Text,
                    value_pattern: true,
                },
                node(FocusRole::List),
            ],
            vec![
                node(FocusRole::Text),
                FocusNode {
                    role: FocusRole::Pane,
                    value_pattern: true,
                },
                node(FocusRole::List),
            ],
            vec![node(FocusRole::Text), node(FocusRole::Group)],
        ] {
            assert!(!static_text_in_folder_list(&path, true));
        }
        assert!(!static_text_in_folder_list(&[], true));
        for length in [32, 33] {
            let mut path = vec![node(FocusRole::Pane); length];
            path[0] = node(FocusRole::Text);
            path[length - 1] = node(FocusRole::List);
            assert_eq!(static_text_in_folder_list(&path, true), length == 32);
        }
    }

    fn stable() -> ContextEvidence {
        ContextEvidence {
            foreground_stable: true,
            native_focus_stable: true,
            semantic_focus_stable: true,
            folder_items_focused: true,
            unresolved_entries: 0,
        }
    }

    #[test]
    fn selects_focus_instead_of_enumeration_order() {
        let views = [
            ViewEvidence {
                contains_focus: false,
                filesystem: true,
            },
            ViewEvidence {
                contains_focus: true,
                filesystem: true,
            },
            ViewEvidence {
                contains_focus: false,
                filesystem: true,
            },
        ];
        assert_eq!(select_focused_view(&views, stable()), Some(1));
    }

    #[test]
    fn rejects_multiple_focused_views_even_when_one_is_virtual() {
        let views = [
            ViewEvidence {
                contains_focus: true,
                filesystem: true,
            },
            ViewEvidence {
                contains_focus: true,
                filesystem: false,
            },
        ];
        assert_eq!(select_focused_view(&views, stable()), None);
    }

    #[test]
    fn rejects_missing_focus_and_virtual_folders() {
        assert_eq!(select_focused_view(&[], stable()), None);
        for view in [
            ViewEvidence {
                contains_focus: false,
                filesystem: true,
            },
            ViewEvidence {
                contains_focus: true,
                filesystem: false,
            },
        ] {
            assert_eq!(select_focused_view(&[view], stable()), None);
        }
    }

    #[test]
    fn rejects_each_kind_of_instability_and_unknown_context() {
        let views = [ViewEvidence {
            contains_focus: true,
            filesystem: true,
        }];
        for context in [
            ContextEvidence {
                foreground_stable: false,
                ..stable()
            },
            ContextEvidence {
                native_focus_stable: false,
                ..stable()
            },
            ContextEvidence {
                semantic_focus_stable: false,
                ..stable()
            },
            ContextEvidence {
                folder_items_focused: false,
                ..stable()
            },
            ContextEvidence {
                unresolved_entries: 1,
                ..stable()
            },
        ] {
            assert_eq!(select_focused_view(&views, context), None);
        }
    }
}
