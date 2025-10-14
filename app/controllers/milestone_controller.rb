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
    before_action :find_project, except: [:issue_detail]
    before_action :authorize, except: [:issue_detail]
  
    def index
      # force 파라미터가 있으면 캐시를 클리어합니다
      #Rails.cache.delete('user_status_users') if params[:force].present?
      
    end

    def gantt
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

    def roadmap
      # DB에서 로드맵 데이터 불러오기
      @roadmap_names = RoadmapData.where( project_id: @project.id ).pluck(:name).uniq
      @roadmap_data = RoadmapData.active_for_project(@project.id)
      
      if @roadmap_data && @roadmap_data.categories.any?
        # DB에서 불러온 데이터 사용
        formatted_categories = format_roadmap_categories(@roadmap_data)
        @all_roadmaps = build_roadmap_response_data(@roadmap_data, formatted_categories, "Redmine 로드맵 데이터", @roadmap_data.name)
      else
        # DB에 데이터가 없으면 기본 예제 데이터 사용
        @all_roadmaps = build_default_roadmap_data("Redmine 로드맵 기본 데이터", @roadmap_data.name)
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

      # 일정 배치 가능한 상태들
      valid_status_ids = ( IssueStatus.in_progress_ids + IssueStatus.new_ids ).uniq

      # 일정 배치 가능한 일감 목록 취합      
      issues =  if params[:user_id].present?
                  Issue.where( assigned_to_id: params[:user_id] ).where( status_id: valid_status_ids )        
                elsif params[:parent_issue_id].present?

                  # 부모+자식 일감을 related_issues에 정리
                  parent_issue = Issue.find( params[:parent_issue_id] )
                  related_issues = ( [ parent_issue ] + get_all_descendants(parent_issue) ).select { |issue| valid_status_ids.include?( issue.status_id ) }

                  # 관련자들의 기타 일정 확정된 이슈를 모두 얻어온다.
                  assigned_to_ids = related_issues.map { |issue| issue.assigned_to }.uniq
                  etc_blocked_issues = Issue.where( assigned_to_id: assigned_to_ids ).where( status_id: valid_status_ids ).where.not( start_date: nil ).where.not( due_date: nil ).order( assigned_to_id: :desc )
                  etc_blocked_issues = etc_blocked_issues.select { |issue| !related_issues.include?( issue ) }
                  ( related_issues + etc_blocked_issues ).uniq
                else
                  []
                end
      
      # 일감 정보 정리
      # @issues_info[:fixed_issues] 일정이 확정된 일감
      # @issues_info[:other_issues] 일정이 확정되지 않은 일감
      # @issues_info[:candidate_issues] 일정이 확정되지 않은 일감 중 예상 시간이 있는 일감
      # @issues_info[:no_estimated_hours_issues] 일정이 확정되지 않은 일감 중 예상 시간이 없는 일감
      @issues_info = Issue.analyze_issues_schedule( issues )

      # 일정 자동 배치 (저장은 되지 않음)
      if params[:auto_schedule] == 'true' && params[:issue_ids].present?
        
        # 자동 배치 요청한 이슈들 취합
        issue_ids = params[:issue_ids].split(',').map(&:to_i)
        target_issues = issues.select { |issue| issue_ids.include?( issue.id ) }  # target_issues 는 issues 의 객체와 동일한 객체를 참조해야함. 새로운 인스턴스를 만들면 일정 꼬임.

        # 자동 재배치
        auto_schedule_issues( issues, target_issues, assign_from_date )

        @result_issues = target_issues

        flash[:notice] = "#{target_issues.count}개 일감의 일정을 아래와 같이 제안 합니다.<br>저장하시려면 위 일정으로 확정 버튼을 클릭해 주세요.".html_safe
        
      # 요청된 일감 정보대로 일정을 저장.
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

      # 로드맵 데이터 저장 API
  def save_roadmap_data
    begin
      # JSON 데이터 파싱 및 검증
      name = params[:name] || "Default"
      data = JSON.parse(params[:roadmap_data])
      
      # 데이터 유효성 검사
      unless data['categories'].is_a?(Array)
        raise ArgumentError, 'Invalid data format: categories must be an array'
      end
      
      # 프로젝트별 공용 로드맵 찾기 또는 생성
      roadmap_data = RoadmapData.find_or_initialize_by(
        project_id: @project.id,
        name: name,
        is_active: true
      )
      
      # 기존 레코드가 있으면 업데이트, 없으면 새로 생성
      roadmap_data.assign_attributes(
        name: name,
        data: data.to_json,
        is_active: true
      )
      
      if roadmap_data.save
        render json: {
          success: true,
          message: roadmap_data.persisted? ? '로드맵 데이터가 성공적으로 업데이트되었습니다.' : '로드맵 데이터가 성공적으로 생성되었습니다.',
          roadmap_id: roadmap_data.id,
          updated_at: roadmap_data.updated_at,
          is_new_record: roadmap_data.previously_new_record?
        }
      else
        render json: {
          success: false,
          message: '저장에 실패했습니다.',
          errors: roadmap_data.errors.full_messages
        }, status: :unprocessable_entity
      end
      
    rescue JSON::ParserError => e
      render json: {
        success: false,
        message: 'JSON 형식이 올바르지 않습니다.'
      }, status: :bad_request
      
    rescue => e
      Rails.logger.error "RoadmapData 저장 중 예외 발생: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      render json: {
        success: false,
        message: '서버 오류가 발생했습니다.',
        error_details: e.message
      }, status: :internal_server_error
    end
  end

