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
end
