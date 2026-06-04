require 'set'

module RedmineTxMilestone
  class IssueDetailScheduleSummary
    COLOR_PALETTE = [
      '#98E5B0', '#FFD280', '#C897CE', '#8FC5F0', '#FFB0B0',
      '#70D8BE', '#F09897', '#8FBFEA', '#F9CC85', '#78D9A8',
      '#F9C980', '#B880C3', '#6BC2B0', '#E08080', '#70D095'
    ].freeze

    FULL_DAY_VACATION_STATUSES = %w[휴가 휴직 병가].freeze

    def self.build(issue, display_start_date: 6.months.ago.to_date)
      new(issue, display_start_date).build
    end

    def initialize(issue, display_start_date)
      @issue = issue
      @root_issue = issue.root
      @display_start_date = display_start_date
    end

    def build
      input_issue_ids = [root_issue.id]
      parent_issues = [root_issue]
      version_markers = build_version_markers(parent_issues)
      main_issue_colors = build_main_issue_colors(parent_issues)
      issue_to_main_issue = build_issue_to_main_issue(parent_issues)

      all_issues = visible_related_issues(input_issue_ids, parent_issues)
      filtered_issues = scheduled_display_issues(all_issues)
      filtered_all_issues = implementation_issues(all_issues)
      timeline_start_date = display_start_date
      timeline_end_date = (filtered_issues.maximum(:due_date) || Date.today) + 60.days
      holidays = holidays_for(timeline_start_date, timeline_end_date)
      result_data, users = grouped_user_issues(filtered_issues)
      background_issues_by_user = background_issues_for(users.keys, filtered_issues, timeline_start_date)

      {
        root_issue: root_issue,
        input_issue_ids: input_issue_ids,
        parent_issues: parent_issues,
        display_start_date: display_start_date,
        version_markers: version_markers,
        main_issue_colors: main_issue_colors,
        issue_to_main_issue: issue_to_main_issue,
        holidays: holidays,
        full_day_vacation_map: full_day_vacation_map(result_data, timeline_start_date, timeline_end_date),
        result_data: result_data,
        background_issues_by_user: background_issues_by_user,
        total_issue_count: filtered_all_issues.size,
        summarized_issue_count: filtered_issues.where.not(assigned_to_id: nil).size
      }
    end

    private

    attr_reader :issue, :root_issue, :display_start_date

    def build_version_markers(parent_issues)
      versions = parent_issues.map(&:fixed_version).compact.uniq.select { |version| version.effective_date.present? }
      versions.sort_by(&:effective_date).each_with_object([]) do |version, markers|
        version.marks.each do |mark|
          markers << {
            date: mark[:date],
            name: mark[:name],
            color: mark[:is_deadline] ? '#cc0000' : '#9999ff',
            side: 'right',
            lineStyle: mark[:is_deadline] ? 'solid' : 'dashed'
          }
        end
        markers << { date: version.effective_date, name: version.name, color: '#5555cc', side: 'right' }
      end
    end

    def build_main_issue_colors(parent_issues)
      parent_issues.each_with_index.each_with_object({}) do |(parent_issue, index), colors|
        colors[parent_issue.id] = COLOR_PALETTE[index % COLOR_PALETTE.length]
      end
    end

    def build_issue_to_main_issue(parent_issues)
      parent_issues.each_with_object({}) do |parent_issue, mapping|
        mapping[parent_issue.id] = parent_issue.id
        parent_issue.descendants.pluck(:id).each do |descendant_id|
          mapping[descendant_id] = parent_issue.id
        end
      end
    end

    def visible_related_issues(input_issue_ids, parent_issues)
      all_issue_ids = Set.new(input_issue_ids)
      parent_issues.each { |parent_issue| all_issue_ids.merge(parent_issue.descendants.pluck(:id)) }

      Issue.visible.where(id: all_issue_ids.to_a)
    end

    def scheduled_display_issues(all_issues)
      implementation_issues(all_issues)
        .where.not(start_date: nil)
        .where.not(due_date: nil)
        .where('start_date >= ? OR due_date >= ?', display_start_date, display_start_date)
    end

    def implementation_issues(all_issues)
      all_issues.where.not(tracker_id: excluded_tracker_ids)
                .where.not(status_id: IssueStatus.discarded_ids)
    end

    def excluded_tracker_ids
      (Tracker.bug_trackers_ids +
       Tracker.sidejob_trackers_ids +
       Tracker.exception_trackers_ids +
       Tracker.roadmap_trackers_ids).uniq
    end

    def holidays_for(timeline_start_date, timeline_end_date)
      return [] unless defined?(TxBaseHelper::HolidayApi) && TxBaseHelper::HolidayApi.available?

      TxBaseHelper::HolidayApi.for_date_range(timeline_start_date, timeline_end_date)
                                 .map { |date, _name| date.strftime('%Y-%m-%d') }
    rescue StandardError => e
      Rails.logger.warn "[RedmineTxMilestone] issue detail schedule summary holidays failed: #{e.message}"
      []
    end

    def grouped_user_issues(filtered_issues)
      issues_by_user = filtered_issues.where.not(assigned_to_id: nil).group_by(&:assigned_to_id)
      users = User.where(id: issues_by_user.keys.compact).index_by(&:id)
      registered_user_ids = Set.new
      result_data = {}

      groups_to_show.each do |group|
        group_user_ids = group.users.pluck(:id)
        group_users_issues = {}

        group_user_ids.each do |user_id|
          next if registered_user_ids.include?(user_id)
          next unless issues_by_user[user_id]

          user = users[user_id]
          next unless user

          user_issues = issues_by_user[user_id].sort_by(&:start_date)
          next if user_issues.blank?

          group_users_issues[user] = user_issues
          registered_user_ids.add(user_id)
        end

        result_data[group] = group_users_issues if group_users_issues.any?
      end

      [result_data, users]
    end

    def groups_to_show
      excluded_group_ids = Array(TxBaseHelper.config_arr('e_group')).map(&:to_i)
      Group.all.reject { |group| excluded_group_ids.include?(group.id) }
    end

    def background_issues_for(user_ids, filtered_issues, timeline_start_date)
      displayed_issue_ids = filtered_issues.where.not(assigned_to_id: nil).pluck(:id).to_set

      user_ids.each_with_object({}) do |user_id, background_map|
        other_issues = Issue.visible
                            .where(assigned_to_id: user_id)
                            .where.not(id: displayed_issue_ids.to_a)
                            .where.not(start_date: nil)
                            .where.not(due_date: nil)
                            .where.not(tracker_id: excluded_tracker_ids)
                            .where('start_date >= ? OR due_date >= ?', timeline_start_date, timeline_start_date)

        background_map[user_id] = other_issues.to_a if other_issues.any?
      end
    end

    def full_day_vacation_map(result_data, timeline_start_date, timeline_end_date)
      displayed_user_logins = result_data.values.flat_map { |users_issues| users_issues.keys.map(&:login) }.to_set
      return {} if displayed_user_logins.empty?
      return {} unless defined?(TxBaseHelper::UserVacationApi) && TxBaseHelper::UserVacationApi.available?

      TxBaseHelper::UserVacationApi.get_vacation_info(timeline_start_date..timeline_end_date)
                                   .each_with_object({}) do |(date, day_info), vacation_map|
        next unless day_info.present?

        day_map = day_info.each_with_object({}) do |(login, info), acc|
          next unless displayed_user_logins.include?(login)

          status = info[:status].to_s
          next unless FULL_DAY_VACATION_STATUSES.include?(status)

          acc[login] = status
        end

        vacation_map[date.strftime('%Y-%m-%d')] = day_map if day_map.any?
      end
    rescue StandardError => e
      Rails.logger.warn "[RedmineTxMilestone] issue detail schedule summary vacations failed: #{e.message}"
      {}
    end
  end
end
