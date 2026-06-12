module RedmineTxMilestoneHelper
  # TxBaseHelper의 일감 테이블 헬퍼 메서드 사용
  include TxBaseHelper

  REVIEW_VERSION_CUSTOM_FIELD_SETTING = 'setting_milestone_review_version_custom_field_ids'.freeze
  AUTO_SCHEDULE_PRIORITY_CUSTOM_FIELD_SETTING = 'setting_milestone_auto_schedule_priority_custom_field_id'.freeze
  ISSUE_DETAIL_SCHEDULE_SUMMARY_TRACKER_SETTING = 'setting_milestone_issue_detail_schedule_summary_tracker_ids'.freeze

  def self.major_issue_tags_plugin_available?
    Redmine::Plugin.respond_to?(:installed?) &&
      Redmine::Plugin.installed?(:redmineup_tags) &&
      Issue.respond_to?(:all_tags) &&
      Issue.respond_to?(:tagged_with)
  rescue StandardError
    false
  end

  def self.major_issue_tag_names(settings = Setting.plugin_redmine_tx_milestone)
    Array(settings&.[]('setting_milestone_major_issue_tags'))
      .map(&:to_s)
      .reject(&:blank?)
      .uniq
  end

  def self.available_major_issue_tags
    return [] unless major_issue_tags_plugin_available?

    Issue.all_tags(sort_by: "#{Redmineup::Tag.table_name}.name", order: 'ASC').map(&:name)
  rescue StandardError
    []
  end

  def self.review_version_custom_field_ids(settings = Setting.plugin_redmine_tx_milestone)
    Array(settings&.[](REVIEW_VERSION_CUSTOM_FIELD_SETTING))
      .map(&:to_s)
      .reject(&:blank?)
      .map(&:to_i)
      .select(&:positive?)
      .uniq
  end

  def self.available_review_version_custom_fields
    return [] unless defined?(IssueCustomField)

    IssueCustomField.where(field_format: 'version').order(:name).to_a
  rescue StandardError
    []
  end

  def self.auto_schedule_priority_custom_field_id(settings = Setting.plugin_redmine_tx_milestone)
    id = settings&.[](AUTO_SCHEDULE_PRIORITY_CUSTOM_FIELD_SETTING).to_s
    id.present? && id.to_i.positive? ? id.to_i : nil
  end

  def self.auto_schedule_priority_custom_field(settings = Setting.plugin_redmine_tx_milestone)
    id = auto_schedule_priority_custom_field_id(settings)
    return nil unless id

    field = IssueCustomField.find_by(id: id)
    return nil unless field&.field_format == 'list'
    return nil if field.multiple?

    field
  rescue StandardError
    nil
  end

  def self.available_auto_schedule_priority_custom_fields
    return [] unless defined?(IssueCustomField)

    IssueCustomField.where(field_format: 'list').order(:name).to_a.reject(&:multiple?)
  rescue StandardError
    []
  end

  def self.issue_detail_schedule_summary_tracker_ids(settings = Setting.plugin_redmine_tx_milestone)
    Array(settings&.[](ISSUE_DETAIL_SCHEDULE_SUMMARY_TRACKER_SETTING))
      .map(&:to_s)
      .reject(&:blank?)
      .map(&:to_i)
      .select(&:positive?)
      .uniq
  end

  def self.available_issue_detail_schedule_summary_trackers
    return [] unless defined?(Tracker)

    if Tracker.respond_to?(:sorted)
      Tracker.sorted.to_a
    else
      Tracker.order(:position).to_a
    end
  rescue StandardError
    []
  end

  def self.issue_detail_schedule_summary_enabled?(issue, settings = Setting.plugin_redmine_tx_milestone)
    tracker_ids = issue_detail_schedule_summary_tracker_ids(settings)
    issue.present? && tracker_ids.include?(issue.tracker_id.to_i)
  end

  def self.auto_schedule_priority_column_name(settings = Setting.plugin_redmine_tx_milestone)
    field = auto_schedule_priority_custom_field(settings)
    field ? :"cf_#{field.id}" : nil
  end

  def self.auto_schedule_priority_value(issue, custom_field = auto_schedule_priority_custom_field)
    return 0.0 unless custom_field && issue.respond_to?(:custom_field_value)

    raw_value = Array(issue.custom_field_value(custom_field)).find(&:present?)
    priority_text = raw_value.to_s.match(/(?<![\d.])-?\d+(?![\d.])/)&.[](0)
    priority_text ? Integer(priority_text) : 0
  rescue ArgumentError, TypeError
    0
  end

  def milestone_major_issues(issues)
    filtered_issues = block_given? ? Array(issues).select { |issue| yield(issue) } : Array(issues)
    selected_tags = RedmineTxMilestoneHelper.major_issue_tag_names
    return filtered_issues if filtered_issues.blank? || selected_tags.blank?
    return filtered_issues unless RedmineTxMilestoneHelper.major_issue_tags_plugin_available?

    tagged_issue_ids = Issue.tagged_with(
      selected_tags,
      conditions: ["#{Issue.table_name}.id IN (?)", filtered_issues.map(&:id)]
    ).map(&:id)

    filtered_issues.select { |issue| tagged_issue_ids.include?(issue.id) }
  end

  def milestone_review_issues(version)
    custom_field_ids = RedmineTxMilestoneHelper.review_version_custom_field_ids
    return [] if version.blank? || custom_field_ids.blank?

    Issue.visible
         .joins(:custom_values)
         .where(tracker_id: Tracker.roadmap_trackers_ids)
         .where.not(status_id: IssueStatus.discarded_ids)
         .where(custom_values: { custom_field_id: custom_field_ids, value: version.id.to_s })
         .where("#{Issue.table_name}.fixed_version_id IS NULL OR #{Issue.table_name}.fixed_version_id <> ?", version.id)
         .distinct
         .to_a
  end

  # 버전별 색상 코드 반환 메소드
  # effective_date 기준으로 남은 기간에 따라 다른 색상 반환
  def get_version_color(version)
    return "#ccc" unless version.effective_date 
    grade = [0, (version.effective_date - Date.today).to_i / 12].max
    case grade
    when 0
      "#099"  # 기한 임박
    when 1
      "#4bb"  # 여유 있음
    when 2
      "#8bb"  # 충분한 시간
    else
      "#bbb"  # 기타
    end
  end

  def build_issue_query(name, project, column_names = nil)
    query = IssueQuery.new(name: name)
    query.project = project
    query.column_names = column_names || [:id, :tip, :status, :priority, :subject, :assigned_to, :fixed_version_plus, :done_ratio, :due_date]