# 로드맵 데이터 불러오기 API
def load_roadmap_data
  begin
    roadmap_data = RoadmapData.active_for_project(@project.id, params[:name])

    pp roadmap_data
      
    if roadmap_data && roadmap_data.categories.class == Array
      # JSON 파일과 동일한 형식으로 변환
      formatted_categories = format_roadmap_categories(roadmap_data)
      data = build_roadmap_response_data(roadmap_data, formatted_categories, "서버에서 로드한 Redmine 로드맵 데이터", roadmap_data.name)
      
        # JSON 파일과 동일한 형식으로 반환
      render json: {
        success: true,
        name: roadmap_data.name,
        data: data
      }
    else
      render json: {
        success: false,
        message: '저장된 로드맵 데이터가 없습니다.'
      }, status: :not_found
    end
    
  rescue => e
    Rails.logger.error "로드맵 데이터 로드 오류: #{e.message}"
    render json: {
      success: false,
      message: '데이터 로드 중 오류가 발생했습니다.'
    }, status: :internal_server_error
  end
end

# 새 로드맵 생성 액션
def create_roadmap
  begin
    # 파라미터 검증
    name = params[:name]&.strip
    
    if name.blank?
      render json: {
        success: false,
        message: '로드맵 이름을 입력해주세요.'
      }, status: :bad_request
      return
    end
    
    # 중복 이름 체크
    existing_roadmap = RoadmapData.where(project_id: @project.id, name: name, is_active: true).first
    if existing_roadmap
      render json: {
        success: false,
        message: '이미 같은 이름의 로드맵이 존재합니다.'
      }, status: :conflict
      return
    end
    
    # 새 로드맵 생성
    roadmap_data = RoadmapData.create!(
      project_id: @project.id,
      name: name,
      is_active: true,
      data: build_default_roadmap_data( "Redmine 로드맵 데이터", name ).to_json
    )
    
    render json: {
      success: true,
      message: "새 로드맵 '#{name}'이 성공적으로 생성되었습니다.",
      roadmap_id: roadmap_data.id,
      name: roadmap_data.name
    }
    
  rescue => e
    Rails.logger.error "새 로드맵 생성 오류: #{e.message}"
    render json: {
      success: false,
      message: '로드맵 생성 중 오류가 발생했습니다.'
    }, status: :internal_server_error
  end
