module RedmineTxMilestone
  module SettingsMigration
    # 이전 형식(개별 키)을 새 형식(배열)으로 변환
    def self.migrate_to_array(old_settings)
      deadlines = []
      (1..10).each do |i|
        days = old_settings["setting_milestone_days_#{i}"]
        title = old_settings["setting_milestone_title_#{i}"]
        next if days.blank?
        deadlines << { 'days' => days, 'title' => title }
      end
      old_settings.merge('setting_milestone_deadlines' => deadlines)
    end

    # 새/이전 형식 모두 지원하는 읽기
    def self.get_deadlines(settings)
      return [] if settings.blank?

      if settings['setting_milestone_deadlines'].present?
        settings['setting_milestone_deadlines']
      else
        migrate_to_array(settings)['setting_milestone_deadlines']
      end
    end
  end
end
