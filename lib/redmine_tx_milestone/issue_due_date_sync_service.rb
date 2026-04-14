module RedmineTxMilestone
  class IssueDueDateSyncService
    JOURNAL_NOTE = '일정 동기화'.freeze

    class << self
      def sync_due_date!(issue:, due_date:, user:, note: JOURNAL_NOTE)
        raise ArgumentError, 'issue is required' if issue.nil?
        raise ArgumentError, 'user is required' if user.nil?

        return false if due_date.blank?
        return false unless issue.due_date.nil? || issue.due_date < due_date

        issue.init_journal(user, note)
        issue.current_journal.notify = false
        issue.due_date = due_date

        return true if issue.save(validate: false)

        raise ActiveRecord::RecordNotSaved.new('Failed to sync issue due date', issue)
      end
    end
  end
end
