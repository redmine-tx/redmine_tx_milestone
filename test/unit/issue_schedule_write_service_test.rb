require File.expand_path('../test_helper', __dir__)

class IssueScheduleWriteServiceTest < ActiveSupport::TestCase
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

  def setup
    @previous_user = User.current
  end

  def teardown
    User.current = @previous_user
  end

  def test_apply_updates_schedule_and_creates_journal_details_without_delivery
    issue = Issue.find(1)
    user = User.find(1)
    old_start_date = issue.start_date
    old_due_date = issue.due_date
    new_start_date = old_start_date + 2.days
    new_due_date = old_due_date + 4.days
    previous_updated_on = issue.updated_on
    previous_journal_count = issue.journals.count
    User.current = user
    ActionMailer::Base.deliveries.clear

    result = RedmineTxMilestone::IssueScheduleWriteService.apply(
      issue: issue,
      start_date: new_start_date,
      due_date: new_due_date,
      user: user
    )

    issue.reload
    journal = issue.journals.order(:id).last
    start_date_detail = journal.details.find { |detail| detail.prop_key == 'start_date' }
    due_date_detail = journal.details.find { |detail| detail.prop_key == 'due_date' }

    assert_equal true, result
    assert_equal new_start_date, issue.start_date
    assert_equal new_due_date, issue.due_date
    assert_operator issue.updated_on, :>, previous_updated_on
    assert_equal previous_journal_count + 1, issue.journals.count
    assert_equal user, journal.user
    assert_equal RedmineTxMilestone::IssueScheduleWriteService::JOURNAL_NOTE, journal.notes
    assert_not_nil start_date_detail
    assert_not_nil due_date_detail
    assert_equal old_start_date.to_s, start_date_detail.old_value
    assert_equal new_start_date.to_s, start_date_detail.value
    assert_equal old_due_date.to_s, due_date_detail.old_value
    assert_equal new_due_date.to_s, due_date_detail.value
    assert_equal 0, ActionMailer::Base.deliveries.size
  end

  def test_apply_updates_due_date_without_creating_start_date_detail
    issue = Issue.find(1)
    user = User.find(1)
    previous_journal_count = issue.journals.count
    new_due_date = issue.due_date + 2.days
    User.current = user

    result = RedmineTxMilestone::IssueScheduleWriteService.apply(
      issue: issue,
      start_date: issue.start_date,
      due_date: new_due_date,
      user: user
    )

    issue.reload
    journal = issue.journals.order(:id).last
    start_date_detail = journal.details.find { |detail| detail.prop_key == 'start_date' }
    due_date_detail = journal.details.find { |detail| detail.prop_key == 'due_date' }

    assert_equal true, result
    assert_equal previous_journal_count + 1, issue.journals.count
    assert_nil start_date_detail
    assert_not_nil due_date_detail
    assert_equal new_due_date.to_s, due_date_detail.value
  end

  def test_apply_returns_false_without_schedule_changes
    issue = Issue.find(1)
    user = User.find(1)
    previous_journal_count = issue.journals.count
    previous_updated_on = issue.updated_on
    User.current = user

    result = RedmineTxMilestone::IssueScheduleWriteService.apply(
      issue: issue,
      start_date: issue.start_date,
      due_date: issue.due_date,
      user: user
    )

    issue.reload

    assert_equal false, result
    assert_equal previous_journal_count, issue.journals.count
    assert_equal previous_updated_on, issue.updated_on
  end
end
