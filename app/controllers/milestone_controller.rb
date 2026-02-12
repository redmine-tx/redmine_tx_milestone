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
    before_action :find_project, except: [:issue_detail, :predict_issue, :apply_predict_issue]
    before_action :authorize, except: [:issue_detail, :predict_issue, :apply_predict_issue]
    before_action :find_issue_for_predict, only: [:predict_issue, :apply_predict_issue]
  
    def index
      # force 파라미터가 있으면 캐시를 클리어합니다
      #Rails.cache.delete('user_status_users') if params[:force].present?
      
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
            if issue.parent.present? && issue.due_date && (issue.parent.due_date.nil? || issue.parent.due_date < issue.due_date)
              issue.parent.due_date = issue.due_date
              if issue.parent.save
                updated_count += 1
              end
            end
          end
          
          render json: { 
            success: true, 
            message: "#{updated_count}개 일감의 일정을 부모 일감에 반영했습니다." 
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

    private

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
  
