require File.expand_path('../test_helper', __dir__)

class RedmineTxMilestoneHelperTest < ActiveSupport::TestCase
  include RedmineTxMilestoneHelper

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
    @original_settings = Setting.plugin_redmine_tx_milestone
    @issue_1 = Issue.find(1)
    @issue_2 = Issue.find(2)
    @issue_1_original_tags = @issue_1.tag_list.dup
    @issue_2_original_tags = @issue_2.tag_list.dup

    @issue_1.tag_list = ['Major']
    @issue_2.tag_list = ['Hotfix']
    @issue_1.save!
    @issue_2.save!
  end

  def teardown
    @issue_1.tag_list = @issue_1_original_tags
    @issue_2.tag_list = @issue_2_original_tags
    @issue_1.save!
    @issue_2.save!
    Setting.plugin_redmine_tx_milestone = @original_settings if @original_settings
  end

  def test_major_issue_tag_names_removes_blank_values
    settings = {
      'setting_milestone_major_issue_tags' => ['', 'Major', 'Major', 'Hotfix']
    }

    assert_equal %w[Major Hotfix], RedmineTxMilestoneHelper.major_issue_tag_names(settings)
  end

  def test_milestone_major_issues_keeps_existing_filter_when_tags_not_selected
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_major_issue_tags' => ['']
    )

    issues = milestone_major_issues([@issue_1, @issue_2]) { |issue| issue.id == @issue_1.id }

    assert_equal [@issue_1.id], issues.map(&:id)
  end

  def test_milestone_major_issues_filters_by_any_selected_tag
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_major_issue_tags' => %w[Hotfix Missing]
    )

    issues = milestone_major_issues([@issue_1, @issue_2])

    assert_equal [@issue_2.id], issues.map(&:id)
  end
end
