module RedmineTxMilestoneHelper
  # TxBaseHelper의 일감 테이블 헬퍼 메서드 사용
  include TxBaseHelper

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
    if IssueStatus.is_postponed?(issue.status_id)
      'issue-postponed'
    elsif IssueStatus.is_discarded?(issue.status_id)
      'issue-discarded'
    elsif IssueStatus.is_implemented?(issue.status_id)
      'issue-implemented'
    elsif IssueStatus.is_in_progress?(issue.status_id)
      'issue-in-progress'
    else
      if issue.due_date && issue.due_date < Date.today
        'issue-overdue'
      else
        'issue-default'
      end
    end
  end

  # paused 구간 배치 쿼리 (N+1 방지)
  def gantt_paused_periods(issues)
    paused_periods_map = {}
    paused_status_ids = IssueStatus.paused_ids.map(&:to_s)
    if paused_status_ids.any?
      paused_transitions = JournalDetail.joins(:journal)
        .where(journals: { journalized_type: 'Issue', journalized_id: issues.map(&:id) })
        .where(property: 'attr', prop_key: 'status_id')
        .where("journal_details.old_value IN (?) OR journal_details.value IN (?)", paused_status_ids, paused_status_ids)
        .select('journals.journalized_id AS issue_id, journals.created_on, journal_details.old_value, journal_details.value')
        .order('journals.journalized_id, journals.created_on')

      paused_transitions.group_by(&:issue_id).each do |issue_id, trans|
        periods = []
        trans.each do |t|
          if paused_status_ids.include?(t.value.to_s)
            periods << { entered_at: t.created_on.to_date, exited_at: nil }
          elsif paused_status_ids.include?(t.old_value.to_s) && periods.last && periods.last[:exited_at].nil?
            periods.last[:exited_at] = t.created_on.to_date
          end
        end
        paused_periods_map[issue_id] = periods if periods.any?
      end
    end
    paused_periods_map
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

  # 간트 차트 날짜 범위 계산
  def gantt_date_range(issues, gantt_opts, due_date)
    before_length = gantt_opts[:before_length] || 20.days
    after_length = gantt_opts[:after_length] || 30.days

    min_date = issues.map { |issue| [issue.start_date, issue.begin_time&.to_date] }.flatten.compact.min
    before_length = [ (min_date ? (Date.today - min_date).days + 1.days : 15.days), 15.days ].max unless gantt_opts[:before_length]

    max_date = issues.map { |issue| [issue.due_date, issue.end_time&.to_date] }.flatten.compact.max
    after_length = [ (max_date ? (max_date - Date.today).days + 5.days : 5.days), 5.days ].max unless gantt_opts[:after_length]
    after_length = [ after_length, (due_date - Date.today).days + 5.days ].max if due_date

    start_date = Date.today - before_length
    end_date = Date.today + after_length
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

  # 간트 차트용 이슈 배열 생성
  def gantt_prepare_issues(issues, depth_map)
    issues.map do |issue|
      show_no_due_date_warning = issue.due_date.nil? && !Tracker.is_exception?(issue.tracker_id) && !IssueStatus.is_implemented?(issue.status_id)
      {
        issue: issue,
        depth: depth_map[issue.id] || 0,
        show_no_due_date_warning: show_no_due_date_warning
      }
    end
  end

  module_function :get_version_color, :build_issue_query, :render_issues,
                  :build_bug_issues_filter_params, :link_to_issue_with_id, :link_to_bug_issues_count,
                  :gantt_issue_css_class, :gantt_paused_periods, :gantt_depth_map,
                  :gantt_date_range, :gantt_prepare_issues

  class RedmineTxMilestoneHook < Redmine::Hook::ViewListener
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
                             '<span class="icon-label">로드맵</span></a>';
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
      deadlines = RedmineTxMilestone::SettingsMigration.get_deadlines(
        Setting[:plugin_redmine_tx_milestone]
      )
      deadlines.each do |deadline|
        days = deadline['days']
        title = deadline['title']
        next if days.blank?

        date = (effective_date - days.to_i.days).to_date
        date_marks.push({ date: date, name: title })
      end

      # 데이터 타입이 날짜 타입인 커스텀 필드가 있으면 해당 값도 추가
      self.custom_field_values.each do |custom_field_value|
        if custom_field_value.custom_field.field_format == 'date' && custom_field_value.value.present?
          date_marks.delete_if { |dm| dm[:name] == custom_field_value.custom_field.name }
          date_marks.push({ 
            date: custom_field_value.value.to_date, 
            name: custom_field_value.custom_field.name 
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