=begin    
    if params[:sort].present?
      query.sort_criteria = params[:sort]
    end
=end    
    query
  end

  def render_issues( name, project, issues, column_names = nil )
    render partial: 'issues/list', locals: { 
            query: build_issue_query( name, project, column_names ), 
            issues: issues, 
            context_menu: true
          }, class: 'no-margin-bottom'
  end

  # BUG 이슈 필터링 파라미터 생성
  def build_bug_issues_filter_params(assignee_id: nil, version_ids: nil, other_filters: {})
    bug_ids = Tracker.where(is_bug: true).pluck(:id)
    
    # 기본 필터 설정
    base_params = {
      'set_filter' => '1',
      'sort' => 'assigned_to:desc,start_date',
      'group_by' => 'fixed_version',
      't[]' => ''
    }
    
    # 필터 필드들을 개별적으로 추가 (중첩 배열 방지)
    filter_count = 0
    
    # assigned_to_id 필터 (먼저 설정)
    if assignee_id
      base_params['f[]'] = [] unless base_params['f[]']
      base_params['f[]'] << 'assigned_to_id'
      base_params['op[assigned_to_id]'] = '='
      base_params['v[assigned_to_id]'] = [assignee_id.to_s]
      filter_count += 1
    end
    
    # status_id 필터
    base_params['f[]'] = [] unless base_params['f[]']
    base_params['f[]'] << 'status_id'
    base_params['op[status_id]'] = '!'
    base_params['v[status_id]'] = ['6']
    filter_count += 1
    
    # fixed_version_id 필터 (version_ids가 주어졌을 때만 적용)
    if version_ids
      base_params['f[]'] << 'fixed_version_id'
      base_params['op[fixed_version_id]'] = '='
      if version_ids.is_a?(Array)
        base_params['v[fixed_version_id]'] = version_ids.map(&:to_s)
      else
        base_params['v[fixed_version_id]'] = [version_ids.to_s]
      end
      filter_count += 1
    end
    
    # end_time 필터 
    base_params['f[]'] << 'end_time'
    base_params['op[end_time]'] = '!*'
    filter_count += 1
    
    # tracker_id 필터
    base_params['f[]'] << 'tracker_id'
    base_params['op[tracker_id]'] = '='
    base_params['v[tracker_id]'] = bug_ids.map(&:to_s)
    filter_count += 1
    
    # 빈 필터 추가 (레드마인 호환성을 위해)
    base_params['f[]'] << ''
    
    # 컬럼 설정
    base_params['c'] = ['tracker', 'status', 'subject', 'assigned_to', 'category', 'done_ratio', 'due_date', 'tags_relations', 'tip']
    
    base_params.merge(other_filters)
  end

  # 일관된 일감 링크 생성
  def link_to_issue_with_id(issue, options = {})
    text = options[:show_tracker] == false ? "##{issue.id}" : "#{issue.tracker} ##{issue.id}"
    text += ": #{issue.subject}" unless options[:subject] == false
    
    link_to text, issue_path(issue), 
            class: issue.css_classes, 
            title: issue.subject.truncate(100)
  end

  # BUG 이슈 링크 생성 (카운트와 함께)
  def link_to_bug_issues_count(bug_ids, count, assignee_id: nil, version_ids: nil, category_ids: nil, include_none_category: false, other_filters: {})
    return count.to_s if count == 0
    
    query_parts = []
    query_parts << 'set_filter=1'
    query_parts << 'sort=assigned_to%3Adesc%2Cstart_date'
    
    # assigned_to_id 필터
    if assignee_id
      query_parts << 'f%5B%5D=assigned_to_id'
      query_parts << 'op%5Bassigned_to_id%5D=%3D'
      query_parts << "v%5Bassigned_to_id%5D%5B%5D=#{assignee_id}"
    end
    
    # status_id 필터
    query_parts << 'f%5B%5D=status_id'
    query_parts << 'op%5Bstatus_id%5D=%21'
    query_parts << 'v%5Bstatus_id%5D%5B%5D=6'
    
    # fixed_version_id 필터 (version_ids가 주어졌을 때만 적용)
    if version_ids
      query_parts << 'f%5B%5D=fixed_version_id'
      query_parts << 'op%5Bfixed_version_id%5D=%3D'
      if version_ids.is_a?(Array)
        version_ids.each { |vid| query_parts << "v%5Bfixed_version_id%5D%5B%5D=#{vid}" }
      else
        query_parts << "v%5Bfixed_version_id%5D%5B%5D=#{version_ids}"
      end
    end
    
    # end_time 필터
    query_parts << 'f%5B%5D=end_time'
    query_parts << 'op%5Bend_time%5D=%21%2A'
    
    # tracker_id 필터
    query_parts << 'f%5B%5D=tracker_id'
    query_parts << 'op%5Btracker_id%5D=%3D'
    bug_ids.each { |bid| query_parts << "v%5Btracker_id%5D%5B%5D=#{bid}" }
    
    # category_id 필터
    if include_none_category
      query_parts << 'f%5B%5D=category_id'
      query_parts << 'op%5Bcategory_id%5D=%21%2A'
    elsif category_ids && category_ids.respond_to?(:each) && category_ids.any?
      query_parts << 'f%5B%5D=category_id'
      query_parts << 'op%5Bcategory_id%5D=%3D'
      category_ids.each { |cid| query_parts << "v%5Bcategory_id%5D%5B%5D=#{cid}" }
    end

    # 빈 필터
    query_parts << 'f%5B%5D='
    
    # 컬럼 설정
    columns = ['tracker', 'status', 'subject', 'assigned_to', 'category', 'done_ratio', 'due_date', 'tags_relations', 'tip']
    columns.each { |col| query_parts << "c%5B%5D=#{col}" }
    
    # 기타 설정
    query_parts << 'group_by=fixed_version'
    query_parts << 't%5B%5D='
    
    # URL 구성
    base_url = if defined?(@project) && @project
                 "/projects/#{@project.identifier}/issues"
               else
                 "/issues"
               end
    
    full_url = "#{base_url}?#{query_parts.join('&')}"
    
    link_to count, full_url, target: '_blank'
  end

  # 일감 상태에 따른 CSS 클래스명 반환 (인라인 스타일 대체)
  def gantt_issue_css_class(issue)
    overdue_due_date = issue.due_date && issue.due_date < Date.today
    overdue_start_date = IssueStatus.is_new?(issue.status_id) && issue.start_date && issue.start_date < Date.today

    if IssueStatus.is_postponed?(issue.status_id)
      'issue-postponed'
    elsif IssueStatus.is_discarded?(issue.status_id)
      'issue-discarded'
    elsif IssueStatus.is_implemented?(issue.status_id)
      'issue-implemented'
    elsif IssueStatus.is_in_progress?(issue.status_id)
      if overdue_due_date
        'issue-in-progress issue-overdue'
      else
        'issue-in-progress'
      end
    else
      if overdue_due_date || overdue_start_date
        'issue-overdue'
      else
        'issue-default'
      end
    end
  end

  # 상태 기간 배치 쿼리 (N+1 방지)
  def gantt_status_periods(issues)
    issue_ids = Array(issues).map(&:id).compact
    status_groups = gantt_status_period_groups
    watched_status_ids = status_groups.values.flatten.uniq
    return {} if issue_ids.empty? || watched_status_ids.empty?

    status_transitions = JournalDetail.joins(:journal)
      .where(journals: { journalized_type: 'Issue', journalized_id: issue_ids })
      .where(property: 'attr', prop_key: 'status_id')
      .where("journal_details.old_value IN (?) OR journal_details.value IN (?)", watched_status_ids, watched_status_ids)
      .select('journals.journalized_id AS issue_id, journals.created_on, journal_details.old_value, journal_details.value')
      .order('journals.journalized_id, journals.created_on')

    gantt_status_periods_from_transitions(status_transitions, status_groups)
  end

  def gantt_status_period_groups
    {
      paused: IssueStatus.paused_ids,
      review: IssueStatus.in_review_ids
    }.transform_values { |ids| Array(ids).map(&:to_s).reject(&:blank?).uniq }
     .reject { |_name, ids| ids.empty? }
  end

  def gantt_status_periods_from_transitions(transitions, status_groups)
    periods_map = status_groups.keys.each_with_object({}) { |name, map| map[name] = {} }

    Array(transitions).group_by(&:issue_id).each do |issue_id, issue_transitions|
      status_groups.each do |name, raw_status_ids|
        status_ids = Array(raw_status_ids).map(&:to_s)
        periods = []

        issue_transitions.each do |transition|
          old_in_group = status_ids.include?(transition.old_value.to_s)
          new_in_group = status_ids.include?(transition.value.to_s)
          transition_date = transition.created_on.to_date

          if new_in_group && !old_in_group
            periods << { entered_at: transition_date, exited_at: nil } unless periods.last && periods.last[:exited_at].nil?
          elsif old_in_group && !new_in_group && periods.last && periods.last[:exited_at].nil?
            periods.last[:exited_at] = transition_date
          end
        end

        periods_map[name][issue_id] = periods if periods.any?
      end
    end

    periods_map
  end

  # paused 구간만 필요로 하는 기존 호출용 wrapper
  def gantt_paused_periods(issues)
    gantt_status_periods(issues).fetch(:paused, {})
  end

  def gantt_bar_period_segment(period, bar_date, issue_end_date, cell_width)
    return nil unless period && period[:entered_at] && issue_end_date

    period_start = period[:entered_at].to_date
    period_end = (period[:exited_at] || Date.today).to_date
    bar_date = bar_date.to_date
    issue_end_date = issue_end_date.to_date

    visible_start = [period_start, bar_date].max
    visible_end = [period_end, issue_end_date].min
    return nil if visible_start > visible_end || visible_start > issue_end_date || visible_end < bar_date

    {
      left_px: (visible_start - bar_date).to_i * cell_width,
      width_px: (visible_end - visible_start + 1).to_i * cell_width
    }
  end

  # parent-child depth 계산 (이슈 목록 기반)
  def gantt_depth_map(issues)
    depth_map = {}
    issues.each_with_index do |issue, index|
      depth = if index > 0
        prev_issue = issues[index - 1]
        if issue.parent_id == prev_issue.id
          depth_map[issue.parent_id].to_i + 1
        elsif issue.parent_id == prev_issue.parent_id
          depth_map[prev_issue.id].to_i
        else
          if depth_map[issue.parent_id]
            depth_map[issue.parent_id].to_i + 1
          else
            0
          end
        end
      else
        0
      end
      depth_map[issue.id] = depth
    end
    depth_map
  end

  # 표시 중인 최상위 부모 이슈별로 자식 예정일 초과분 계산
  def gantt_top_level_overrun_due_dates(issues, descendant_issues = nil)
    return {} if issues.blank?

    displayed_issue_ids = {}
    issues.each { |issue| displayed_issue_ids[issue.id] = true }

    descendant_issues ||= gantt_all_descendants_for(issues)
    descendants_by_ancestor_id = Array(descendant_issues).group_by(&:ancestor_id)
    discarded_status_ids = Array(IssueStatus.discarded_ids)

    issues.each_with_object({}) do |issue, overrun_due_dates|
      next if displayed_issue_ids[issue.parent_id]
      next unless issue.due_date.present?
      next if issue.leaf?

      max_due_date = Array(descendants_by_ancestor_id[issue.id])
                       .reject { |child|
                         child.due_date.nil? ||
                           discarded_status_ids.include?(child.status_id) ||
                           Tracker.is_exception?(child.tracker_id) ||
                           Tracker.is_bug?(child.tracker_id) ||
                           Tracker.is_sidejob?(child.tracker_id)
                       }
                       .map(&:due_date)
                       .max

      overrun_due_dates[issue.id] = max_due_date if max_due_date && max_due_date > issue.due_date
    end
  end

  # 간트 차트 날짜 범위 계산
  def gantt_date_range(issues, gantt_opts, due_date, extra_dates = [])
    before_length = gantt_opts[:before_length] || 20.days
    after_length = gantt_opts[:after_length] || 30.days

    extra_dates = Array(extra_dates).compact
    min_dates = issues.map { |issue| [issue.start_date, issue.begin_time&.to_date] }.flatten.compact
    min_date = (min_dates + extra_dates).compact.min
    before_length = [ (min_date ? (Date.today - min_date).days + 1.days : 15.days), 15.days ].max unless gantt_opts[:before_length]

    max_dates = issues.map { |issue| [issue.due_date, issue.end_time&.to_date] }.flatten.compact
    max_dates.concat(issues.filter_map { |issue| issue.start_date if issue.due_date.nil? })
    max_dates.concat(issues.filter_map { |issue| Date.today if issue.begin_time.present? && issue.end_time.nil? })
    max_dates.concat(extra_dates)
    max_date = max_dates.max
    after_length = [ (max_date ? (max_date - Date.today).days + 5.days : 5.days), 5.days ].max unless gantt_opts[:after_length]
    after_length = [ after_length, (due_date - Date.today).days + 5.days ].max if due_date

    if due_date.present? && !gantt_opts[:before_length] && !gantt_opts[:after_length]
      stale_date_range = gantt_stale_due_date_range(min_dates, max_dates, due_date, gantt_opts)
    end

    if stale_date_range
      start_date = stale_date_range[:start_date]
      end_date = stale_date_range[:end_date]
    else
      start_date = Date.today - before_length
      end_date = Date.today + after_length
    end

    today_index = (Date.today - start_date).to_i
    due_date_index = due_date ? (due_date - start_date).to_i + 1 : nil
    total_days = (end_date - start_date).to_i

    {
      start_date: start_date,
      end_date: end_date,
      today_index: today_index,
      due_date_index: due_date_index,
      total_days: total_days
    }
  end

  def gantt_stale_due_date_range(min_dates, max_dates, due_date, gantt_opts = {})
    stale_due_after_length = gantt_opts.fetch(:stale_due_after_length, 15.days)
    return nil if stale_due_after_length == false

    due_cap_date = due_date + stale_due_after_length
    return nil if due_cap_date >= Date.today

    all_dates = (Array(min_dates) + Array(max_dates) + [due_date]).compact
    min_date = all_dates.min || due_date
    max_date = all_dates.max || due_date

    end_date = if max_date > due_cap_date
                 max_date + 5.days
               else
                 due_cap_date
               end

    {
      start_date: [min_date - 1.day, end_date].min,
      end_date: end_date
    }
  end

  def gantt_schedule_required?(issue)
    !Tracker.is_exception?(issue.tracker_id) &&
      !Tracker.is_sidejob?(issue.tracker_id) &&
      !IssueStatus.is_implemented?(issue.status_id) &&
      !IssueStatus.is_discarded?(issue.status_id) &&
      !IssueStatus.is_postponed?(issue.status_id)
  end

  def gantt_missing_due_date?(issue)
    issue.due_date.nil?
  end

  def gantt_schedule_line_css_classes(issue, virtual_ids = [])
    return 'virtual' if Array(virtual_ids).include?(issue.id)
    return 'planning' if Tracker.respond_to?(:is_planning?) && Tracker.is_planning?(issue.tracker_id)

    ''
  end

  def gantt_schedule_line_edge_css_classes(planning_segments, line_start_date, visible_line_end_date)
    return '' unless line_start_date.present? && visible_line_end_date.present?

    visible_segments = Array(planning_segments).filter_map do |segment|
      segment_start = [segment[:start_date], line_start_date].compact.max
      segment_end = [segment[:due_date], visible_line_end_date].compact.min
      next unless segment_start.present? && segment_end.present?
      next if segment_start > segment_end

      {
        start_date: segment_start,
        due_date: segment_end
      }
    end

    classes = []
    classes << 'planning-before' if visible_segments.any? { |segment| segment[:start_date] == line_start_date }
    classes << 'planning-after' if visible_segments.any? { |segment| segment[:due_date] == visible_line_end_date }
    classes.join(' ')
  end

  def gantt_delayed_schedule_segment(issue, line_start_date, visible_line_end_date)
    return nil unless issue.respond_to?(:first_due_date)
    return nil unless issue.first_due_date.present? && issue.due_date.present?
    return nil unless issue.due_date.to_date > issue.first_due_date.to_date
    return nil unless line_start_date.present? && visible_line_end_date.present?

    segment_start = [issue.first_due_date.to_date + 1.day, line_start_date].max
    segment_end = [issue.due_date.to_date, visible_line_end_date].min
    return nil if segment_start > segment_end

    {
      start_date: segment_start,
      due_date: segment_end
    }
  end

  def gantt_parent_planning_segments_map(issues, descendant_issues = nil)
    issue_list = Array(issues)
    displayed_issue_ids = issue_list.map(&:id).compact
    return {} if displayed_issue_ids.empty?

    descendant_issues ||= gantt_visible_descendants_for(issues)
    displayed_issue_id_set = displayed_issue_ids.to_set
    issues_by_id = issue_list.index_by(&:id)
    descendants_by_ancestor_id = Array(descendant_issues).group_by do |descendant|
      descendant.respond_to?(:ancestor_id) ? descendant.ancestor_id : descendant.parent_id
    end

    displayed_issue_ids.each_with_object({}) do |issue_id, segments_map|
      next if displayed_issue_id_set.include?(issues_by_id[issue_id]&.parent_id)

      segments = Array(descendants_by_ancestor_id[issue_id]).filter_map do |descendant|
        next unless Tracker.respond_to?(:is_planning?) && Tracker.is_planning?(descendant.tracker_id)

        segment_start = descendant.start_date || descendant.due_date
        segment_end = descendant.due_date || descendant.start_date
        next unless segment_start.present? && segment_end.present?

        if segment_end < segment_start
          segment_start, segment_end = segment_end, segment_start
        end

        {
          start_date: segment_start,
          due_date: segment_end
        }
      end

      merged_segments = gantt_merge_date_segments(segments)
      segments_map[issue_id] = merged_segments if merged_segments.any?
    end
  end

  def gantt_planning_line_bounds(planning_segments, chart_start_date, chart_end_date)
    visible_segments = Array(planning_segments).filter_map do |segment|
      segment_start = segment[:start_date]
      segment_end = segment[:due_date]
      next unless segment_start.present? && segment_end.present?

      visible_start = [segment_start, chart_start_date].max
      visible_end = [segment_end, chart_end_date].min
      next if visible_start > visible_end

      {
        start_date: visible_start,
        due_date: visible_end
      }
    end
    return nil if visible_segments.empty?

    {
      start_date: visible_segments.map { |segment| segment[:start_date] }.min,
      due_date: visible_segments.map { |segment| segment[:due_date] }.max
    }
  end

  # 표시 중인 이슈들의 모든 하위 일감을 (descendant, ancestor) 쌍으로 단일 쿼리 조회.
  # 간트 차트의 overrun/planning/warning 계산이 이 결과 하나를 공유한다.
  def gantt_all_descendants_for(issues)
    displayed_issue_ids = Array(issues).map(&:id).compact
    return [] if displayed_issue_ids.empty?
    return [] unless Array(issues).all? { |issue| issue.is_a?(Issue) }

    Issue.visible
         .joins(
           "JOIN #{Issue.table_name} ancestors" \
           " ON ancestors.root_id = #{Issue.table_name}.root_id" \
           " AND ancestors.lft <= #{Issue.table_name}.lft" \
           " AND ancestors.rgt >= #{Issue.table_name}.rgt"
         )
         .where(ancestors: { id: displayed_issue_ids })
         .where.not("#{Issue.table_name}.id = ancestors.id")
         .select(
           "#{Issue.table_name}.id",
           "#{Issue.table_name}.parent_id",
           "#{Issue.table_name}.subject",
           "#{Issue.table_name}.tracker_id",
           "#{Issue.table_name}.status_id",
           "#{Issue.table_name}.start_date",
           "#{Issue.table_name}.due_date",
           "ancestors.id AS ancestor_id"
         )
         .to_a
  end

  def gantt_visible_descendants_for(issues, all_descendants = nil)
    displayed_issue_ids = Array(issues).map(&:id).compact
    return [] if displayed_issue_ids.empty?

    in_list_descendants = Array(issues).select do |issue|
      issue.parent_id.present? && displayed_issue_ids.include?(issue.parent_id)
    end
    if in_list_descendants.any?
      return in_list_descendants.map do |issue|
        issue.dup.tap do |descendant|
          descendant.ancestor_id = issue.parent_id if descendant.respond_to?(:ancestor_id=)
        end
      end
    end

    all_descendants || gantt_all_descendants_for(issues)
  end

  def gantt_merge_date_segments(segments)
    return [] if segments.blank?

    sorted_segments = segments.sort_by { |segment| [segment[:start_date], segment[:due_date]] }

    sorted_segments.each_with_object([]) do |segment, merged_segments|
      if merged_segments.empty? || segment[:start_date] > merged_segments.last[:due_date] + 1.day
        merged_segments << segment.dup
      else
        merged_segments.last[:due_date] = [merged_segments.last[:due_date], segment[:due_date]].max
      end
    end
  end

  def gantt_child_schedule_warning_map(issues, descendant_issues = nil)
    gantt_child_schedule_warning_details_map(issues, descendant_issues).transform_values { true }
  end

  def gantt_child_schedule_warning_details_map(issues, descendant_issues = nil)
    displayed_issue_ids = issues.map(&:id)
    return {} if displayed_issue_ids.empty?

    descendant_issues ||= gantt_all_descendants_for(issues)

    descendant_issues.each_with_object({}) do |descendant, warning_details_map|
      next unless gantt_schedule_required?(descendant)
      next unless gantt_missing_due_date?(descendant)

      warning_details_map[descendant.ancestor_id] ||= []
      warning_details_map[descendant.ancestor_id] << {
        id: descendant.id,
        subject: descendant.respond_to?(:subject) && descendant.subject.present? ? descendant.subject : "(제목 없음)",
        reason: "완료기한 미기입"
      }
    end
  end

  # 일별 통계에서 버그 추이 데이터(오늘 잔여 기준 역산 + 날짜 유형) 생성.
  # dashboard와 report(bugs)가 같은 로직을 공유한다. 공휴일은 일괄 조회.
  def milestone_bug_trend_data(issues_by_days, rest_issue_count_per_category)
    days = Array(issues_by_days).map { |day_data| day_data[:day] }
    holidays = {}
    if days.any? && defined?(TxBaseHelper::HolidayApi) && TxBaseHelper::HolidayApi.available?
      holidays = TxBaseHelper::HolidayApi.for_date_range(days.min, days.max)
    end

    bug_data = []
    remaining_bugs = (rest_issue_count_per_category || {})['BUG'] || 0
    Array(issues_by_days).each do |day_data|
      bug_category = day_data[:issues_by_category]['BUG']
      created = bug_category ? bug_category[:created] : 0
      completed = bug_category ? bug_category[:completed] : 0
      date = day_data[:day]
      date_type = if holidays[date]
                    'holiday'
                  elsif date.sunday?
                    'sunday'
                  elsif date.saturday?
                    'saturday'
                  else
                    'weekday'
                  end

      bug_data << { date: date.strftime('%m-%d'), created: created, completed: completed, remaining: remaining_bugs, date_type: date_type }
      # 한 단계 과거로 이동: 오늘 기준 잔여에서 (그 날 해결 수)를 더하고 (그 날 생성 수)를 뺌
      remaining_bugs = remaining_bugs + completed - created
    end
    bug_data.reverse
  end

  # 간트 차트 공용 스타일/스크립트를 요청당 한 번만 포함
  def gantt_chart_assets
    return ''.html_safe if @gantt_chart_assets_included

    @gantt_chart_assets_included = true
    safe_join([
      render(partial: 'milestone/gantt_style'),
      javascript_include_tag('tx_milestone_gantt_chart', plugin: 'redmine_tx_milestone')
    ])
  end

  # 담당자 링크 렌더링 결과를 요청 내에서 캐싱
  def cached_link_to_principal(principal, options = {})
    @cached_principals ||= {}
    principal_id = principal.is_a?(Principal) ? principal.id : principal

    unless @cached_principals.key?(principal_id)
      if principal.is_a?(Principal)
        @cached_principals[principal_id] = link_to_principal(principal, options)
      else
        principal_obj = Principal.find_by(id: principal_id)
        @cached_principals[principal_id] = principal_obj ? link_to_principal(principal_obj, options) : principal_id.to_s
      end
    end

    @cached_principals[principal_id]
  end

  # 간트 차트용 이슈 배열 생성
  def gantt_prepare_issues(issues, depth_map, descendant_issues = nil)
    child_schedule_warning_details_map = gantt_child_schedule_warning_details_map(issues, descendant_issues)

    issues.map do |issue|
      show_no_due_date_warning = issue.due_date.nil? && !Tracker.is_exception?(issue.tracker_id) && !IssueStatus.is_implemented?(issue.status_id)
      missing_child_schedule_warning_details = child_schedule_warning_details_map[issue.id] || []
      {
        issue: issue,
        depth: depth_map[issue.id] || 0,
        show_no_due_date_warning: show_no_due_date_warning,
        show_missing_child_schedule_warning: missing_child_schedule_warning_details.any?,
        missing_child_schedule_warning_details: missing_child_schedule_warning_details
      }
    end
  end

  module_function :milestone_major_issues, :milestone_review_issues,
                  :milestone_bug_trend_data,
                  :get_version_color, :build_issue_query, :render_issues,
                  :build_bug_issues_filter_params, :link_to_issue_with_id, :link_to_bug_issues_count,
                  :gantt_issue_css_class,
                  :gantt_status_periods, :gantt_status_period_groups, :gantt_status_periods_from_transitions,
                  :gantt_paused_periods, :gantt_bar_period_segment, :gantt_depth_map,
                  :gantt_top_level_overrun_due_dates, :gantt_date_range,
                  :gantt_stale_due_date_range,
                  :gantt_schedule_required?, :gantt_missing_due_date?,
                  :gantt_schedule_line_css_classes, :gantt_schedule_line_edge_css_classes,
                  :gantt_delayed_schedule_segment,
                  :gantt_parent_planning_segments_map,
                  :gantt_planning_line_bounds,
                  :gantt_all_descendants_for,
                  :gantt_visible_descendants_for,
                  :gantt_merge_date_segments,
                  :gantt_child_schedule_warning_map, :gantt_child_schedule_warning_details_map,
                  :gantt_prepare_issues

  class RedmineTxMilestoneHook < Redmine::Hook::ViewListener
    def view_issues_show_description_bottom(context = {})
      issue = context[:issue]
      return ''.html_safe unless RedmineTxMilestoneHelper.issue_detail_schedule_summary_enabled?(issue)
      return ''.html_safe unless User.current.allowed_to?(:view_milestone, issue.root.project)

      view = context[:controller]&.view_context
      return ''.html_safe unless view

      view.render(
        partial: 'issues/tx_milestone_schedule_summary',
        locals: { issue: issue }
      )
    rescue StandardError => e
      Rails.logger.error "[RedmineTxMilestone] issue detail schedule summary render failed: #{e.message}\n#{Array(e.backtrace).first(5).join("\n")}"
      ''.html_safe
    end

    # 이슈 페이지 action menu에 로드맵 및 일정요약 링크 추가
    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]
      project = context[:project]
      view = context[:controller].view_context
      is_roadmap_tracker = Tracker.is_in_roadmap?(issue.root.tracker_id)

      roadmap_url = "/projects/#{project.identifier}/milestone/gantt/issues/#{issue.root.id}"
      schedule_url = "/projects/#{project.identifier}/milestone/schedule_summary?issue_ids=#{issue.root.id}"

      # Rails asset pipeline을 사용해서 올바른 아이콘 경로 생성
      icons_path = view.asset_path('icons.svg')

      <<~HTML.html_safe
        <script>
          $(function() {
            // div.main -> div.content -> div.contextual 구조를 찾아야 함
            var $ctx = $('div.main div.content div.contextual').first();

            // 더 정확한 선택자로 시도
            if ($ctx.length === 0) {
              $ctx = $('#main .content div.contextual').first();
            }

            // 마지막 fallback: action menu처럼 보이는 contextual div 찾기
            if ($ctx.length === 0) {
              $('div.contextual').each(function() {
                var $this = $(this);
                var html = $this.html();
                if (html.indexOf('edit') !== -1 || html.indexOf('시간') !== -1 || html.indexOf('time-add') !== -1 ||
                    html.indexOf('icon-edit') !== -1 || html.indexOf('icon-time') !== -1 ||
                    html.indexOf('showAndScrollTo') !== -1 || html.indexOf('btn') !== -1 ||
                    html.indexOf('sprite_icon') !== -1) {
                  $ctx = $this;
                  return false; // break
                }
              });
            }

            if ($ctx.length > 0) {
              var linksHtml = '';

              // 로드맵 트래커인 경우 로드맵 링크 추가
              if (#{is_roadmap_tracker} && !$ctx.find('#milestone-roadmap-link').length) {
                linksHtml += ' <a href="#{roadmap_url}" class="icon icon-projects" title="로드맵 보기" target="_blank">' +
                             '<svg class="s18 icon-svg" aria-hidden="true"><use href="#{icons_path}#icon--projects"></use></svg>' +
                             '<span class="icon-label">간트</span></a>';
              }

              // 일정요약 링크 추가 (항상 표시)
              if (!$ctx.find('#milestone-schedule-link').length) {
                linksHtml += ' <a href="#{schedule_url}" class="icon icon-stats" title="일정요약 보기" target="_blank">' +
                             '<svg class="s18 icon-svg" aria-hidden="true"><use href="#{icons_path}#icon--stats"></use></svg>' +
                             '<span class="icon-label">일정요약</span></a>';
              }

              // 모든 링크를 한번에 추가
              if (linksHtml) {
                $ctx.prepend(linksHtml);
              }
            }
          });
        </script>
      HTML
    end
  end

  module VersionPatch
    def marks
      return [] unless effective_date
      date_marks = []
      settings = Setting[:plugin_redmine_tx_milestone]
      deadlines = RedmineTxMilestone::SettingsMigration.get_deadlines(settings)
      dev_complete_index = (settings['setting_milestone_dev_complete_index'] || '0').to_i
      deadlines.each_with_index do |deadline, idx|
        days = deadline['days']
        title = deadline['title']
        next if days.blank?

        date = (effective_date - days.to_i.days).to_date
        date_marks.push({ date: date, name: title, is_deadline: idx == dev_complete_index })
      end

      # 데이터 타입이 날짜 타입인 커스텀 필드가 있으면 해당 값도 추가
      self.custom_field_values.each do |custom_field_value|
        if custom_field_value.custom_field.field_format == 'date' && custom_field_value.value.present?
          existing = date_marks.find { |dm| dm[:name] == custom_field_value.custom_field.name }
          date_marks.delete_if { |dm| dm[:name] == custom_field_value.custom_field.name }
          date_marks.push({
            date: custom_field_value.value.to_date,
            name: custom_field_value.custom_field.name,
            is_deadline: existing ? existing[:is_deadline] : false
          })
        end
      end

      date_marks
    end

    def mark_date( mark_name )
      marks.each do |mark|
        if mark[:name] == mark_name
          return mark[:date]
        end
      end
      nil
    end
    
  end

  

  

end
