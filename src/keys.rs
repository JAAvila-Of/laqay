//! Ephemeral modifier state and repeat suppression; no keyboard history.

#[derive(Clone, Default)]
pub struct PasteKeys {
    modifiers: [bool; 8],
    v_down: bool,
}

impl PasteKeys {
    /// Accept normalized left/right modifier keys. Return true once per Ctrl+V
    /// press with no Alt, Shift or Windows modifier. Every event remains native.
    pub fn transition(&mut self, key: u16, down: bool) -> bool {
        let modifier = match key {
            0xa2 => Some(0),
            0xa3 => Some(1),
            0xa0 => Some(2),
            0xa1 => Some(3),
            0xa4 => Some(4),
            0xa5 => Some(5),
            0x5b => Some(6),
            0x5c => Some(7),
            _ => None,
        };
        if let Some(index) = modifier {
            self.modifiers[index] = down;
        }
        if key != 0x56 {
            return false;
        }
        let first = down && !self.v_down;
        self.v_down = down;
        first && (self.modifiers[0] || self.modifiers[1]) && !self.modifiers[2..].contains(&true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn either_control_key_triggers_and_releasing_one_preserves_the_other() {
        for key in [0xa2, 0xa3] {
            let mut keys = PasteKeys::default();
            keys.transition(key, true);
            assert!(keys.transition(0x56, true));
        }
        let mut keys = PasteKeys::default();
        keys.transition(0xa2, true);
        keys.transition(0xa3, true);
        keys.transition(0xa2, false);
        assert!(keys.transition(0x56, true));
    }

    #[test]
    fn suppresses_repeat_until_v_is_released() {
        let mut keys = PasteKeys::default();
        keys.transition(0xa2, true);
        assert!(keys.transition(0x56, true));
        assert!(!keys.transition(0x56, true));
        assert!(!keys.transition(0x56, false));
        assert!(keys.transition(0x56, true));
    }

    #[test]
    fn rejects_unmodified_v_and_each_additional_modifier() {
        assert!(!PasteKeys::default().transition(0x56, true));
        for modifier in [0xa0, 0xa1, 0xa4, 0xa5, 0x5b, 0x5c] {
            let mut keys = PasteKeys::default();
            keys.transition(0xa2, true);
            keys.transition(modifier, true);
            assert!(!keys.transition(0x56, true));
        }
    }
}
