require 'set'

class MilestoneController < ApplicationController
  include SortHelper
  include QueriesHelper
  include IssuesHelper
  helper :issues
  helper :queries
  helper :sort
  helper :redmine_tx_milestone

  menu_item :redmine_tx_milestone
    
    layout 'base'  # 기본 Redmine 레이아웃 사용
    # layout 'admin'  # 관리자 레이아웃을 사용하려면
    # layout 'milestone'  # 커스텀 레이아웃을 만들어서 사용하려면
    # layout false  # 레이아웃 없이 사용하려면
  
    before_action :require_login
    before_action :find_project, except: [:issue_detail, :predict_issue, :apply_predict_issue, :test_summary_prompt]
    before_action :authorize, except: [:issue_detail, :predict_issue, :apply_predict_issue, :test_summary_prompt]
    before_action :find_issue_for_predict, only: [:predict_issue, :apply_predict_issue]
  
    def index
      # force 파라미터가 있으면 캐시를 클리어합니다
      #Rails.cache.delete('user_status_users') if params[:force].present?
      
    end

    def dashboard
      version_id_param = params[:version_id]
      @selected_version_id = if version_id_param.present? && version_id_param != 'all'
                               version_id_param.to_i
                             else
                               @project&.default_version&.id
                             end

      if @selected_version_id
        skip_cache = Rails.env.development?
        cache_base = "milestone/dashboard/#{@project.id}/#{@selected_version_id}/#{Date.today}"
        force = params[:force] == 'true' || skip_cache

        if force
          Rails.cache.delete("#{cache_base}/overview")
          Rails.cache.delete("#{cache_base}/bugs")
        end

        @overview = Rails.cache.fetch("#{cache_base}/overview", expires_in: skip_cache ? 0 : 1.hour) do
          RedmineTxMilestone::SummaryService.dashboard_overview(@selected_version_id)
        end

        @issues_by_days, @rest_issue_count_per_category, @rest_bug_issues, _, @all_bug_issues, _ =
          Rails.cache.fetch("#{cache_base}/bugs", expires_in: skip_cache ? 0 : 1.hour) do
            process_bugs_data(Date.today, @selected_version_id)
          end

        # AI 현황 요약 — overview+bug 데이터 해시 기반 캐시
        if @overview && !@overview[:error] && defined?(RedmineTxMcp::LlmService) && RedmineTxMcp::LlmService.available?
          bug_data = build_bug_data_for_ai(@overview, @selected_version_id)
          mcp_settings = Setting.plugin_redmine_tx_mcp rescue {}
          llm_provider = mcp_settings['llm_provider'] || 'anthropic'
          llm_model = llm_provider == 'openai' ? (mcp_settings['openai_model'].presence || 'default') : (mcp_settings['claude_model'].presence || 'claude-sonnet-4-6')
          custom_prompt = (Setting.plugin_redmine_tx_milestone rescue {}).slice('use_custom_summary_prompt', 'custom_summary_prompt').to_json
          digest_source = @overview.to_json + (bug_data ? bug_data.to_json : '') + custom_prompt + "#{llm_provider}:#{llm_model}"
          overview_digest = Digest::SHA256.hexdigest(digest_source)[0..15]
          ai_cache_key = "milestone/ai_summary/#{@project.id}/#{@selected_version_id}/#{overview_digest}"
          Rails.cache.delete(ai_cache_key) if params[:force] == 'true'
          @ai_summary = Rails.cache.fetch(ai_cache_key, expires_in: 1.day, skip_nil: true) do
            result = RedmineTxMcp::LlmService.summarize(build_ai_summary_prompt(@overview, bug_data: bug_data))
            result.present? ? result : nil
          end
        end
      end
    end

    def gantt
    end

    def predict_issue
      render partial: 'milestone/predict_issue', layout: false
    end

    # 예측 간트 결과를 그대로 저장 (AJAX)
    def apply_predict_issue
      begin
        issue_info = RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_parent_schedule(@issue.id)

        # 자식 일감 중 일정이 확정되지 않은 일감 ID 목록 (뷰의 로직과 동일)
        descendant_ids = @issue.descendants.pluck(:id)
        other_issue_ids = issue_info[:other_issues].map(&:id)
        issue_ids = descendant_ids & other_issue_ids

        # 자동 재배치
        result_issues = RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.auto_schedule_issues(
          issue_info[:all_issues],
          issue_ids
        )

        saved_count = 0
        result_issues.each do |ri|
          issue = Issue.find(ri.id)
          issue.start_date = ri.start_date
          issue.due_date = ri.due_date
          saved_count += 1 if issue.save
        end

        # 최상위 부모 일감의 완료일을 자식 중 가장 늦은 날짜로 업데이트
        top_issue = @issue
        while top_issue.parent.present?
          top_issue = top_issue.parent
        end
        latest_due_date = top_issue.self_and_descendants.map(&:due_date).compact.max
        if latest_due_date.present? && (top_issue.due_date.nil? || top_issue.due_date < latest_due_date)
          top_issue.due_date = latest_due_date
          top_issue.save
        end

        render json: {
          success: true,
          message: "#{saved_count}개 일감의 일정이 확정되었습니다.",
          saved_count: saved_count
        }
      rescue => e
        render json: {
          success: false,
          message: "일정 저장 중 오류가 발생했습니다: #{e.message}"
        }, status: :internal_server_error
      end
    end

    def group_detail
    end

    def validate
    end

    def report
      today = Date.today
      report_type = params[:report_type]
      # version_id가 'all'이면 버전 필터 제거, 없으면 프로젝트의 기본 버전을 사용
      version_id_param = params[:version_id]
      version_id = if version_id_param == 'all'
                     nil
                   else
                     (version_id_param.presence || @project&.default_version&.id)
                   end
      
      # 캐시 키에 report_type 포함
      cache_key = "_milestone_report_#{@project.id}_#{version_id}_#{today.strftime('%Y-%m-%d_%H-%M')}_#{report_type}"
      expires_in = if Rails.env.development?
                     1.second
                   else
                     5.minutes
                   end

      case report_type
      when 'issues'
        @issues_by_days, @avarage_hours_per_category, @rest_issue_count_per_category, @updated_at = Rails.cache.fetch(cache_key, expires_in: expires_in) do
          process_issues_data(today, version_id)
        end
      when 'bugs'
        @issues_by_days, @rest_issue_count_per_category, @rest_bug_issues, @rest_bug_count_per_category, @all_bug_issues, @updated_at = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
          process_bugs_data(today, version_id)
        end
      else
        # 웰컴 페이지는 기본 통계만
        @basic_stats, @updated_at = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do
          process_welcome_data(today, version_id)
        end
      end
    end

    def tetris

      # 아직 대상 지정이 안된 상태면 그룹별 사용자 목록 정보를 리턴해 줘서 대상을 선택 할 수 있도록 해 주자
      unless params[:user_id].present? || params[:parent_issue_id].present? then
        @groups = group_infos()
        return
      end

      # assign_from_date : 이 날짜 이후로만 일정 배치 가능하도록 한다. 디폴트는 오늘.
      assign_from_date = params[:assign_from_date] ? Date.parse(params[:assign_from_date]) : Date.today

      # 일감 정보 조회 및 분석 (한 번에 처리)
      @issues_info = if params[:user_id].present?
                       RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_user_schedule(params[:user_id])
                     elsif params[:parent_issue_id].present?
                       RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_parent_schedule(params[:parent_issue_id])
                     else
                       { all_issues: [], fixed_issues: [], other_issues: [], candidate_issues: [], no_estimated_hours_issues: [] }
                     end

      # 일정 자동 배치 (저장은 되지 않음)
      if params[:auto_schedule] == 'true' && params[:issue_ids].present?
        
        # 자동 재배치 - @issues_info[:all_issues] 사용
        @result_issues = RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.auto_schedule_issues( 
          @issues_info[:all_issues], 
          params[:issue_ids].split(',').map(&:to_i), 
          assign_from_date 
        )

        flash[:notice] = "#{@result_issues.count}개 일감의 일정을 아래와 같이 제안 합니다.<br>저장하시려면 위 일정으로 확정 버튼을 클릭해 주세요.".html_safe
        
      # 요청된 일감 일정 정보대로 반영
      elsif params[:save_schedule] == 'true' && params[:issue_data].present?
        begin
          issue_data = JSON.parse(params[:issue_data])
          saved_count = 0

          issue_data.each do |data|
            issue = Issue.find(data['id'])
            issue.start_date = Date.parse(data['start_date'])
            issue.due_date = Date.parse(data['due_date'])
            
            if issue.save
              saved_count += 1
            end
          end
          
          flash[:notice] = "#{saved_count}개 일감의 일정이 확정되었습니다."
          redirect_to tetris_project_milestone_index_path(@project, user_id: params[:user_id], parent_issue_id: params[:parent_issue_id])
          return
        rescue => e
          flash[:error] = "일정 저장 중 오류가 발생했습니다: #{e.message}"
        end
      end
    end

    def sync_parent_date
    end

    def api_sync_parent_date
      begin
        if params[:ids].present?
          updated_count = 0
          issues = Issue.where(id: params[:ids])

          issues.each do |issue|
            # 자식 일감들의 최대 완료일을 조회
            max_child_due = issue.descendants
                                .where.not(due_date: nil)
                                .maximum(:due_date)

            next unless max_child_due.present?
            next unless issue.due_date.nil? || issue.due_date < max_child_due

            # update_column으로 콜백/검증을 우회하여 직접 업데이트
            issue.update_column(:due_date, max_child_due)
            updated_count += 1
          end

          render json: {
            success: true,
            message: "#{updated_count}개 일감의 일정을 동기화했습니다."
          }
        else
          render json: {
            success: false,
            message: "동기화할 일감을 선택해주세요."
          }
        end
      rescue => e
        render json: {
          success: false,
          message: "동기화 중 오류가 발생했습니다: #{e.message}"
        }
      end
    end

    def test_summary_prompt
      return render json: { success: false, error: '관리자 권한이 필요합니다.' } unless User.current.admin?

      unless defined?(RedmineTxMcp::LlmService) && RedmineTxMcp::LlmService.available?
        return render json: { success: false, error: 'LLM 서비스를 사용할 수 없습니다. MCP 플러그인의 API 키를 확인해 주세요.' }
      end

      # 버전 찾기: 지정된 version_id 또는 일감 많은 프로젝트의 기본 버전
      if params[:version_id].present?
        version = Version.find_by(id: params[:version_id])
        return render json: { success: false, error: '버전을 찾을 수 없습니다.' } unless version
        project = version.project
      else
        project = Project.visible.has_module(:issue_tracking)
                    .left_joins(:issues)
                    .group('projects.id')
                    .order('COUNT(issues.id) DESC')
                    .first
        return render json: { success: false, error: '프로젝트를 찾을 수 없습니다.' } unless project

        version = project.default_version || project.versions.open.order(effective_date: :desc).first
        return render json: { success: false, error: "프로젝트 '#{project.name}'에 열린 버전이 없습니다." } unless version
      end

      overview = RedmineTxMilestone::SummaryService.dashboard_overview(version.id)
      return render json: { success: false, error: overview[:error] } if overview[:error]

      # 폼에서 전달된 프롬프트로 임시 설정 오버라이드
      test_prompt = params[:prompt].presence
      if test_prompt
        original = Setting.plugin_redmine_tx_milestone
        Setting.plugin_redmine_tx_milestone = original.merge(
          'use_custom_summary_prompt' => 'true',
          'custom_summary_prompt' => test_prompt
        )
      end

      full_prompt = build_ai_summary_prompt(overview, bug_data: nil)
      result = RedmineTxMcp::LlmService.summarize(full_prompt)

      render json: if result
                     { success: true, summary: result, project: project.name, version: version.name }
                   else
                     { success: false, error: 'LLM 응답을 받지 못했습니다.' }
                   end
    ensure
      # 설정 복원
      Setting.plugin_redmine_tx_milestone = original if original
    end

    private

    # 릴리즈 15일 이내일 때 버그 추이 데이터 수집
    def build_bug_data_for_ai(overview, version_id)
      due_date_str = overview[:version][:due_date]
      return nil unless due_date_str

      days_to_release = (Date.parse(due_date_str) - Date.today).to_i
      return nil unless days_to_release <= 15

      version = Version.find(version_id)
      RedmineTxMilestone::SlackDashboardNotifier.send(:build_bug_data, version.project, version_id)
    rescue => e
      Rails.logger.error "build_bug_data_for_ai error: #{e.message}"
      nil
    end

    def build_ai_summary_prompt(overview, bug_data: nil)
      v = overview[:version]
      roadmap = overview[:roadmap_issues]
      alerts = overview[:alerts]
      risk_top = overview[:assignee_risk_top]

      today = Date.today
      data_lines = []
      data_lines << "오늘: #{today}"
      data_lines << "버전: #{v[:name]}"
      data_lines << "완료율: #{v[:done_ratio].is_a?(Float) ? v[:done_ratio].round(1) : v[:done_ratio]}%"
      data_lines << "개발마감: #{v[:dev_deadline]}" if v[:dev_deadline]
      data_lines << "릴리즈: #{v[:due_date]}" if v[:due_date]
      data_lines << "전체 일감: #{v[:total_issues]}건, 로드맵: #{roadmap.size}건"

      # 마일스톤 일정 마크 (빌드 전달일, 확정일 등)
      marks = (v[:marks] || []).select { |m| m[:date].present? }
                .map { |m| { date: Date.parse(m[:date]), name: m[:name], is_deadline: m[:is_deadline] } }
                .sort_by { |m| m[:date] }
      if marks.any?
        data_lines << "\n주요 일정:"
        marks.each do |m|
          days_diff = (m[:date] - today).to_i
          status = if days_diff < 0
                     "#{days_diff.abs}일 경과"
                   elsif days_diff == 0
                     "오늘"
                   else
                     "#{days_diff}일 남음"
                   end
          data_lines << "  #{m[:date]} #{m[:name]}#{m[:is_deadline] ? ' [마감]' : ''} (#{status})"
        end
      end

      if v[:dev_deadline]
        total_past = roadmap.sum { |r| (r[:descendant_stats] || {})[:past_dev_deadline].to_i }
        data_lines << "개발마감 이후 완료 예정 일감: #{total_past}건" if total_past > 0
      end

      # 마감/릴리즈까지 잔여 작업일 및 공휴일 정보
      deadline_dates = {}
      deadline_dates['개발마감'] = Date.parse(v[:dev_deadline]) if v[:dev_deadline]
      deadline_dates['릴리즈'] = Date.parse(v[:due_date]) if v[:due_date]
      if deadline_dates.any? { |_, d| d > today }
        holidays = if TxBaseHelper::HolidayApi.available?
                     farthest = deadline_dates.values.max
                     TxBaseHelper::HolidayApi.for_date_range(today, farthest)
                   else
                     {}
                   end

        data_lines << "\n잔여 작업일:"
        deadline_dates.each do |label, target_date|
          next if target_date <= today
          calendar_days = (target_date - today).to_i
          weekends = (today...target_date).count { |d| d.saturday? || d.sunday? }
          holiday_count = holidays.count { |date, _| date > today && date < target_date && !date.saturday? && !date.sunday? }
          workdays = calendar_days - weekends - holiday_count
          data_lines << "  #{label}(#{target_date})까지: 역일 #{calendar_days}일, 작업일 #{workdays}일 (주말 #{weekends}일, 공휴일 #{holiday_count}일 제외)"
        end

        if holidays.any? { |date, _| date > today }
          upcoming = holidays.select { |date, _| date > today }.sort_by { |date, _| date }.first(5)
          holiday_names = upcoming.map { |date, info| "#{date.strftime('%-m/%-d')} #{info[:name] || info['name']}" }
          data_lines << "  예정 공휴일: #{holiday_names.join(', ')}"
        end
      end

      if alerts.present?
        grouped = alerts.group_by { |a| a[:parent_id] }
        data_lines << "\n알림 (#{grouped.size}건):"
        grouped.first(15).each do |_, alert_list|
          parts = alert_list.map do |a|
            case a[:type]
            when 'past_dev_deadline' then "마감초과 #{a[:count]}건"
            when 'overdue_descendants' then "지연 #{a[:overdue_count]}건"
            when 'no_due_date_descendants' then "일정없음 #{a[:count]}건"
            when 'not_started_descendants' then "미개시 #{a[:count]}건"
            end
          end.compact
          data_lines << "  #{alert_list.first[:subject]}: #{parts.join(', ')}"
        end
      end

      if risk_top.present?
        data_lines << "\n담당자별 리스크 Top 5:"
        risk_top.each do |r|
          next if r[:total] == 0
          data_lines << "  #{r[:name]}: 지연 #{r[:overdue]}건, 미개시 #{r[:not_started]}건"
        end
      end

      # 릴리즈 15일 이내: 버그 추이 데이터 추가
      if bug_data.present?
        recent = bug_data.last(7)
        current_remaining = bug_data.last[:remaining]
        week_created = recent.sum { |d| d[:created] }
        week_completed = recent.sum { |d| d[:completed] }
        data_lines << "\n버그 수정 추이 (릴리즈 임박):"
        data_lines << "  현재 잔여 버그: #{current_remaining}건"
        data_lines << "  최근 7일 — 생성: #{week_created}건, 해결: #{week_completed}건"
        recent.each { |d| data_lines << "  #{d[:date]}: 생성 #{d[:created]}, 해결 #{d[:completed]}, 잔여 #{d[:remaining]}" }
      end

      context = data_lines.join("\n")

      # 커스텀 프롬프트 설정 확인
      ms_settings = Setting.plugin_redmine_tx_milestone rescue {}
      if ms_settings['use_custom_summary_prompt'] == 'true' && ms_settings['custom_summary_prompt'].present?
        prompt = ms_settings['custom_summary_prompt']
      else
        total_work = roadmap.sum { |r| (r[:descendant_stats] || {})[:total].to_i }
        total_no_due = roadmap.sum { |r| (r[:descendant_stats] || {})[:no_due_date].to_i }
        no_due_ratio = total_work > 0 ? (total_no_due.to_f / total_work * 100).round(0) : 0

        requirements = ["5~10문장으로 핵심을 전달"]
        requirements << "가장 심각한 리스크나 주의사항을 먼저 언급"
        if no_due_ratio >= 30
          requirements << "일정 미배정 일감이 전체의 #{no_due_ratio}%에 달하므로, 일정 리스크 판단 자체가 어려운 상황임을 최우선으로 강조하고, 일정 배정이 선행되어야 한다는 점을 명확히 언급"
        end
        requirements << "전체적인 진행 상태에 대한 판단 포함"
        requirements << "주요 일정(빌드 전달일, 마감일 등)의 경과/잔여 상황을 고려하여 현재 시점의 위치를 판단"
        requirements << "잔여 작업일 정보가 포함된 경우, 실제 작업 가능 일수를 기반으로 일정 리스크를 판단"
        requirements << "버그 수정 추이가 포함된 경우, 릴리즈까지 버그 해소 전망도 언급" if bug_data.present?
        requirements << "마크다운 없이 평문으로 작성"
        requirements << "한국어로 작성"

        prompt = "위 프로젝트 마일스톤 현황 데이터를 바탕으로 프로젝트 매니저에게 보고하는 간결한 현황 요약을 작성해 주세요.\n\n요구사항:\n" +
          requirements.map { |r| "- #{r}" }.join("\n")
      end

      "#{context}\n\n#{prompt}"
    end

  def find_issue_for_predict
    @issue = Issue.visible.find(params[:issue_id])
  end

  # 공통으로 사용되는 기본 데이터
  def get_base_data
    categories = IssueCategory.where(project_id: @project.id).pluck(:id, :name).to_h
    tracker_ids = Tracker.where(is_sidejob: false, is_exception: false).pluck(:id)
    bug_ids = Tracker.where(is_bug: true).pluck(:id)
    discarded_ids = IssueStatus.discarded_ids
    
    {
      categories: categories,
      tracker_ids: tracker_ids,
      bug_ids: bug_ids,
      discarded_ids: discarded_ids
    }
  end

  # 일반 일감 데이터 조회
  def get_issues_data(base_data, version_id)
    all_issues = Issue.where(project_id: @project.id)
                     .where(tracker_id: base_data[:tracker_ids])
                     .where.not(status_id: base_data[:discarded_ids])
    all_issues = all_issues.where(fixed_version_id: version_id) if version_id
    
    all_completed_issues = all_issues.where.not(end_time: nil)
    issues = all_issues.where('created_on >= ? OR end_time >= ?', Date.today - 1.year, Date.today - 1.year)
    
    {
      all_issues: all_issues,
      all_completed_issues: all_completed_issues,
      issues: issues
    }
  end

  # 버그 데이터 조회
  def get_bug_data(base_data, version_id)
    all_bug_issues = Issue.where(tracker_id: base_data[:bug_ids])
                         .where.not(status_id: base_data[:discarded_ids])
    all_bug_issues = all_bug_issues.where(fixed_version_id: version_id) if version_id
    
    all_bug_completed_issues = all_bug_issues.where.not(end_time: nil)
    bug_issues = all_bug_issues.where('created_on >= ? OR end_time >= ?', Date.today - 1.year, Date.today - 1.year)
    
    {
      all_bug_issues: all_bug_issues,
      all_bug_completed_issues: all_bug_completed_issues,
      bug_issues: bug_issues
    }
  end

  # 일별 통계 계산
  def calculate_daily_stats(today, issues, bug_issues, categories, all_issues = nil, all_bug_issues = nil, include_bugs: true)
    issues_by_days = []
    
    (0..11).each do |day|
      # 기준 날짜 (N일 전)
      day_date = today - day.days

      # 각 이슈가 해당 "하루"에 한 번만 집계되도록 to_date로 비교
      created_issues = issues.select do |issue|
        issue.created_on.present? && issue.created_on.to_date == day_date
      end

      completed_issues = issues.select do |issue|
        issue.end_time.present? && issue.end_time.to_date == day_date
      end
      
      issues_by_category = {}
      
      # 일반 일감 카테고리별 집계
      categories.each do |id, category_name|
        issues_by_category[category_name] ||= { all: 0, created: 0, completed: 0 }
        # 전체 일감 개수 계산
        if all_issues
          issues_by_category[category_name][:all] = all_issues.where(category_id: id).size
        end
      end
      
      created_issues.each do |issue|
        next unless issue.category_id
        category_name = categories[issue.category_id]
        next unless category_name
        issues_by_category[category_name][:created] += 1
      end
      
      completed_issues.each do |issue|
        next unless issue.category_id
        category_name = categories[issue.category_id]
        next unless category_name
        issues_by_category[category_name][:completed] += 1
      end
      
      if include_bugs && bug_issues
        created_bug_issues = bug_issues.select do |issue|
          issue.created_on.present? && issue.created_on.to_date == day_date
        end

        completed_bug_issues = bug_issues.select do |issue|
          issue.end_time.present? && issue.end_time.to_date == day_date
        end
        
        issues_by_category['BUG'] ||= { all: 0, created: 0, completed: 0 }
        issues_by_category['BUG'][:created] += created_bug_issues.size
        issues_by_category['BUG'][:completed] += completed_bug_issues.size
        # 전체 버그 개수 계산
        if all_bug_issues
          issues_by_category['BUG'][:all] = all_bug_issues.size
        end
      end
      
      # 전체 일감 개수 계산 (all_issues가 있으면 사용, 없으면 기존 방식)
      total_all_issues = all_issues ? all_issues.size : issues.size
      
      issues_by_days.push({
        day: today - day.days,
        all: total_all_issues,
        created: created_issues.size,
        completed: completed_issues.size,
        issues_by_category: issues_by_category
      })
    end
    
    issues_by_days
  end

  # 잔여 일감 개수 계산
  def calculate_rest_issue_counts(all_issues, all_completed_issues, all_bug_issues, all_bug_completed_issues, categories, include_bugs: true)
    rest_issue_count_per_category = {}
    
    categories.each do |id, category|
      rest_issue_count_per_category[category] = all_issues.where(category_id: id).size - all_completed_issues.where(category_id: id).size
    end
    
    if include_bugs
      rest_issue_count_per_category['BUG'] = all_bug_issues.size - all_bug_completed_issues.size
    end
    
    rest_issue_count_per_category
  end

  # 평균 소요 시간 계산
  def calculate_average_hours(issues, bug_issues, categories, bug_ids, include_bugs: true)
    avarage_hours_per_category = {}
    avarage_count_per_category = {}
    
    if include_bugs
      avarage_hours_per_category['BUG'] = 0
      avarage_count_per_category['BUG'] = 0
    end
    
    # issues와 bug_issues가 ActiveRecord::Relation인지 Array인지 확인하고 처리
    timed_issues = []
    
    # 일반 일감 처리
    if issues.respond_to?(:where)
      timed_issues += issues.where.not(begin_time: nil, end_time: nil).to_a
    else
      timed_issues += issues.select { |issue| issue.begin_time.present? && issue.end_time.present? }
    end
    
    # 버그 일감 처리
    if include_bugs && bug_issues
      if bug_issues.respond_to?(:where)
        timed_issues += bug_issues.where.not(begin_time: nil, end_time: nil).to_a
      else
        timed_issues += bug_issues.select { |issue| issue.begin_time.present? && issue.end_time.present? }
      end
    end
    
    timed_issues.each do |issue|
      # nil 체크 추가
      next unless issue.begin_time.present? && issue.end_time.present?
      next if issue.end_time - issue.begin_time >= 1.year
      
      if bug_ids.include?(issue.tracker_id)
        category_name = 'BUG'
      else
        next unless issue.category_id
        category_name = categories[issue.category_id]
        next unless category_name
      end
      
      avarage_hours_per_category[category_name] ||= 0
      avarage_hours_per_category[category_name] += (issue.end_time - issue.begin_time).to_i
      avarage_count_per_category[category_name] ||= 0
      avarage_count_per_category[category_name] += 1
    end
    
    avarage_hours_per_category.map do |category_name, hours|
      count = avarage_count_per_category[category_name]
      [category_name, count > 0 ? (hours / count) / 3600 : 0]
    end.to_h
  end

  # 웰컴 페이지용 기본 통계 처리
  def process_welcome_data(today, version_id)
    base_data = get_base_data
    issue_data = get_issues_data(base_data, version_id)
    bug_data = get_bug_data(base_data, version_id)
    
    [ {
      total_issues: issue_data[:all_issues].size,
      completed_issues: issue_data[:all_completed_issues].size,
      total_bugs: bug_data[:all_bug_issues].size,
      completed_bugs: bug_data[:all_bug_completed_issues].size,
      completion_rate: issue_data[:all_issues].size > 0 ? (issue_data[:all_completed_issues].size.to_f / issue_data[:all_issues].size * 100).round(2) : 0,
      bug_completion_rate: bug_data[:all_bug_issues].size > 0 ? (bug_data[:all_bug_completed_issues].size.to_f / bug_data[:all_bug_issues].size * 100).round(2) : 0      
    }, Time.current ]
  end

  # 일감 통계용 데이터 처리
  def process_issues_data(today, version_id)
    base_data = get_base_data
    issue_data = get_issues_data(base_data, version_id)
    bug_data = get_bug_data(base_data, version_id)
    
    issues_by_days = calculate_daily_stats(today, issue_data[:issues], bug_data[:bug_issues], base_data[:categories], issue_data[:all_issues], bug_data[:all_bug_issues])
    avarage_hours_per_category = calculate_average_hours(issue_data[:issues], bug_data[:bug_issues], base_data[:categories], base_data[:bug_ids])
    rest_issue_count_per_category = calculate_rest_issue_counts(
      issue_data[:all_issues], 
      issue_data[:all_completed_issues], 
      bug_data[:all_bug_issues], 
      bug_data[:all_bug_completed_issues], 
      base_data[:categories]
    )
    
    [issues_by_days, avarage_hours_per_category, rest_issue_count_per_category, Time.current]
  end

  # 버그 통계용 데이터 처리
  def process_bugs_data(today, version_id)
    base_data = get_base_data
    bug_data = get_bug_data(base_data, version_id)

    if version_id.present? && Version.find(version_id).effective_date.present?
      today = [today, Version.find(version_id).effective_date + 2.day].min
    end

    # 버그 통계용 데이터 (일반 일감 제외)
    issues_by_days = calculate_daily_stats(today, [], bug_data[:bug_issues], base_data[:categories], nil, bug_data[:all_bug_issues], include_bugs: true)
    # today 시점 기준으로 BUG 잔여 개수를 다시 계산
    bugs_until_today = bug_data[:all_bug_issues].where('created_on <= ?', today.end_of_day)
    bugs_completed_until_today = bugs_until_today.where.not(end_time: nil)
                                                 .where('end_time <= ?', today.end_of_day)

    rest_issue_count_per_category = calculate_rest_issue_counts(
      Issue.none,
      Issue.none,
      bugs_until_today,
      bugs_completed_until_today,
      base_data[:categories],
      include_bugs: true
    )
    
    # 담당자별 미해결 버그 집계
    rest_bug_issues = bug_data[:all_bug_issues].select { |issue| issue.end_time.nil? }
    rest_bug_issues = rest_bug_issues.group_by { |issue| issue.assigned_to_id }
    user_map = User.where(id: rest_bug_issues.keys).index_by(&:id)
    rest_bug_issues.transform_keys! { |key| user_map[key] }
    rest_bug_issues.transform_values! do |issues|
      issues.group_by { |issue| issue.fixed_version_id }.transform_values! { |issues| issues.size }
    end

    all_bug_issues = bug_data[:all_bug_issues]

    # 카테고리별 미해결 버그 수 (상위 10 표시용) - 카테고리 없으면 '미분류'
    rest_bug_count_per_category = begin
      counts = Hash.new(0)
      # 루프 바깥에서 필요한 카테고리 이름을 모두 로드
      bug_category_ids = bug_data[:all_bug_issues].map(&:category_id).compact.uniq
      external_categories = bug_category_ids.any? ? IssueCategory.where(id: bug_category_ids).pluck(:id, :name).to_h : {}
      categories_map = base_data[:categories].merge(external_categories)

      bug_data[:all_bug_issues].each do |issue|
        next if issue.end_time.present?
        category_name = categories_map[issue.category_id] || '미분류'
        counts[category_name] += 1
      end
      counts
    end
    
    [issues_by_days, rest_issue_count_per_category, rest_bug_issues, rest_bug_count_per_category, all_bug_issues, Time.current]
  end

    def find_project
      @user = params[:user_id] ? User.find(params[:user_id]) : User.current
      @project = Project.find(params[:project_id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end
  
    def authorize
      raise Unauthorized unless User.current.allowed_to?(:view_milestone, @project)
    end

    def group_infos
      groups = {}

      excluded_user_ids = TxBaseHelper.config_arr('e_users')
      all_users = User.active
        .where.not(id: excluded_user_ids)
        .distinct #.select{ |u| (u.group_ids & excluded_group_ids).empty? }

      excluded_group_ids = TxBaseHelper.config_arr('e_group') || []
      all_groups = Group.all.select{ |group| !excluded_group_ids.include?(group.id) }

      all_groups.each do |group|
        # @users의 순서를 유지하면서 해당 그룹의 사용자만 필터링
        groups[ group ] = { user_infos: all_users.filter_map { |user| { user: user, issue_info: RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_user_schedule( user.id ) } if group.users.map(&:id).include?(user.id) } }
      end

      groups
    end

  end
  
