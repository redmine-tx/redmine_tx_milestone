require File.expand_path('../test_helper', __dir__)

class IssueDueDateSyncServiceTest < ActiveSupport::TestCase
  fixtures :projects,
           :users,
           :roles,
           :members,
           :member_roles,
           :issues,
           :issue_statuses,
           :versions,
           :trackers,
           :projects_trackers,
           :issue_categories,
           :enabled_modules,
           :enumerations,
           :attachments,
           :workflows,
           :custom_fields,
           :custom_values,
           :custom_fields_projects,
           :custom_fields_trackers

  def test_sync_due_date_updates_issue_and_creates_journal_detail_without_delivery
    issue = Issue.find(1)
    user = User.find(1)
    old_due_date = issue.due_date
    new_due_date = issue.due_date + 3.days
    previous_updated_on = issue.updated_on
    previous_journal_count = issue.journals.count
    ActionMailer::Base.deliveries.clear

    result = RedmineTxMilestone::IssueDueDateSyncService.sync_due_date!(
      issue: issue,
      due_date: new_due_date,
      user: user
    )

    issue.reload
    journal = issue.journals.order(:id).last
    due_date_detail = journal.details.find { |detail| detail.prop_key == 'due_date' }

    assert_equal true, result
    assert_equal new_due_date, issue.due_date
    assert_operator issue.updated_on, :>, previous_updated_on
    assert_equal previous_journal_count + 1, issue.journals.count
    assert_equal user, journal.user
    assert_equal RedmineTxMilestone::IssueDueDateSyncService::JOURNAL_NOTE, journal.notes
    assert_not_nil due_date_detail
    assert_equal old_due_date.to_s, due_date_detail.old_value
    assert_equal new_due_date.to_s, due_date_detail.value
    assert_equal 0, ActionMailer::Base.deliveries.size
  end

  def test_sync_due_date_returns_false_without_changes
    issue = Issue.find(1)
    user = User.find(1)
    previous_journal_count = issue.journals.count

    result = RedmineTxMilestone::IssueDueDateSyncService.sync_due_date!(
      issue: issue,
      due_date: issue.due_date,
      user: user
    )

    issue.reload

    assert_equal false, result
    assert_equal previous_journal_count, issue.journals.count
  end
end
