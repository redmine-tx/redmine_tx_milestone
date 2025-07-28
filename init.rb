Redmine::Plugin.register :redmine_tx_milestone do
  name 'Redmine Tx Milestone'
  author 'KiHyun Kang'
  description '마일스톤 입니다'
  version '0.0.1'
  url 'http://example.com/path/to/plugin'
  author_url 'http://example.com/about'

  requires_redmine_plugin :redmine_tx_0_base, :version_or_higher => '0.0.1'
  requires_redmine_plugin :redmine_tx_advanced_issue_status, :version_or_higher => '0.0.1'
  requires_redmine_plugin :redmine_tx_advanced_tracker, :version_or_higher => '0.0.1'

  #menu :top_menu, :redmine_tx_gantt, { controller: 'redmine_tx_gantt', action: 'index' }, caption: 'Gantt', if: Proc.new { User.current.logged? }

  menu :project_menu, 
       :redmine_tx_milestone, 
       { controller: 'milestone', action: 'index' }, 
       caption: '마일스톤', 
       param: :project_id, 
       after: :roadmap,
       permission: :view_milestone

  project_module :redmine_tx_milestone do
    permission :view_milestone, { milestone: [:index] }
  end

  settings :default => {
    'setting_milestone_days_1' => '7',
    'setting_milestone_title_1' => '마감 1주전',
    'setting_milestone_days_2' => '14',
    'setting_milestone_title_2' => '마감 2주전',
    'setting_milestone_days_3' => '',
    'setting_milestone_title_3' => '',
    'setting_milestone_days_4' => '',
    'setting_milestone_title_4' => '',
    'setting_milestone_days_5' => '',
    'setting_milestone_title_5' => '',
    'setting_milestone_use_redmine_auto_schedule' => 'false'
  }, :partial => 'settings/redmine_tx_milestone'
end

Rails.application.config.after_initialize do
  require_dependency File.expand_path('../lib/redmine_tx_milestone_helper', __FILE__)

  Version.send(:include, RedmineTxMilestoneHelper::VersionPatch)  
  Issue.send(:prepend, RedmineTxMilestoneAutoScheduleHelper::IssuePatch)
  IssueRelation.send(:prepend, RedmineTxMilestoneAutoScheduleHelper::IssueRelationPatch)
end

