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
      
      # 캐시 키 생성 - 프로젝트 ID와 날짜를 포함
      cache_key = "milestone_report_5#{@project.id}_#{today.strftime('%Y-%m-%d_%H-%M')}"
      
      @issues_by_week, @avarage_hours_per_category = Rails.cache.fetch(cache_key, expires_in: 5.minutes) do

        categories = IssueCategory.all.pluck(:id, :name).to_h
        

        tracker_ids = Tracker.where( is_sidejob: false ).where( is_exception: false ).pluck(:id)        

        issues = Issue.where( project_id: @project.id ).where( tracker_id: tracker_ids ).where( 'created_on >= ? OR end_time >= ?', Date.today - 1.year, Date.today - 1.year )
        issues_by_week = []

        (1..20).each { |week|
            created_issues = issues.select { |issue| issue.created_on.present? && issue.created_on > today - week.weeks && issue.created_on <= today - (week - 1).weeks }
            completed_issues = issues.select { |issue| issue.end_time.present? && issue.end_time > today - week.weeks && issue.end_time <= today - (week - 1).weeks }

            issues_by_category = {}

            created_issues.each { |issue|
              next unless issue.category_id
              category_name = categories[issue.category_id]
              next unless category_name  # nil 체크 추가
              issues_by_category[category_name] ||= { created: 0, completed: 0 }
              issues_by_category[category_name][:created] += 1
            }

            completed_issues.each { |issue|
              next unless issue.category_id
              category_name = categories[issue.category_id]
              next unless category_name  # nil 체크 추가
              issues_by_category[category_name] ||= { created: 0, completed: 0 }
              issues_by_category[category_name][:completed] += 1
            }          

            issues_by_week.push( {week: week, created: created_issues.size, completed: completed_issues.size, issues_by_category: issues_by_category} )
        }

        avarage_hours_per_category = {}
        avarage_count_per_category = {}
        issues.where.not( begin_time: nil ).where.not( end_time: nil ).each { |issue|
          next unless issue.category_id
          category_name = categories[issue.category_id]
          next unless category_name  # nil 체크 추가
          next if issue.end_time - issue.begin_time >= 1.year
          avarage_hours_per_category[category_name] ||= 0
          avarage_hours_per_category[category_name] += ( issue.end_time - issue.begin_time ).to_i
          avarage_count_per_category[category_name] ||= 0
          avarage_count_per_category[category_name] += 1
        }

        [ issues_by_week, avarage_hours_per_category.map { |category_name, hours| [ category_name, (hours / avarage_count_per_category[category_name])/3600 ] }.to_h ]
      end

    end

    def roadmap
      # DB에서 로드맵 데이터 불러오기
      @roadmap_data = RoadmapData.active_for_project(@project.id)
      
      if @roadmap_data && @roadmap_data.categories.any?
        # DB에서 불러온 데이터 사용
        @all_projects = @roadmap_data.categories.map do |category|
          {
            category: category['name'] || '미분류',
            customColor: category['customColor'], # 카테고리 색상 정보 추가
            events: (category['events'] || []).map do |event|
              {
                name: event['name'] || '이름 없음',
                schedules: (event['schedules'] || []).map do |schedule|
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
                    
                    {
                      name: schedule['name'] || '일정 없음',
                      start_date: start_date,
                      end_date: end_date,
                      status: schedule['status'] || 'planning'
                    }
                  rescue => e
                    Rails.logger.warn "스케줄 파싱 오류: #{e.message}, 스케줄: #{schedule}"
                    {
                      name: schedule['name'] || '일정 없음',
                      start_date: nil,
                      end_date: nil,
                      status: schedule['status'] || 'planning'
                    }
                  end
                end.compact
              }
            end.compact
          }
        end.compact
      else
        # DB에 데이터가 없으면 기본 예제 데이터 사용
        @all_projects = [
          { 
            category: '가챠', 
            events: [
              {
                name: "미국",
                schedules: [
                  { name: "미국 출장 1차", start_date: Date.new(2025, 7, 1), end_date: Date.new(2025, 7, 15), status: "in-progress" },
                  { name: "미국 파트너십 미팅", start_date: Date.new(2025, 6, 20), end_date: Date.new(2025, 6, 25), status: "planning" }
                ]
              },
              {
                name: "일본",
                schedules: [
                  { name: "일본 현지조사", start_date: Date.new(2025, 10, 5), end_date: Date.new(2025, 10, 20), status: "planning" }
                ]
              }
            ]
          },
          { 
            category: '이벤트', 
            events: [
              {
                name: "일반인",
                schedules: [
                  { name: "일반 사용자 교육", start_date: Date.new(2025, 10, 2), end_date: Date.new(2025, 10, 16), status: "review" }
                ]
              }
            ]
          }
        ]
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
        issues = Issue.where(id: issue_ids)

        # 자동 재배치
        auto_schedule_issues( issues, assign_from_date )

        @result_issues = issues

        flash[:notice] = "#{issues.count}개 일감의 일정을 아래와 같이 제안 합니다.<br>저장하시려면 위 일정으로 확정 버튼을 클릭해 주세요.".html_safe
        
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
      data = JSON.parse(params[:roadmap_data])
      
      # 데이터 유효성 검사
      unless data['categories'].is_a?(Array)
        raise ArgumentError, 'Invalid data format: categories must be an array'
      end
      
      # 프로젝트별 공용 로드맵 찾기 또는 생성
      roadmap_data = RoadmapData.find_or_initialize_by(
        project_id: @project.id,
        is_active: true
      )
      
      # 기존 레코드가 있으면 업데이트, 없으면 새로 생성
      roadmap_data.assign_attributes(
        name: params[:name] || "#{@project.name} Roadmap",
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
      roadmap_data = RoadmapData.active_for_project(@project.id)
      
      if roadmap_data && roadmap_data.categories.any?
        # @all_projects와 동일한 구조로 변환하여 반환
        formatted_data = roadmap_data.categories.map do |category|
          {
            category: category['name'] || '미분류',
            customColor: category['customColor'], # 카테고리 색상 정보 포함
            events: (category['events'] || []).map do |event|
              {
                name: event['name'] || '이름 없음',
                schedules: (event['schedules'] || []).map do |schedule|
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
                    
                    {
                      name: schedule['name'] || '일정 없음',
                      start_date: start_date,
                      end_date: end_date,
                      status: schedule['status'] || 'planning'
                    }
                  rescue => e
                    Rails.logger.warn "스케줄 파싱 오류: #{e.message}, 스케줄: #{schedule}"
                    {
                      name: schedule['name'] || '일정 없음',
                      start_date: nil,
                      end_date: nil,
                      status: schedule['status'] || 'planning'
                    }
                  end
                end.compact
              }
            end.compact
          }
        end.compact
        
        render json: {
          success: true,
          data: formatted_data,
          categories: formatted_data.map { |project| 
            {
              name: project[:category],
              customColor: project[:customColor]
            }
          },
          updated_at: roadmap_data.updated_at
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
  
    private

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
      raise Unauthorized unless User.current.allowed_to?(:view_sc_report, @project)
    end

     

    def auto_schedule_issues( issues, assign_from_date = Date.today )

      # 이미 일정이 배치된 날짜들 정보를 정리해 둔다
      all_blocked_dates = Issue.blocked_dates_map_per_assignee( issues )

      # 1. priority가 큰 순서부터 정렬 (priority_id가 클수록 높은 우선순위)
      priority_sorted_issues = issues.sort_by do |issue|
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

      assigned_to_ids = issues.map { |issue| issue.assigned_to_id }.uniq
      
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
        latest_predecessor_end_date = issue.latest_predecessor_end_date( issues )
        
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
  end
  
