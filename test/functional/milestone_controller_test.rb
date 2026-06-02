require File.expand_path('../test_helper', __dir__)

class MilestoneControllerTest < Redmine::ControllerTest
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
    User.current = nil
    @request.session[:user_id] = 2
    Role.find(1).add_permission! :view_milestone
    EnabledModule.create!(project_id: 1, name: 'redmine_tx_milestone') unless EnabledModule.exists?(project_id: 1, name: 'redmine_tx_milestone')
  end

  def test_update_issue_schedule_updates_dates
    issue = Issue.find(1)
    new_start_date = issue.start_date + 1.day
    new_due_date = issue.due_date + 1.day

    post :update_issue_schedule, params: {
      project_id: 'ecookbook',
      issue_id: issue.id,
      start_date: new_start_date.iso8601,
      due_date: new_due_date.iso8601
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['success']
    assert_equal new_start_date.iso8601, body['start_date']
    assert_equal new_due_date.iso8601, body['due_date']
    assert_equal new_start_date, issue.reload.start_date
    assert_equal new_due_date, issue.due_date
  end

  def test_update_issue_schedule_rejects_due_date_before_start_date
    issue = Issue.find(1)
    original_start_date = issue.start_date
    original_due_date = issue.due_date

    post :update_issue_schedule, params: {
      project_id: 'ecookbook',
      issue_id: issue.id,
      start_date: original_due_date.iso8601,
      due_date: (original_start_date - 1.day).iso8601
    }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body['success']
    assert_equal original_start_date, issue.reload.start_date
    assert_equal original_due_date, issue.due_date
  end

  def test_update_issue_schedule_rejects_missing_existing_schedule
    issue = Issue.find(1)
    issue.update_columns(start_date: nil)

    post :update_issue_schedule, params: {
      project_id: 'ecookbook',
      issue_id: issue.id,
      start_date: Date.today.iso8601,
      due_date: (Date.today + 1.day).iso8601
    }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body['success']
    assert_nil issue.reload.start_date
  end

  def test_update_issue_schedule_updates_start_date_only_when_due_date_is_missing
    issue = Issue.find(1)
    original_start_date = issue.start_date
    issue.update_columns(due_date: nil)
    new_start_date = original_start_date + 2.days

    post :update_issue_schedule, params: {
      project_id: 'ecookbook',
      issue_id: issue.id,
      start_date: new_start_date.iso8601
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['success']
    assert_equal new_start_date.iso8601, body['start_date']
    assert_nil body['due_date']
    assert_equal new_start_date, issue.reload.start_date
    assert_nil issue.due_date
  end

  def test_update_issue_schedule_updates_due_date_only_when_start_date_is_missing
    issue = Issue.find(1)
    original_due_date = issue.due_date
    issue.update_columns(start_date: nil)
    new_due_date = original_due_date + 2.days

    post :update_issue_schedule, params: {
      project_id: 'ecookbook',
      issue_id: issue.id,
      due_date: new_due_date.iso8601
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['success']
    assert_nil body['start_date']
    assert_equal new_due_date.iso8601, body['due_date']
    assert_nil issue.reload.start_date
    assert_equal new_due_date, issue.due_date
  end

  def test_update_issue_schedules_updates_multiple_dates
    first_issue = Issue.find(1)
    second_issue = Issue.find(7)
    first_start_date = first_issue.start_date + 1.day
    first_due_date = first_issue.due_date + 1.day
    second_start_date = second_issue.start_date + 2.days
    second_due_date = second_issue.due_date + 2.days

    post :update_issue_schedules, params: {
      project_id: 'ecookbook',
      schedules: [
        {
          issue_id: first_issue.id,
          start_date: first_start_date.iso8601,
          due_date: first_due_date.iso8601
        },
        {
          issue_id: second_issue.id,
          start_date: second_start_date.iso8601,
          due_date: second_due_date.iso8601
        }
      ]
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['success']
    assert_equal 2, body['saved_count']
    assert_equal first_start_date, first_issue.reload.start_date
    assert_equal first_due_date, first_issue.due_date
    assert_equal second_start_date, second_issue.reload.start_date
    assert_equal second_due_date, second_issue.due_date
  end

  def test_update_issue_schedules_updates_partial_dates
    first_issue = Issue.find(1)
    second_issue = Issue.find(7)
    first_issue.update_columns(due_date: nil)
    second_issue.update_columns(start_date: nil)
    first_start_date = first_issue.start_date + 1.day
    second_due_date = second_issue.due_date + 1.day

    post :update_issue_schedules, params: {
      project_id: 'ecookbook',
      schedules: [
        {
          issue_id: first_issue.id,
          start_date: first_start_date.iso8601
        },
        {
          issue_id: second_issue.id,
          due_date: second_due_date.iso8601
        }
      ]
    }

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body['success']
    assert_equal 2, body['saved_count']
    assert_equal first_start_date, first_issue.reload.start_date
    assert_nil first_issue.due_date
    assert_nil second_issue.reload.start_date
    assert_equal second_due_date, second_issue.due_date
  end

  def test_update_issue_schedules_rejects_invalid_payload_without_changes
    first_issue = Issue.find(1)
    second_issue = Issue.find(7)
    first_original_start_date = first_issue.start_date
    first_original_due_date = first_issue.due_date
    second_original_start_date = second_issue.start_date
    second_original_due_date = second_issue.due_date

    post :update_issue_schedules, params: {
      project_id: 'ecookbook',
      schedules: [
        {
          issue_id: first_issue.id,
          start_date: (first_original_start_date + 1.day).iso8601,
          due_date: (first_original_due_date + 1.day).iso8601
        },
        {
          issue_id: second_issue.id,
          start_date: second_original_due_date.iso8601,
          due_date: (second_original_start_date - 1.day).iso8601
        }
      ]
    }

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body['success']
    assert_equal first_original_start_date, first_issue.reload.start_date
    assert_equal first_original_due_date, first_issue.due_date
    assert_equal second_original_start_date, second_issue.reload.start_date
    assert_equal second_original_due_date, second_issue.due_date
  end
end
