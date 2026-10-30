//! Generation tickets prevent paused or stopped work from resuming later.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

pub(crate) struct Activity {
    state: AtomicU64,
    stopped: AtomicBool,
}

impl Activity {
    pub fn new(enabled: bool) -> Self {
        Self {
            state: AtomicU64::new(u64::from(enabled)),
            stopped: AtomicBool::new(false),
        }
    }
    pub fn is_stopped(&self) -> bool {
        self.stopped.load(Ordering::Acquire)
    }
    pub fn ticket(&self) -> Option<u64> {
        let state = self.state.load(Ordering::Acquire);
        (!self.is_stopped() && state & 1 != 0).then_some(state)
    }
    pub fn valid(&self, ticket: u64) -> bool {
        self.ticket() == Some(ticket)
    }
    pub fn set_enabled(&self, enabled: bool) {
        let mut current = self.state.load(Ordering::Acquire);
        loop {
            let enabled = enabled && !self.is_stopped();
            // Exhaustion fails closed instead of reusing an old generation.
            let next = current
                .checked_add(2)
                .map(|next| (next & !1) | u64::from(enabled))
                .unwrap_or(u64::MAX - 1);
            match self.state.compare_exchange_weak(
                current,
                next,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => return,
                Err(actual) => current = actual,
            }
        }
    }
    pub fn disable_if_current(&self, ticket: u64) {
        let next = ticket.checked_add(2).unwrap_or(u64::MAX - 1) & !1;
        let _ = self
            .state
            .compare_exchange(ticket, next, Ordering::AcqRel, Ordering::Acquire);
    }
    pub fn stop(&self) {
        self.stopped.store(true, Ordering::Release);
        self.set_enabled(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn pause_and_resume_never_revive_a_queued_ticket() {
        let activity = Activity::new(true);
        let first = activity.ticket().unwrap();
        activity.set_enabled(false);
        assert!(activity.ticket().is_none());
        activity.set_enabled(true);
        assert!(!activity.valid(first));
        assert!(activity.valid(activity.ticket().unwrap()));
    }
    #[test]
    fn a_stale_failure_cannot_disable_a_new_session() {
        let activity = Activity::new(true);
        let old = activity.ticket().unwrap();
        activity.set_enabled(false);
        activity.set_enabled(true);
        let current = activity.ticket().unwrap();
        activity.disable_if_current(old);
        assert!(activity.valid(current));
        activity.disable_if_current(current);
        assert!(activity.ticket().is_none());
    }
    #[test]
    fn stop_is_permanent_and_invalidates_all_work() {
        let activity = Activity::new(true);
        let old = activity.ticket().unwrap();
        activity.stop();
        activity.set_enabled(true);
        assert!(activity.is_stopped());
        assert!(activity.ticket().is_none());
        assert!(!activity.valid(old));
    }
    #[test]
    fn disabled_start_does_not_issue_tickets() {
        let activity = Activity::new(false);
        assert!(activity.ticket().is_none());
        activity.set_enabled(true);
        assert!(activity.ticket().is_some());
    }
    #[test]
    fn generation_exhaustion_fails_closed() {
        let activity = Activity::new(true);
        activity.state.store(u64::MAX, Ordering::Release);
        activity.set_enabled(true);
        assert!(activity.ticket().is_none());
    }

    #[test]
    fn work_waiting_on_an_encoder_stays_cancelled_after_a_resume() {
        use std::sync::{Arc, Barrier};
        let activity = Arc::new(Activity::new(true));
        let ticket = activity.ticket().unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let worker_gate = Arc::clone(&activity);
        let worker_barrier = Arc::clone(&barrier);
        let worker = std::thread::spawn(move || {
            worker_barrier.wait();
            worker_gate.valid(ticket)
        });
        activity.set_enabled(false);
        activity.set_enabled(true);
        barrier.wait();
        assert!(!worker.join().unwrap());
    }
}
