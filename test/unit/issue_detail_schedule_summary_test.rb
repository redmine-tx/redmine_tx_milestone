require File.expand_path('../test_helper', __dir__)
require 'securerandom'

class IssueDetailScheduleSummaryTest < ActiveSupport::TestCase
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
           :enabled_modules,
           :groups_users

  def setup
    User.current = User.find(1)
  end

  def test_build_includes_hidden_teammates_for_issue_detail_expansion
    project = Project.find(1)
    tracker = implementation_tracker
    group = Group.generate!(name: 'Schedule detail team')
    suffix = SecureRandom.hex(4)
    visible_user = User.generate!(login: "visible_#{suffix}", mail: "visible_#{suffix}@example.com")
    hidden_user = User.generate!(login: "hidden_#{suffix}", mail: "hidden_#{suffix}@example.com")
    User.add_to_project(visible_user, project)
    User.add_to_project(hidden_user, project)
    group.users << visible_user
    group.users << hidden_user

    root_issue = Issue.generate!(
      project: project,
      tracker: tracker,
      assigned_to: visible_user,
      start_date: Date.today,
      due_date: Date.today + 2.days
    )
    background_issue = Issue.generate!(
      project: project,
      tracker: tracker,
      assigned_to: hidden_user,
      start_date: Date.today + 1.day,
      due_date: Date.today + 3.days
    )

    summary = RedmineTxMilestone::IssueDetailScheduleSummary.build(root_issue, display_start_date: Date.yesterday)

    assert_includes summary[:result_data].keys, group
    assert_includes summary[:hidden_teammates_by_group][group], hidden_user
    assert_equal [background_issue.id], summary[:background_issues_by_user][hidden_user.id].map(&:id)
  end

  private

  def implementation_tracker
    tracker = Tracker.generate!(name: 'Schedule detail', is_in_roadmap: false)
    Project.find(1).trackers << tracker unless Project.find(1).trackers.include?(tracker)
    tracker
  end
end
