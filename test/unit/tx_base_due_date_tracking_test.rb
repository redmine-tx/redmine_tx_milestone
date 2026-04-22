require File.expand_path('../test_helper', __dir__)

class TxBaseDueDateTrackingTest < ActiveSupport::TestCase
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

  def test_version_delay_reset_predicate_checks_version_effective_dates
    assert_equal true, TxBaseHelper.version_delay_reset?(1, 2)
    assert_equal false, TxBaseHelper.version_delay_reset?(2, 1)
    assert_equal false, TxBaseHelper.version_delay_reset?(2, 3)
    assert_equal false, TxBaseHelper.version_delay_reset?(nil, 2)
  end

  def test_version_delay_resets_first_due_date_and_clears_delay_tracking
    issue = Issue.find(1)
    user = User.find(1)
    current_due_date = issue.due_date

    issue.update_columns(
      fixed_version_id: 1,
      first_due_date: current_due_date - 3.days,
      end_date_delayed_on: Time.current,
      end_date_delayed_by_id: user.id,
      end_date_delayed_days: 3
    )

    User.current = user
    issue.init_journal(user, '목표버전 연기')
    issue.current_journal.notify = false
    issue.fixed_version_id = 2

    assert_equal true, issue.save(validate: false)

    issue.reload

    assert_equal current_due_date, issue.first_due_date
    assert_nil issue.end_date_delayed_on
    assert_nil issue.end_date_delayed_by_id
    assert_nil issue.end_date_delayed_days
  end

  def test_version_delay_with_due_date_change_uses_new_due_date_as_baseline
    issue = Issue.find(1)
    user = User.find(1)
    old_due_date = issue.due_date
    new_due_date = old_due_date + 7.days

    issue.update_columns(
      fixed_version_id: 1,
      first_due_date: old_due_date - 5.days,
      end_date_delayed_on: Time.current,
      end_date_delayed_by_id: user.id,
      end_date_delayed_days: 5
    )

    User.current = user
    issue.init_journal(user, '목표버전 연기와 일정 수정')
    issue.current_journal.notify = false
    issue.fixed_version_id = 2
    issue.due_date = new_due_date

    assert_equal true, issue.save(validate: false)

    issue.reload

    assert_equal new_due_date, issue.first_due_date
    assert_nil issue.end_date_delayed_on
    assert_nil issue.end_date_delayed_by_id
    assert_nil issue.end_date_delayed_days
  end

  def test_update_end_date_changed_on_rebuilds_due_date_baseline_after_version_delay
    issue = Issue.find(1)
    user = User.find(1)
    initial_due_date = Date.today + 5.days
    due_date_before_reset = initial_due_date + 3.days
    due_date_after_reset = due_date_before_reset + 4.days

    issue.update_columns(
      fixed_version_id: 1,
      due_date: initial_due_date,
      first_due_date: nil,
      end_date_changed_on: nil,
      end_date_delayed_on: nil,
      end_date_delayed_by_id: nil,
      end_date_delayed_days: nil,
      done_ratio: 10
    )

    User.current = user

    issue.init_journal(user, '일정 1차 연기')
    issue.current_journal.notify = false
    issue.due_date = due_date_before_reset
    assert_equal true, issue.save(validate: false)

    issue.reload
    issue.init_journal(user, '목표버전 연기')
    issue.current_journal.notify = false
    issue.fixed_version_id = 2
    assert_equal true, issue.save(validate: false)

    issue.reload
    issue.init_journal(user, '일정 2차 연기')
    issue.current_journal.notify = false
    issue.due_date = due_date_after_reset
    assert_equal true, issue.save(validate: false)

    issue.update_columns(
      first_due_date: nil,
      end_date_changed_on: nil,
      end_date_delayed_on: nil,
      end_date_delayed_by_id: nil,
      end_date_delayed_days: nil
    )

    issue.update_end_date_changed_on!
    issue.reload

    assert_equal due_date_before_reset, issue.first_due_date
    assert_equal user.id, issue.end_date_delayed_by_id
    assert_equal(
      TxBaseHelper.business_days_between(due_date_before_reset, due_date_after_reset),
      issue.end_date_delayed_days
    )
    assert_not_nil issue.end_date_delayed_on
  end
end
