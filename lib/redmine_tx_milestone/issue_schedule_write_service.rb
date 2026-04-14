module RedmineTxMilestone
  class IssueScheduleWriteService
    JOURNAL_NOTE = '일정 자동배치'.freeze

    class << self
      def apply(issue:, start_date:, due_date:, user:, note: JOURNAL_NOTE)
        raise ArgumentError, 'issue is required' if issue.nil?
        raise ArgumentError, 'user is required' if user.nil?

        return false if issue.start_date == start_date && issue.due_date == due_date

        issue.init_journal(user, note)
        issue.current_journal.notify = false
        issue.start_date = start_date
        issue.due_date = due_date

        issue.save
      end
    end
  end
end