end
  
    private

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
      created_issues = issues.select { |issue| issue.created_on.present? && issue.created_on >= today - day.days && issue.created_on <= today - (day - 1).days }
      completed_issues = issues.select { |issue| issue.end_time.present? && issue.end_time >= today - day.days && issue.end_time <= today - (day - 1).days }
      
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
        created_bug_issues = bug_issues.select { |issue| issue.created_on.present? && issue.created_on >= today - day.days && issue.created_on <= today - (day - 1).days }
        completed_bug_issues = bug_issues.select { |issue| issue.end_time.present? && issue.end_time >= today - day.days && issue.end_time <= today - (day - 1).days }
        
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
        day: Date.today - day.days,
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
    
    # 버그 통계용 데이터 (일반 일감 제외)
    issues_by_days = calculate_daily_stats(today, [], bug_data[:bug_issues], base_data[:categories], nil, bug_data[:all_bug_issues], include_bugs: true)
    rest_issue_count_per_category = calculate_rest_issue_counts(
      Issue.none, 
      Issue.none, 
      bug_data[:all_bug_issues], 
      bug_data[:all_bug_completed_issues], 
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

    def get_all_descendants(issue)
      descendants = []
      issue.children.each do |child|
        descendants << child
        descendants.concat(get_all_descendants(child))
      end
      descendants
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

     

    def auto_schedule_issues( all_issues, target_issues, assign_from_date = Date.today )

      # 이미 일정이 배치된 날짜들 정보를 정리해 둔다
      all_blocked_dates = Issue.blocked_dates_map_per_assignee( all_issues )

      # 1. priority가 큰 순서부터 정렬 (priority_id가 클수록 높은 우선순위)
      priority_sorted_issues = target_issues.sort_by do |issue|
        [
          ( issue.fixed_version&.effective_date || assign_from_date + 10.years ),
          -(issue.priority_id || 0),
          issue.id
        ]
      end

      # 2. 상호간 선행 일감 관계를 고려한 위상 정렬
      # 위상 정렬은 선/후행 관계를 올바르게 처리할 수 있는 알고리즘입니다
      sorted_issues = Issue.topological_sort(priority_sorted_issues)
      Rails.logger.info "[RedmineTxMilestone] sorted_issues: #{sorted_issues.map { |issue| issue.id }}"

      assigned_to_ids = target_issues.map { |issue| issue.assigned_to_id }.uniq
      
      assigned_dates = {} # 이미 배치된 일감들의 날짜를 추적
      assigned_to_ids.each do |assigned_to_id|
        assigned_dates[assigned_to_id] = {}
      end
      
      sorted_issues.each do |issue|
        next unless issue.estimated_hours.present?

        #puts "issue.id: #{issue.id}"
        
        # 추정작업시간을 일수로 변환 (8시간 = 1일)
        work_days = (issue.estimated_hours / 8.0).ceil
        
        # 선행 일감들의 완료일을 고려하여 시작 가능한 날짜 계산
        search_start_date = assign_from_date
        latest_predecessor_end_date = issue.latest_predecessor_end_date( all_issues )
        
        if latest_predecessor_end_date.present?          
          search_start_date = [search_start_date, latest_predecessor_end_date + 1.day].max
          #puts "  - latest_predecessor_end_date: #{latest_predecessor_end_date} search_start_date: #{search_start_date}"
        end

        start_date = Issue.find_available_start_date(search_start_date, work_days, all_blocked_dates[issue.assigned_to_id], assigned_dates[issue.assigned_to_id], issue.estimated_hours)
        due_date = Issue.calculate_due_date(start_date, work_days)

        #puts "\e[31missue.id: #{issue.id} search_start_date: #{search_start_date} latest_predecessor_end_date: #{latest_predecessor_end_date} start_date: #{start_date} due_date: #{due_date}\e[0m"
        
        # 일감 업데이트
        issue.start_date = start_date
        issue.due_date = due_date

        # 사용된 날짜 범위를 기록
        if issue.estimated_hours.to_f < 8.0 then
          assigned_dates[issue.assigned_to_id][start_date] = assigned_dates[issue.assigned_to_id][start_date].to_f + issue.estimated_hours.to_f
        else
          (start_date..due_date).each { |date| assigned_dates[issue.assigned_to_id][date] = assigned_dates[issue.assigned_to_id][date].to_f + 8.0 }
        end
      end
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
        groups[ group ] = { user_infos: all_users.filter_map { |user| { user: user, issue_info: Issue.analyze_issues_schedule( Issue.where( assigned_to_id: user.id ).where( status_id: ( IssueStatus.in_progress_ids + IssueStatus.new_ids ).uniq ) ) } if group.users.map(&:id).include?(user.id) } }
      end

      groups
    end

    # 로드맵 카테고리 포맷팅 (중복 코드 제거용)
    def format_roadmap_categories(roadmap_data)
      return [] unless roadmap_data&.categories&.any?
      
      roadmap_data.categories.map.with_index do |category, index|
        {
          name: category['name'] || '미분류',
          index: index,
          customColor: category['customColor'],
          events: (category['events'] || []).map do |event|
            {
              name: event['name'] || '이름 없음',
              schedules: (event['schedules'] || []).map do |schedule|
                format_schedule(schedule)
              end.compact
            }
          end.compact
        }
      end.compact
    end

    # 스케줄 포맷팅 (중복 코드 제거용)
    def format_schedule(schedule)
      begin
        start_date = nil
        end_date = nil
        
        # 날짜 파싱 시 예외 처리
        if schedule['startDate'].present?
          start_date = Date.parse(schedule['startDate']) rescue nil
        end
        
        if schedule['endDate'].present?
          end_date = Date.parse(schedule['endDate']) rescue nil
        end

        done_ratio = if schedule['issue'].present?
                      issue = Issue.where(id: schedule['issue']).first
                      issue.present? ? issue.done_ratio : nil
                    else
                      nil
                    end
      
        {
          name: schedule['name'] || '일정 없음',
          startDate: start_date&.strftime('%Y-%m-%d'),
          endDate: end_date&.strftime('%Y-%m-%d'),
          issue: schedule['issue'] || '',
          done_ratio: done_ratio,
          customColor: schedule['customColor']
        }
      rescue => e
        Rails.logger.warn "스케줄 파싱 오류: #{e.message}, 스케줄: #{schedule}"
        {
          name: schedule['name'] || '일정 없음',
          startDate: nil,
          endDate: nil,
          issue: schedule['issue'] || '',
          done_ratio: nil,
          customColor: schedule['customColor']
        }
      end
    end

    # 로드맵 응답 데이터 구조 생성 (중복 코드 제거용)
    def build_roadmap_response_data(roadmap_data, categories, description, name = 'Default')
      {
        metadata: build_roadmap_metadata(roadmap_data, description, name),
        categories: categories
      }
    end

    # 기본 로드맵 데이터 구조 생성 (중복 코드 제거용)
    def build_default_roadmap_data(description, name = 'Default')
      build_roadmap_response_data(nil, [], description, name)
    end

    # 로드맵 메타데이터 생성 (중복 코드 제거용)
    def build_roadmap_metadata(roadmap_data, description, name = 'Default')
      {
        exportDate: roadmap_data&.updated_at&.iso8601 || Time.current.iso8601,
        version: "1.0",
        name: name,
        description: description
      }
    end
  end
  
