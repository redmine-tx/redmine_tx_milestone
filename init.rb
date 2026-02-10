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
    'setting_milestone_deadlines' => [
      { 'days' => '7', 'title' => '마감 1주전' },
      { 'days' => '14', 'title' => '마감 2주전' }
    ],
    'setting_milestone_use_redmine_auto_schedule' => 'false'
  }, :partial => 'settings/redmine_tx_milestone'
end

Rails.application.config.after_initialize do
  require_dependency File.expand_path('../lib/redmine_tx_milestone/settings_migration', __FILE__)
  require_dependency File.expand_path('../lib/redmine_tx_milestone_helper', __FILE__)

  # 플러그인 로드 시 이전 형식 → 새 형식 자동 마이그레이션
  if Setting.plugin_redmine_tx_milestone.present?
    current = Setting.plugin_redmine_tx_milestone
    if current['setting_milestone_deadlines'].blank? && current['setting_milestone_days_1'].present?
      Rails.logger.info "[RedmineTxMilestone] Auto-migrating settings to new format"
      migrated = RedmineTxMilestone::SettingsMigration.migrate_to_array(current)
      Setting.plugin_redmine_tx_milestone = migrated
    end
  end

  Version.send(:include, RedmineTxMilestoneHelper::VersionPatch)
  Issue.send(:prepend, RedmineTxMilestoneAutoScheduleHelper::IssuePatch)
  IssueRelation.send(:prepend, RedmineTxMilestoneAutoScheduleHelper::IssueRelationPatch)
end

