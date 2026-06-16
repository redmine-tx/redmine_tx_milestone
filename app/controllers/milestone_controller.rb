require 'set'
require 'digest'

class MilestoneController < ApplicationController
  include SortHelper
  include QueriesHelper
  include IssuesHelper
  helper :issues
  helper :queries
  helper :sort
  helper :redmine_tx_milestone
  helper_method :schedule_summary_cookie_key,
                :schedule_summary_mode,
                :schedule_summary_group_ids,
                :schedule_summary_all_groups,
                :schedule_summary_groups_to_show

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
                               version = @project.shared_versions.find_by(id: version_id_param)
                               return render_404 unless version

                               version.id
                             else
                               @project&.default_version&.id
                             end

      if @selected_version_id
        skip_cache = Rails.env.development?
        # SummaryService 결과는 사용자별 가시성에 의존하므로 캐시 키에 사용자 포함
        cache_base = "milestone/dashboard/#{@project.id}/#{@selected_version_id}/#{User.current.id}/#{Date.today}"
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

      end
    end

    def gantt
      if params[:issue_id]
        @gantt_issue = Issue.visible.find(params[:issue_id])
        @gantt_issues = gantt_issue_tree(@gantt_issue)
        @gantt_due_date = @gantt_issue.fixed_version ? @gantt_issue.fixed_version.effective_date : @gantt_issue.due_date
      else
        @gantt_versions = @project.shared_versions
                                  .open
                                  .where.not(effective_date: nil)
                                  .order(:effective_date)
                                  .to_a
                                  .first(16)
        @gantt_selected_version =
          if params[:version_id].present?
            @gantt_versions.find { |v| v.id == params[:version_id].to_i } ||
              @project.shared_versions.find_by(id: params[:version_id])
          else
            @gantt_versions.find { |v| v.effective_date >= Date.today } || @gantt_versions.first
          end
        return render_404 if params[:version_id].present? && @gantt_selected_version.nil?

        @gantt_issue_groups = gantt_version_issue_groups(@gantt_selected_version)
      end
    rescue ActiveRecord::RecordNotFound
      render_404
    end

    def update_issue_schedule
      issue = Issue.visible.find(params[:issue_id])
      start_date_provided = schedule_param_present?(params, :start_date)
      due_date_provided = schedule_param_present?(params, :due_date)
      start_date = start_date_provided ? parse_schedule_date(params[:start_date]) : nil
      due_date = due_date_provided ? parse_schedule_date(params[:due_date]) : nil

      return render_404 unless issue.project == @project

      schedule_change = normalize_issue_schedule_change(
        issue,
        start_date_provided: start_date_provided,
        start_date: start_date,
        due_date_provided: due_date_provided,
        due_date: due_date
      )
      if schedule_change[:error]
        return render_schedule_error(schedule_change[:error], schedule_change[:status] || :unprocessable_entity)
      end

      start_date = schedule_change[:start_date]
      due_date = schedule_change[:due_date]

      same_schedule = issue.start_date == start_date && issue.due_date == due_date
      saved = same_schedule || RedmineTxMilestone::IssueScheduleWriteService.apply(
        issue: issue,
        start_date: start_date,
        due_date: due_date,
        user: User.current,
        note: '간트 일정 변경'
      )

      unless saved
        return render_schedule_error(issue.errors.full_messages.presence&.join(', ') || '일정 저장에 실패했습니다.')
      end

      render json: {
        success: true,
        issue_id: issue.id,
        start_date: start_date&.iso8601,
        due_date: due_date&.iso8601,
        saved: !same_schedule
      }
    rescue ActiveRecord::RecordNotFound
      render_404
    rescue => e
      Rails.logger.error "update_issue_schedule error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render_schedule_error('일정 저장 중 오류가 발생했습니다.', :internal_server_error)
    end

    def update_issue_schedules
      raw_schedules = params[:schedules]
      raw_schedules = raw_schedules.values if raw_schedules.is_a?(ActionController::Parameters)
      raw_schedules = Array(raw_schedules)

      return render_schedule_error('저장할 일정 변경이 없습니다.') if raw_schedules.blank?

      normalized_by_issue_id = {}
      raw_schedules.each do |schedule|
        issue_id_value = schedule_param_value(schedule, :issue_id) || schedule_param_value(schedule, :id)
        start_date_provided = schedule_param_present?(schedule, :start_date)
        due_date_provided = schedule_param_present?(schedule, :due_date)
        start_date = start_date_provided ? parse_schedule_date(schedule_param_value(schedule, :start_date)) : nil
        due_date = due_date_provided ? parse_schedule_date(schedule_param_value(schedule, :due_date)) : nil

        return render_schedule_error('일감 ID가 필요합니다.') if issue_id_value.blank?

        issue_id = issue_id_value.to_i
        normalized_by_issue_id[issue_id] = {
          issue_id: issue_id,
          start_date_provided: start_date_provided,
          start_date: start_date,
          due_date_provided: due_date_provided,
          due_date: due_date
        }
      end

      schedules = normalized_by_issue_id.values
      issues = Issue.visible.where(id: schedules.map { |schedule| schedule[:issue_id] }).index_by(&:id)

      schedules.each do |schedule|
        issue = issues[schedule[:issue_id]]
        return render_schedule_error('일감을 찾을 수 없습니다.', :not_found) unless issue
        return render_schedule_error('프로젝트에 속하지 않은 일감입니다.', :not_found) unless issue.project == @project

        schedule_change = normalize_issue_schedule_change(
          issue,
          start_date_provided: schedule[:start_date_provided],
          start_date: schedule[:start_date],
          due_date_provided: schedule[:due_date_provided],
          due_date: schedule[:due_date]
        )
        if schedule_change[:error]
          return render_schedule_error(schedule_change[:error], schedule_change[:status] || :unprocessable_entity)
        end

        schedule[:start_date] = schedule_change[:start_date]
        schedule[:due_date] = schedule_change[:due_date]
      end

      saved_count = 0
      results = []
      error_message = nil

      ActiveRecord::Base.transaction do
        schedules.each do |schedule|
          issue = issues[schedule[:issue_id]]
          start_date = schedule[:start_date]
          due_date = schedule[:due_date]
          same_schedule = issue.start_date == start_date && issue.due_date == due_date
          saved = same_schedule || RedmineTxMilestone::IssueScheduleWriteService.apply(
            issue: issue,
            start_date: start_date,
            due_date: due_date,
            user: User.current,
            note: '간트 일정 변경'
          )

          unless saved
            error_message = issue.errors.full_messages.presence&.join(', ') || '일정 저장에 실패했습니다.'
            raise ActiveRecord::Rollback
          end

          saved_count += 1 unless same_schedule
          results << {
            issue_id: issue.id,
            start_date: start_date&.iso8601,
            due_date: due_date&.iso8601,
            saved: !same_schedule
          }
        end
      end

      return render_schedule_error(error_message) if error_message

      render json: {
        success: true,
        schedules: results,
        saved_count: saved_count,
        message: "#{saved_count}개 일감의 일정이 저장되었습니다."
      }
    rescue => e
      Rails.logger.error "update_issue_schedules error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
      render_schedule_error('일정 저장 중 오류가 발생했습니다.', :internal_server_error)
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

        # 최상위 부모 일감의 완료일을 자식 중 가장 늦은 날짜로 업데이트
        top_issue = @issue
        while top_issue.parent.present?
          top_issue = top_issue.parent
        end

        # 저장 전에 모든 대상 일감의 편집 권한을 확인 (보이지 않거나 권한 없는 일감이 있으면 전체 거부)
        target_issues = Issue.visible.where(id: result_issues.map(&:id)).index_by(&:id)
        unauthorized = result_issues.reject do |ri|
          (issue = target_issues[ri.id]) && issue_schedule_editable?(issue)
        end
        unauthorized << top_issue unless issue_schedule_editable?(top_issue)
        if unauthorized.any?
          return render json: {
            success: false,
            message: "일정을 수정할 권한이 없는 일감이 있습니다: #{unauthorized.map { |i| "##{i.id}" }.join(', ')}"
          }, status: :forbidden
        end

        saved_count = 0
        ActiveRecord::Base.transaction do
          result_issues.each do |ri|
            saved_count += 1 if RedmineTxMilestone::IssueScheduleWriteService.apply(
              issue: target_issues[ri.id],
              start_date: ri.start_date,
              due_date: ri.due_date,
              user: User.current
            )
          end

          latest_due_date = top_issue.self_and_descendants.map(&:due_date).compact.max
          if latest_due_date.present? && (top_issue.due_date.nil? || top_issue.due_date < latest_due_date)
            RedmineTxMilestone::IssueScheduleWriteService.apply(
              issue: top_issue,
              start_date: top_issue.start_date,
              due_date: latest_due_date,
              user: User.current
            )
          end
        end

        render json: {
          success: true,
          message: "#{saved_count}개 일감의 일정이 확정되었습니다.",
          saved_count: saved_count
        }
      rescue => e
        Rails.logger.error "apply_predict_issue error: #{e.class} #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: {
          success: false,
          message: '일정 저장 중 오류가 발생했습니다.'
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
                   elsif version_id_param.present?
                     version = @project.shared_versions.find_by(id: version_id_param)
                     return render_404 unless version

                     version.id
                   else
                     @project&.default_version&.id
                   end

      # 집계가 사용자별 가시성에 의존하므로 캐시 키에 report_type과 사용자 포함
      cache_key = "_milestone_report_#{@project.id}_#{version_id}_#{User.current.id}_#{today.strftime('%Y-%m-%d_%H-%M')}_#{report_type}"
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
      assign_from_date = begin
        params[:assign_from_date] ? Date.parse(params[:assign_from_date]) : Date.today
      rescue ArgumentError
        Date.today
      end

      # 일감 정보 조회 및 분석 (한 번에 처리)
      @issues_info = begin
        if params[:user_id].present?
          RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_user_schedule(params[:user_id])
        elsif params[:parent_issue_id].present?
          RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_parent_schedule(params[:parent_issue_id])
        else
          { all_issues: [], fixed_issues: [], other_issues: [], candidate_issues: [], no_estimated_hours_issues: [] }
        end
      rescue ActiveRecord::RecordNotFound
        return render_404
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

          # 저장 전에 모든 대상 일감의 가시성/편집 권한을 확인
          target_issues = Issue.visible.where(id: issue_data.map { |data| data['id'] }).index_by(&:id)
          unauthorized_ids = issue_data.filter_map do |data|
            issue = target_issues[data['id'].to_i]
            data['id'] unless issue && issue_schedule_editable?(issue)
          end
          if unauthorized_ids.any?
            flash[:error] = "일정을 수정할 권한이 없는 일감이 있습니다: #{unauthorized_ids.map { |id| "##{id}" }.join(', ')}"
          else
            saved_count = 0
            ActiveRecord::Base.transaction do
              issue_data.each do |data|
                saved_count += 1 if RedmineTxMilestone::IssueScheduleWriteService.apply(
                  issue: target_issues[data['id'].to_i],
                  start_date: Date.parse(data['start_date']),
                  due_date: Date.parse(data['due_date']),
                  user: User.current
                )
              end
            end

            flash[:notice] = "#{saved_count}개 일감의 일정이 확정되었습니다."
            redirect_to tetris_project_milestone_index_path(@project, user_id: params[:user_id], parent_issue_id: params[:parent_issue_id])
            return
          end
        rescue => e
          Rails.logger.error "tetris save_schedule error: #{e.class} #{e.message}\n#{e.backtrace.first(5).join("\n")}"
          flash[:error] = '일정 저장 중 오류가 발생했습니다.'
        end
      end
    end

    # 통합 AI 요약 엔드포인트
    # GET ai_summary?type=dashboard&version_id=123
    # GET ai_summary?type=schedule_summary&issue_ids=1,2,3
    def ai_summary
      unless defined?(RedmineTxMcp::LlmService) && RedmineTxMcp::LlmService.available?
        return render json: { success: false, error: 'AI 요약 기능을 사용할 수 없습니다. MCP 플러그인의 API 키를 확인해 주세요.' }
      end

      begin
        case params[:type]
        when 'dashboard'
          unless Setting.plugin_redmine_tx_milestone['enable_ai_summary_dashboard'] == 'true'
            return render json: { success: false, error: '대시보드 AI 요약 기능이 비활성화되어 있습니다. 플러그인 설정에서 활성화해 주세요.' }
          end
          prompt = build_dashboard_ai_prompt
        when 'schedule_summary'
          unless Setting.plugin_redmine_tx_milestone['enable_ai_summary_schedule'] == 'true'
            return render json: { success: false, error: '일정요약 AI 요약 기능이 비활성화되어 있습니다. 플러그인 설정에서 활성화해 주세요.' }
          end
          if schedule_summary_mode == 'issue' && params[:issue_ids].blank?
            return render json: { success: false, error: '일감 ID가 필요합니다.' }
          end
          data = cached_schedule_summary_data
          prompt = build_schedule_summary_ai_prompt(data)
        else
          return render json: { success: false, error: "알 수 없는 요약 유형: #{params[:type]}" }
        end

        return render json: { success: false, error: '프롬프트를 생성할 수 없습니다.' } unless prompt

        result = if params[:type] == 'schedule_summary'
                   cached_schedule_summary_ai_result(prompt)
                 else
                   RedmineTxMcp::LlmService.summarize(prompt)
                 end

        if result.present?
          render json: { success: true, summary: result }
        else
          render json: { success: false, error: 'AI 응답을 받지 못했습니다.' }
        end
      rescue => e
        Rails.logger.error "ai_summary error: #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: { success: false, error: '요약 생성 중 오류가 발생했습니다.' }
      end
    end

    def cached_schedule_summary_data
      return compute_schedule_summary_data if params[:force] == 'true'

      Rails.cache.fetch(schedule_summary_data_cache_key, expires_in: 5.minutes, skip_nil: true) do
        compute_schedule_summary_data
      end
    end

    def schedule_summary_data_cache_key
      mode = schedule_summary_mode
      display_start_date = begin
        params[:display_start_date].present? ? Date.parse(params[:display_start_date]) : 2.months.ago.to_date
      rescue ArgumentError
        2.months.ago.to_date
      end

      scope_key = if mode == 'team'
                    schedule_summary_group_ids.join(',')
                  else
                    params[:issue_ids].to_s.split(/[,;\s]+/).map(&:strip).reject(&:blank?).map(&:to_i).uniq.sort.join(',')
                  end
      digest_source = "#{@project.id}:#{User.current.id}:#{Date.today}:#{mode}:#{display_start_date}:#{scope_key}"
      digest = Digest::SHA256.hexdigest(digest_source)[0..15]

      "milestone/schedule_summary_data/#{@project.id}/#{User.current.id}/#{digest}"
    end

    def cached_schedule_summary_ai_result(prompt)
      return RedmineTxMcp::LlmService.summarize(prompt) if params[:force] == 'true'

      Rails.cache.fetch(schedule_summary_ai_cache_key(prompt), expires_in: 30.minutes, skip_nil: true) do
        result = RedmineTxMcp::LlmService.summarize(prompt)
        result.present? ? result : nil
      end
    end

    def schedule_summary_ai_cache_key(prompt)
      mcp_settings = Setting.plugin_redmine_tx_mcp rescue {}
      llm_provider = mcp_settings['llm_provider'] || 'anthropic'
      llm_model = if llm_provider == 'openai'
                    mcp_settings['openai_model'].presence || 'default'
                  else
                    mcp_settings['claude_model'].presence || 'claude-sonnet-4-6'
                  end
      digest_source = "#{@project.id}:#{User.current.id}:#{llm_provider}:#{llm_model}:#{prompt}"
      prompt_digest = Digest::SHA256.hexdigest(digest_source)[0..15]

      "milestone/schedule_summary_ai/#{@project.id}/#{User.current.id}/#{prompt_digest}"
    end

    private :cached_schedule_summary_data,
            :schedule_summary_data_cache_key,
            :cached_schedule_summary_ai_result,
            :schedule_summary_ai_cache_key

    def sync_parent_date
    end

    def api_sync_parent_date
      begin
        if params[:ids].present?
          updated_count = 0
          skipped_ids = []
          issues = Issue.visible.where(id: params[:ids])

          issues.each do |issue|
            unless issue_schedule_editable?(issue, edit_start_date: false)
              skipped_ids << issue.id
              next
            end

            # 자식 일감들의 최대 완료일을 조회
            max_child_due = issue.descendants
                                .where.not(due_date: nil)
                                .maximum(:due_date)

            next unless max_child_due.present?
            next unless issue.due_date.nil? || issue.due_date < max_child_due

            updated_count += 1 if RedmineTxMilestone::IssueDueDateSyncService.sync_due_date!(
              issue: issue,
              due_date: max_child_due,
              user: User.current
            )
          end

          message = "#{updated_count}개 일감의 일정을 동기화했습니다."
          message += " (권한 없는 일감 #{skipped_ids.size}건 제외)" if skipped_ids.any?
          render json: {
            success: true,
            message: message
          }
        else
          render json: {
            success: false,
            message: "동기화할 일감을 선택해주세요."
          }
        end
      rescue => e
        Rails.logger.error "api_sync_parent_date error: #{e.class} #{e.message}\n#{e.backtrace.first(5).join("\n")}"
        render json: {
          success: false,
          message: '동기화 중 오류가 발생했습니다.'
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

    # dashboard AI 요약용 프롬프트 생성 (overview 데이터를 직접 조회)
    def build_dashboard_ai_prompt
      version_id = if params[:version_id].present? && params[:version_id] != 'all'
                     @project.shared_versions.find_by(id: params[:version_id])&.id
                   else
                     @project&.default_version&.id
                   end
      return nil unless version_id

      overview = RedmineTxMilestone::SummaryService.dashboard_overview(version_id)
      return nil if overview.nil? || overview[:error]

      bug_data = build_bug_data_for_ai(overview, version_id)
      build_ai_summary_prompt(overview, bug_data: bug_data)
    end

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
            when 'no_due_date' then "일정없음 #{a[:count]}건"
            when 'not_started' then "미개시 #{a[:count]}건"
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

  # 루트 일감과 그 하위 트리를 표시 순서대로 평탄화 (폐기된 하위 트리는 제외)
  def gantt_issue_tree(root_issue)
    children_by_parent_id = root_issue.self_and_descendants.visible.to_a.group_by(&:parent_id)
    ordered = []
    visit = lambda do |issue|
      ordered << issue
      Array(children_by_parent_id[issue.id]).sort_by(&:lft).each do |child|
        next if IssueStatus.is_discarded?(child.status_id)

        visit.call(child)
      end
    end
    visit.call(root_issue)
    ordered
  end

  # 버전 간트에 표시할 일감 그룹 (주요/메인/이관 대기)
  def gantt_version_issue_groups(version)
    return { major: [], main: [], review: [] } if version.nil?

    main_issues = Issue.visible
                       .where(fixed_version_id: version.id, tracker_id: Tracker.roadmap_trackers_ids)
                       .where.not(status_id: IssueStatus.discarded_ids)
                       .to_a
    major_issues = if RedmineTxMilestoneHelper.major_issue_tag_names.present?
                     RedmineTxMilestoneHelper.milestone_major_issues(main_issues)
                   else
                     []
                   end
    major_issue_ids = major_issues.map(&:id).to_set
    remaining_main_issues = main_issues.reject { |issue| major_issue_ids.include?(issue.id) }
    review_issues = RedmineTxMilestoneHelper.milestone_review_issues(version)

    groups = { major: major_issues, main: remaining_main_issues, review: review_issues }
    groups.each_value { |issues| sort_gantt_issues!(issues) }
    groups
  end

  # implemented 상태는 맨 아래로 내린다.
  # implemented 아닌 일감은 마감일 없음 우선, 마감일 오름차순으로,
  # implemented 일감은 마감일 없음 우선, 마감일 내림차순으로 정렬한다.
  # 이후 시작일 오름차순, 마지막으로 done_ratio 오름차순을 적용한다.
  def sort_gantt_issues!(issues)
    issues.sort_by! do |issue|
      implemented = IssueStatus.is_implemented?(issue.status_id)
      [
        implemented ? 1 : 0,
        issue.due_date.nil? ? 0 : 1,
        issue.due_date ? (implemented ? -issue.due_date.jd : issue.due_date.jd) : 0,
        issue.start_date ? issue.start_date.jd : Float::INFINITY,
        issue.done_ratio
      ]
    end
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
    all_issues = Issue.visible
                     .where(project_id: @project.id)
                     .where(tracker_id: base_data[:tracker_ids])
                     .where.not(status_id: base_data[:discarded_ids])
    all_issues = all_issues.where(fixed_version_id: version_id) if version_id
    
    all_completed_issues = all_issues.where.not(end_time: nil)
    issues = all_issues.where("#{Issue.table_name}.created_on >= ? OR #{Issue.table_name}.end_time >= ?", Date.today - 1.year, Date.today - 1.year)

    {
      all_issues: all_issues,
      all_completed_issues: all_completed_issues,
      issues: issues
    }
  end

  # 버그 데이터 조회
  def get_bug_data(base_data, version_id)
    # 뷰에서 priority/fixed_version 기준 정렬에 사용하므로 미리 로드
    all_bug_issues = Issue.visible
                         .where(project_id: @project.id)
                         .where(tracker_id: base_data[:bug_ids])
                         .where.not(status_id: base_data[:discarded_ids])
                         .includes(:priority, :fixed_version)
    all_bug_issues = all_bug_issues.where(fixed_version_id: version_id) if version_id
    
    all_bug_completed_issues = all_bug_issues.where.not(end_time: nil)
    bug_issues = all_bug_issues.where("#{Issue.table_name}.created_on >= ? OR #{Issue.table_name}.end_time >= ?", Date.today - 1.year, Date.today - 1.year)
    
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
    bugs_until_today = bug_data[:all_bug_issues].where("#{Issue.table_name}.created_on <= ?", today.end_of_day)
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

    # --- schedule_summary_ai helpers ---

    def schedule_summary_cookie_key(name)
      "rtx_ms_schedule_summary_#{@project.id}_#{User.current.id}_#{name}"
    end

    def schedule_summary_mode
      raw_mode = if params[:summary_mode].present?
                   params[:summary_mode]
                 elsif params[:issue_ids].present?
                   'issue'
                 else
                   cookies[schedule_summary_cookie_key('mode')].presence
                 end
      %w[issue team].include?(raw_mode) ? raw_mode : 'issue'
    end

    def schedule_summary_group_ids
      return [] unless schedule_summary_mode == 'team'

      raw_values =
        if params.key?(:group_ids) || params.key?('group_ids')
          params[:group_ids]
        else
          cookies[schedule_summary_cookie_key('group_ids')].to_s.split(',')
        end

      Array(raw_values)
        .flat_map { |value| value.to_s.split(',') }
        .map(&:strip)
        .reject(&:blank?)
        .map(&:to_i)
        .reject(&:zero?)
        .uniq
    end

    def schedule_summary_all_groups
      @schedule_summary_all_groups ||= begin
        excluded_group_ids = Array(TxBaseHelper.config_arr('e_group')).map(&:to_i)
        Group.includes(:users).reject { |group| excluded_group_ids.include?(group.id) }.sort_by(&:name)
      end
    end

    def schedule_summary_groups_to_show
      selected_group_ids = schedule_summary_group_ids
      return schedule_summary_all_groups if selected_group_ids.blank?

      schedule_summary_all_groups.select { |group| selected_group_ids.include?(group.id) }
    end

    def compute_schedule_summary_data
      today = Date.today
      display_start_date = begin
        params[:display_start_date].present? ? Date.parse(params[:display_start_date]) : 2.months.ago.to_date
      rescue ArgumentError
        2.months.ago.to_date
      end
      mode = schedule_summary_mode

      groups_to_show = schedule_summary_groups_to_show
      selected_user_ids = groups_to_show.flat_map { |group| group.users.map(&:id) }.uniq
      issue_preload_associations = RedmineTxMilestoneHelper.schedule_summary_issue_preload_associations

      if mode == 'team'
        input_issue_ids = []
        all_issues = selected_user_ids.any? ? Issue.visible.where(assigned_to_id: selected_user_ids) : Issue.none
        parent_issues = []
      else
        # 일감 ID 파싱 → 부모 일감 → 하위 일감 (ERB 로직 재현)
        input_issue_ids = params[:issue_ids].to_s.split(/[,;\s]+/).map(&:strip).reject(&:empty?).map(&:to_i).uniq
        input_issues = Issue.visible.where(id: input_issue_ids).to_a
        parent_issues = Issue.visible
                             .where(id: input_issues.map(&:root_id).uniq)
                             .preload(*issue_preload_associations)
                             .to_a

        all_issue_ids = Set.new(input_issues.map(&:id))
        # parent_issues는 루트이므로 하위 트리 전체가 같은 root_id를 가짐
        all_issue_ids.merge(
          Issue.visible.where(root_id: parent_issues.map(&:id)).where.not(id: parent_issues.map(&:id)).pluck(:id)
        )

        all_issues = Issue.visible.where(id: all_issue_ids.to_a)
      end

      # tracker/status 필터 (ERB와 동일)
      excluded_tracker_ids = (Tracker.bug_trackers_ids +
                              Tracker.sidejob_trackers_ids +
                              Tracker.exception_trackers_ids +
                              Tracker.roadmap_trackers_ids).uniq
      filtered_all = all_issues.where.not(tracker_id: excluded_tracker_ids)
                               .where.not(status_id: IssueStatus.discarded_ids)
      filtered = filtered_all.where.not(start_date: nil).where.not(due_date: nil)
                             .where('start_date >= ? OR due_date >= ?', display_start_date, display_start_date)
      filtered_issue_list = filtered.preload(*issue_preload_associations).to_a

      if mode == 'team'
        parent_issues = Issue.visible
                             .where(id: filtered_issue_list.map(&:root_id).uniq)
                             .preload(*issue_preload_associations)
                             .to_a
      end

      # 1. parent_issues
      pi_data = parent_issues.map { |i| { id: i.id, subject: i.subject } }

      # 2. holidays
      max_due = filtered_issue_list.filter_map(&:due_date).max || today
      timeline_end = max_due + 60.days
      holiday_list = []
      if TxBaseHelper::HolidayApi.available?
        raw = TxBaseHelper::HolidayApi.for_date_range(today, timeline_end)
        holiday_list = raw.select { |d, _| d >= today }.map { |d, info| { date: d.strftime('%Y-%m-%d'), name: info[:name] || info['name'] } }
      end
      holidays_data = { count: holiday_list.size, list: holiday_list }

      # 사용자별 그룹핑
      issues_by_user = filtered_issue_list.select(&:assigned_to_id).group_by(&:assigned_to_id)
      user_ids = issues_by_user.keys.compact
      users = User.where(id: user_ids).index_by(&:id)

      holiday_dates = Set.new(holiday_list.map { |h| Date.parse(h[:date]) })

      # 3. empty_days_by_user — 담당자별 일정 공백 작업일 수
      empty_days_by_user = {}
      issues_by_user.each do |uid, issues|
        user = users[uid]
        next unless user
        sorted = issues.sort_by(&:start_date)
        range_start = sorted.first.start_date
        range_end = sorted.last.due_date
        occupied = Set.new
        sorted.each { |i| (i.start_date..i.due_date).each { |d| occupied.add(d) } }
        empty_work_days = (range_start..range_end).count { |d| !d.saturday? && !d.sunday? && !holiday_dates.include?(d) && !occupied.include?(d) }
        empty_days_by_user[user.name] = empty_work_days if empty_work_days > 0
      end

      # 4. concurrent_by_user — 담당자별 최대 동시진행 일감 수
      concurrent_by_user = {}
      issues_by_user.each do |uid, issues|
        user = users[uid]
        next unless user
        events = []
        issues.each do |i|
          events << [i.start_date, 1]
          events << [i.due_date + 1, -1]
        end
        events.sort_by! { |d, _| d }
        running = 0
        max_concurrent = 0
        events.each do |_, delta|
          running += delta
          max_concurrent = running if running > max_concurrent
        end
        concurrent_by_user[user.name] = max_concurrent if max_concurrent > 1
      end

      # 5. version_marks
      versions = parent_issues.map(&:fixed_version).compact.uniq.select { |v| v.effective_date.present? }
      version_marks = []
      versions.each do |version|
        version.marks.each do |mark|
          next unless mark[:date].present?
          mark_date = mark[:date].is_a?(Date) ? mark[:date] : Date.parse(mark[:date].to_s)
          days_remaining = (mark_date - today).to_i
          version_marks << { date: mark_date.strftime('%Y-%m-%d'), name: mark[:name], is_deadline: mark[:is_deadline], days_remaining: days_remaining }
        end
        version_marks << { date: version.effective_date.strftime('%Y-%m-%d'), name: version.name, is_deadline: false, days_remaining: (version.effective_date - today).to_i }
      end
      version_marks.sort_by! { |m| m[:date] }

      # 6. issues_with_tips — tip이 있는 일감만
      issues_with_tips = []
      filtered_all_list = nil
      if Issue.method_defined?(:tip)
        filtered_all_list = filtered_all.preload(*issue_preload_associations).to_a
        filtered_all_list.each do |issue|
          t = issue.tip
          next unless t.present?

          assignee = issue.assigned_to&.name || '미배정'
          issues_with_tips << { id: issue.id, subject: issue.subject.truncate(40), tip: t, assignee: assignee }
        end
      end

      # 7. missing_schedule — 일정 미기입 일감
      missing_schedule_issues = if filtered_all_list
                                  filtered_all_list.select do |issue|
                                    issue.assigned_to_id.present? && (issue.start_date.nil? || issue.due_date.nil?)
                                  end
                                else
                                  filtered_all.where.not(assigned_to_id: nil)
                                              .where('start_date IS NULL OR due_date IS NULL')
                                              .preload(*issue_preload_associations)
                                              .to_a
                                end
      missing_list = missing_schedule_issues.map do |i|
        { id: i.id, subject: i.subject.truncate(40), assignee: i.assigned_to&.name || '미배정' }
      end
      missing_schedule = { count: missing_list.size, list: missing_list.first(20) }

      {
        mode: mode,
        selected_groups: groups_to_show.map(&:name),
        selected_user_count: selected_user_ids.size,
        parent_issues: pi_data,
        holidays: holidays_data,
        empty_days_by_user: empty_days_by_user,
        concurrent_by_user: concurrent_by_user,
        version_marks: version_marks,
        issues_with_tips: issues_with_tips,
        missing_schedule: missing_schedule,
        total_filtered: filtered_all_list ? filtered_all_list.size : filtered_all.count,
        total_with_schedule: filtered_issue_list.count(&:assigned_to_id)
      }
    end

    def build_schedule_summary_ai_prompt(data)
      today = Date.today
      lines = []
      lines << "오늘: #{today}"
      if data[:mode] == 'team'
        lines << "요약 기준: 팀 기준"
        lines << "선택 팀: #{data[:selected_groups].join(', ')}"
        lines << "대상 구성원: #{data[:selected_user_count]}명"
      else
        lines << "요약 기준: 일감 ID 기준"
      end
      lines << "연관 일감: #{data[:parent_issues].map { |i| "##{i[:id]} #{i[:subject]}" }.join(', ')}"
      lines << "전체 구현 일감: #{data[:total_filtered]}건, 일정 배정 완료: #{data[:total_with_schedule]}건"

      # 공휴일
      if data[:holidays][:count] > 0
        upcoming = data[:holidays][:list].first(5)
        lines << "\n예정 공휴일 (#{data[:holidays][:count]}건):"
        upcoming.each { |h| lines << "  #{h[:date]} #{h[:name]}" }
      end

      # 담당자별 빈 날짜
      if data[:empty_days_by_user].any?
        lines << "\n담당자별 일정 공백 (작업일 기준):"
        data[:empty_days_by_user].each { |name, days| lines << "  #{name}: #{days}일" }
      end

      # 담당자별 동시진행
      if data[:concurrent_by_user].any?
        lines << "\n담당자별 최대 동시진행 일감 수:"
        data[:concurrent_by_user].each { |name, count| lines << "  #{name}: #{count}건" }
      end

      # version marks
      if data[:version_marks].any?
        lines << "\n주요 일정 마크:"
        data[:version_marks].each do |m|
          status = if m[:days_remaining] < 0
                     "#{m[:days_remaining].abs}일 경과"
                   elsif m[:days_remaining] == 0
                     "오늘"
                   else
                     "#{m[:days_remaining]}일 남음"
                   end
          lines << "  #{m[:date]} #{m[:name]}#{m[:is_deadline] ? ' [마감]' : ''} (#{status})"
        end
      end

      # 일정 미기입
      if data[:missing_schedule][:count] > 0
        lines << "\n일정 미기입 일감 (#{data[:missing_schedule][:count]}건):"
        data[:missing_schedule][:list].each { |i| lines << "  ##{i[:id]} #{i[:subject]} (#{i[:assignee]})" }
      end

      # tips
      if data[:issues_with_tips].any?
        lines << "\n주의가 필요한 일감 (#{data[:issues_with_tips].size}건):"
        data[:issues_with_tips].first(15).each { |i| lines << "  ##{i[:id]} #{i[:subject]} (#{i[:assignee]}): #{i[:tip]}" }
      end

      context = lines.join("\n")

      missing_ratio = data[:total_filtered] > 0 ? (data[:missing_schedule][:count].to_f / data[:total_filtered] * 100).round(0) : 0

      requirements = ["5~10문장으로 핵심을 전달"]
      requirements << "가장 심각한 리스크나 주의사항을 먼저 언급"
      if missing_ratio >= 30
        requirements << "일정 미기입 일감이 전체의 #{missing_ratio}%에 달하므로, 일정 리스크 판단이 어려운 상황임을 최우선으로 강조"
      end
      requirements << "담당자별 동시진행 일감이 많거나 일정 공백이 큰 경우 리스크로 언급"
      requirements << "주요 일정 마크의 경과/잔여 상황을 고려하여 현재 시점의 위치를 판단"
      requirements << "마크다운 없이 평문으로 작성"
      requirements << "한국어로 작성"

      prompt = "위 일정요약 데이터를 바탕으로 프로젝트 매니저에게 보고하는 간결한 일정 현황 요약을 작성해 주세요.\n\n요구사항:\n" +
        requirements.map { |r| "- #{r}" }.join("\n")

      "#{context}\n\n#{prompt}"
    end

    def find_project
      @user = params[:user_id] ? User.visible.find(params[:user_id]) : User.current
      @project = Project.find(params[:project_id])
    rescue ActiveRecord::RecordNotFound
      render_404
    end
  
    def authorize
      raise Unauthorized unless User.current.allowed_to?(:view_milestone, @project)
    end

    def parse_schedule_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def normalize_issue_schedule_change(issue, start_date_provided:, start_date:, due_date_provided:, due_date:)
      return { error: '변경할 일정이 없습니다.' } unless start_date_provided || due_date_provided
      return { error: '시작일이 필요합니다.' } if start_date_provided && start_date.nil?
      return { error: '목표일이 필요합니다.' } if due_date_provided && due_date.nil?
      return { error: '기존 시작일이 있는 일감만 시작일을 조정할 수 있습니다.' } if start_date_provided && issue.start_date.blank?
      return { error: '기존 목표일이 있는 일감만 목표일을 조정할 수 있습니다.' } if due_date_provided && issue.due_date.blank?

      next_start_date = start_date_provided ? start_date : issue.start_date
      next_due_date = due_date_provided ? due_date : issue.due_date

      if next_start_date && next_due_date && next_start_date > next_due_date
        return { error: '시작일은 목표일보다 늦을 수 없습니다.' }
      end

      unless issue_schedule_editable?(
        issue,
        edit_start_date: start_date_provided,
        edit_due_date: due_date_provided
      )
        return { error: '일정을 수정할 권한이 없습니다.', status: :forbidden }
      end

      {
        start_date: next_start_date,
        due_date: next_due_date
      }
    end

    def issue_schedule_editable?(issue, edit_start_date: true, edit_due_date: true)
      issue.attributes_editable?(User.current) &&
        (!edit_start_date || issue.safe_attribute?('start_date', User.current)) &&
        (!edit_due_date || issue.safe_attribute?('due_date', User.current))
    end

    def schedule_param_present?(schedule, key)
      return false unless schedule.respond_to?(:key?)

      schedule.key?(key) || schedule.key?(key.to_s)
    end

    def schedule_param_value(schedule, key)
      return nil unless schedule.respond_to?(:[])

      schedule[key] || schedule[key.to_s]
    end

    def render_schedule_error(message, status = :unprocessable_entity)
      render json: { success: false, message: message }, status: status
    end

    def group_infos
      groups = {}

      excluded_user_ids = TxBaseHelper.config_arr('e_users')
      all_users = User.active
        .where.not(id: excluded_user_ids)
        .distinct #.select{ |u| (u.group_ids & excluded_group_ids).empty? }

      excluded_group_ids = TxBaseHelper.config_arr('e_group') || []
      all_groups = Group.includes(:users).select{ |group| !excluded_group_ids.include?(group.id) }

      all_groups.each do |group|
        group_user_ids = group.users.map(&:id).to_set
        # @users의 순서를 유지하면서 해당 그룹의 사용자만 필터링
        groups[ group ] = { user_infos: all_users.filter_map { |user| { user: user, issue_info: RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.analyze_user_schedule( user.id ) } if group_user_ids.include?(user.id) } }
      end

      groups
    end

  end
  
