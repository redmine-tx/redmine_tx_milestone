module RedmineTxMilestoneAutoScheduleHelper

  class Hooks < Redmine::Hook::ViewListener
    render_on :view_issues_show_details_bottom, partial: 'issues/estimated_due_date_fields'
  end

    # IssueRelation 패치: 레드마인 기본 자동 스케줄링 제어
    #
    # 레드마인의 기본 자동 스케줄링 기능(set_issue_to_dates)을 설정에 따라 선택적으로 비활성화합니다.
    # 이 플러그인의 자체 AutoScheduler 로직과 충돌을 방지하기 위해 사용됩니다.
    #
    # 설정:
    #   - setting_milestone_use_redmine_auto_schedule = 'true': 레드마인 기본 동작 사용
    #   - setting_milestone_use_redmine_auto_schedule = 'false' 또는 미설정: 기본 동작 무시
    #
    # 사용법:
    #   IssueRelation.prepend(RedmineTxMilestoneAutoScheduleHelper::IssueRelationPatch)
    module IssueRelationPatch

        # 제대로 동작하지 않는 레드마인 기본 기능 제거.
        def set_issue_to_dates(journal=nil)
            Rails.logger.info "[RedmineTxMilestone] set_issue_to_dates called"
            
            # 설정값 안전하게 접근
            use_redmine_auto_schedule = Setting.plugin_redmine_tx_milestone&.[]("setting_milestone_use_redmine_auto_schedule")
            
            if use_redmine_auto_schedule == 'true'
                Rails.logger.info "[RedmineTxMilestone] Using Redmine auto schedule"
                super(journal)
            else
                Rails.logger.info "[RedmineTxMilestone] Ignoring Redmine auto schedule"
                # 아무것도 하지 않음 (기본 동작 무시)
            end
        end
    end

    # 이슈 자동 스케줄링 유틸리티
    class AutoScheduler
        
        # === PUBLIC API ===
        
        # 사용자별 일정 정보 분석
        # @param user_id [Integer] 사용자 ID
        # @return [Hash] 일감 정보 해시
        #   - :all_issues - 모든 유효한 일감
        #   - :fixed_issues - 일정이 확정된 일감
        #   - :other_issues - 일정이 확정되지 않은 일감
        #   - :candidate_issues - 예상 시간이 있는 일감
        #   - :no_estimated_hours_issues - 예상 시간이 없는 일감
        def self.analyze_user_schedule(user_id)
          valid_status_ids = ( IssueStatus.in_progress_ids + IssueStatus.new_ids ).uniq
          issues = Issue.where( assigned_to_id: user_id ).where( status_id: valid_status_ids )
          analyze_issues_schedule(issues)
        end

        # 부모 일감 기준 관련 일감 일정 정보 분석
        # 부모+자식 일감과 관련 담당자들의 일정 확정된 이슈를 포함
        # @param parent_issue_id [Integer] 부모 일감 ID
        # @return [Hash] 일감 정보 해시
        #   - :all_issues - 모든 유효한 일감
        #   - :fixed_issues - 일정이 확정된 일감
        #   - :other_issues - 일정이 확정되지 않은 일감
        #   - :candidate_issues - 예상 시간이 있는 일감
        #   - :no_estimated_hours_issues - 예상 시간이 없는 일감
        def self.analyze_parent_schedule(parent_issue_id)
          valid_status_ids = ( IssueStatus.in_progress_ids + IssueStatus.new_ids ).uniq
          
          # 부모+자식 일감을 related_issues에 정리
          parent_issue = Issue.find( parent_issue_id )
          related_issues = parent_issue.self_and_descendants.where(status_id: valid_status_ids).to_a

          # 관련자들의 기타 일정 확정된 이슈를 모두 얻어온다.
          assigned_to_ids = related_issues.map { |issue| issue.assigned_to }.uniq
          etc_blocked_issues = Issue.where( assigned_to_id: assigned_to_ids )
                                    .where( status_id: valid_status_ids )
                                    .where.not( start_date: nil )
                                    .where.not( due_date: nil )
                                    .order( assigned_to_id: :desc )
          etc_blocked_issues = etc_blocked_issues.select { |issue| !related_issues.include?( issue ) }
          
          issues = ( related_issues + etc_blocked_issues ).uniq
          analyze_issues_schedule(issues)
        end
        
        # 일정 자동 배치
        # @param all_issues [Array<Issue>] 전체 일감 목록
        # @param issue_ids [Array<Integer>] 배치할 일감 ID 목록
        # @param assign_from_date [Date] 배치 시작 날짜 (기본값: 오늘)
        # @return [Array<Issue>] 일정이 배치된 일감 목록
        def self.auto_schedule_issues(all_issues, issue_ids, assign_from_date = Date.today)
          target_issues = all_issues.select { |issue| issue_ids.include?(issue.id) }

          # 이미 일정이 배치된 날짜들 정보를 정리해 둔다
          all_blocked_dates = blocked_dates_map_per_assignee(all_issues)

          #pp [ 'all_blocked_dates', all_blocked_dates ]

          # 1. priority가 큰 순서부터 정렬 (priority_id가 클수록 높은 우선순위)
          priority_sorted_issues = target_issues.sort_by do |issue|
            [
              (issue.fixed_version&.effective_date || assign_from_date + 10.years),
              -(issue.priority_id || 0),
              issue.id
            ]
          end

          # 2. 상호간 선행 일감 관계를 고려한 위상 정렬
          sorted_issues = topological_sort(priority_sorted_issues)
          Rails.logger.info "[RedmineTxMilestone] sorted_issues: #{sorted_issues.map(&:id)}"

          assigned_to_ids = target_issues.map(&:assigned_to_id).uniq
          
          assigned_dates = {} # 이미 배치된 일감들의 날짜를 추적
          assigned_to_ids.each do |assigned_to_id|
            assigned_dates[assigned_to_id] = {}
          end
          
          sorted_issues.each do |issue|
            next unless issue.estimated_hours.present?
            
            # 추정작업시간을 일수로 변환 (8시간 = 1일)
            work_days = (issue.estimated_hours / 8.0).ceil
            
            # 선행 일감들의 완료일을 고려하여 시작 가능한 날짜 계산
            search_start_date = assign_from_date
            latest_predecessor_end_date = issue.latest_predecessor_end_date(all_issues)

            if latest_predecessor_end_date.present?          
              search_start_date = [search_start_date, latest_predecessor_end_date + 1.day].max
            end

            start_date = find_available_start_date(
              search_start_date,
              work_days,
              all_blocked_dates[issue.assigned_to_id],
              assigned_dates[issue.assigned_to_id],
              issue.estimated_hours,
              issue.assigned_to
            )
            due_date = calculate_due_date(start_date, work_days, issue.assigned_to)

            #pp [ 'start_date', issue.id, search_start_date.strftime('%Y-%m-%d'), work_days, all_blocked_dates[issue.assigned_to_id], assigned_dates[issue.assigned_to_id], issue.estimated_hours, start_date.strftime('%Y-%m-%d') ]
            
            # 일감 업데이트
            issue.start_date = start_date
            issue.due_date = due_date

            # 사용된 날짜 범위를 기록
            if issue.estimated_hours.to_f < 8.0
              assigned_dates[issue.assigned_to_id][start_date] = 
                assigned_dates[issue.assigned_to_id][start_date].to_f + issue.estimated_hours.to_f
            else
              (start_date..due_date).each do |date| 
                assigned_dates[issue.assigned_to_id][date] = 
                  assigned_dates[issue.assigned_to_id][date].to_f + 8.0
              end
            end
          end

          target_issues
        end

        # 일감 정보 정리 (내부용)
        # @param issues [Array<Issue>] 이슈 목록
        # @return [Hash] 일감 정보 해시
        #   - :all_issues - 모든 유효한 일감
        #   - :fixed_issues - 일정이 확정된 일감
        #   - :other_issues - 일정이 확정되지 않은 일감
        #   - :candidate_issues - 예상 시간이 있는 일감
        #   - :no_estimated_hours_issues - 예상 시간이 없는 일감
        def self.analyze_issues_schedule(issues)
          info = {}
          exception_tracker_ids = ( Tracker.sidejob_trackers_ids + Tracker.bug_trackers_ids + Tracker.exception_trackers_ids + Tracker.roadmap_trackers_ids ).uniq
      
          info[:all_issues] = issues.select{ |i| !exception_tracker_ids.include?( i.tracker_id ) && ( IssueStatus.in_progress_ids + IssueStatus.new_ids ).uniq.include?( i.status_id ) }
          
          # 일정이 확정된 일감
          info[:fixed_issues] = info[:all_issues].select { |issue| issue.is_in_progress? || (issue.start_date.present? && issue.due_date.present? ) }
      
          # 일정이 확정되지 않은 일감
          info[:other_issues] = ( info[:all_issues] - info[:fixed_issues] )
      
          # 일정이 확정되지 않은 일감 중 예상 시간이 있는 일감
          info[:candidate_issues] = info[:other_issues].select { |issue| issue.estimated_hours.present? }
      
          info[:no_estimated_hours_issues] = info[:other_issues].select { |issue| !issue.estimated_hours.present? }
      
          info
        end

        # === PRIVATE IMPLEMENTATION ===
        
        class << self
          private
          

          # 이슈 관계를 기반으로 위상정렬 수행
          # blocks/precedes 관계와 follows/blocked 관계를 모두 고려
          def topological_sort(issues)
            # 차단 관계 그래프 구축
            blocked_by = {}  # issue => [blocking_issues]
            blocking = {}    # issue => [blocked_issues]
            
            issues.each do |issue|
              blocked_by[issue] = []
              blocking[issue] = []
            end
            
            # 모든 관계를 수집하고 위상정렬에 사용할 의존관계 구축
            issues.each do |issue|
              issue.relations.each do |relation|
                # 관계의 상대방 이슈가 정렬 대상에 포함되어야 함
                other_issue = nil
                issue_first = false
                
                # 관계 타입에 따른 선후 관계 결정
                case relation.relation_type
                when 'precedes', 'blocks'
                  # A precedes/blocks B: A가 먼저 처리되어야 함
                  if relation.issue_from_id == issue.id
                    other_issue = issues.find { |i| i.id == relation.issue_to_id }
                    issue_first = true
                  elsif relation.issue_to_id == issue.id
                    other_issue = issues.find { |i| i.id == relation.issue_from_id }
                    issue_first = false
                  end
                  
                when 'follows', 'blocked'
                  # A follows/blocked by B: B가 먼저 처리되어야 함
                  if relation.issue_from_id == issue.id
                    other_issue = issues.find { |i| i.id == relation.issue_to_id }
                    issue_first = false
                  elsif relation.issue_to_id == issue.id
                    other_issue = issues.find { |i| i.id == relation.issue_from_id }
                    issue_first = true
                  end
                end

                # 의존관계 설정 (중복 방지)
                if other_issue
                  if issue_first
                    # 현재 issue가 먼저 처리되어야 함
                    unless blocking[issue].include?(other_issue)
                      blocking[issue] << other_issue
                      blocked_by[other_issue] << issue
                    end
                  else
                    # 상대방 issue가 먼저 처리되어야 함
                    unless blocking[other_issue].include?(issue)
                      blocking[other_issue] << issue
                      blocked_by[issue] << other_issue
                    end
                  end
                end
              end
            end
            
            # 위상 정렬 수행 (우선순위 정렬 순서 유지)
            result = []
            issue_indices = {}
            issues.each_with_index { |issue, index| issue_indices[issue] = index }
            
            # 초기 큐는 우선순위 순서로 정렬
            queue = issues.select { |issue| blocked_by[issue].empty? }
            
            while queue.any?
              # 큐에서 우선순위가 가장 높은 이슈를 선택 (인덱스가 작은 것)
              current = queue.min_by { |issue| issue_indices[issue] }
              queue.delete(current)
              result << current
              
              # 현재 이슈가 차단하고 있던 이슈들의 차단 관계 제거
              blocking[current].each do |blocked_issue|
                blocked_by[blocked_issue].delete(current)
                
                # 더 이상 차단되지 않는 이슈는 큐에 추가
                if blocked_by[blocked_issue].empty?
                  queue << blocked_issue
                end
              end
            end
            
            # 순환 참조가 있는 경우 남은 이슈들을 우선순위대로 추가
            remaining = issues - result
            result + remaining
          end

          # 일정 박힌 이슈들을 취합하여 담당자별 일간 할당 시간 정보를 리턴
          # @param issues [Array<Issue>] 이슈 목록
          # @return [Hash] 담당자별 일간 할당 시간 맵
          # @example
          #   {
          #     1 => { Date.new(2025,1,1) => 8, Date.new(2025,1,2) => 4 },
          #     2 => { Date.new(2025,1,3) => 8, Date.new(2025,1,4) => 8 }
          #   }
          def blocked_dates_map_per_assignee(issues)

            # 일정 박힌 이슈들
            fixed_issues = issues.select { |issue| ( issue.is_in_progress? && issue.due_date.present? ) || (issue.start_date.present? && issue.due_date.present? ) }

            # 일정 박힌 이슈들 날짜 정리
            date_ranges = fixed_issues.filter_map { |issue| 
              next unless issue.due_date.present?
              start_date = [ Date.today, issue.start_date ].compact.max
              { assigned_to_id: issue.assigned_to_id, range: start_date..issue.due_date, estimated_hours: issue.estimated_hours }
            }.sort_by{ |info| info[:range].begin }

            all_blocked_dates = {}

            assigned_to_ids = issues.map { |issue| issue.assigned_to_id }.uniq
            assigned_to_ids.each do |assigned_to_id|
              all_blocked_dates[assigned_to_id] = {}
            end

            assigned_to_ids.each do |assigned_to_id|

              # 이틀 이상의 기간 중 겹치는 기간들을 병합
              merged_ranges = []
              date_ranges.select { |info| info[:range].begin != info[:range].end && info[:assigned_to_id] == assigned_to_id }.each do |info|
                  range = info[:range]
                  if merged_ranges.empty? || merged_ranges.last.end < range.begin - 1.day
                    # 완전히 분리된 기간인 경우 새로 추가
                    merged_ranges << range
                  else
                    # 겹치거나 연속되는 경우 기간을 확장
                    last_range = merged_ranges.last
                    new_end = [last_range.end, range.end].max
                    merged_ranges[-1] = last_range.begin..new_end
                  end
              end
              
              # 병합된 기간들에서 모든 날짜를 추출
              array_blocked_dates = merged_ranges.flat_map(&:to_a)

              # 하루 8시간 할당으로 처리
              all_blocked_dates[assigned_to_id] = array_blocked_dates.map { |date| [ date, 8 ] }.to_h
            end      
            
            # 하루짜리 일정 처리      
            date_ranges.select { |info| info[:range].begin == info[:range].end }.each do |info|
              all_blocked_dates[info[:assigned_to_id]][info[:range].begin] = all_blocked_dates[info[:assigned_to_id]][info[:range].begin].to_f + ( info[:estimated_hours] ? info[:estimated_hours].to_f : 8.0 )
            end

            return all_blocked_dates
          end   
    
          def is_working_day?(date, user = nil)

            # 공휴일 얻어두기
            if TxBaseHelper::HolidayApi.available?
              return false if TxBaseHelper::HolidayApi.holiday?(date)
            end

            # 담당자 휴가 확인 (그룹 배정 일감은 제외)
            if user.is_a?(User) && TxBaseHelper::UserVacationApi.available?
              return false if TxBaseHelper::UserVacationApi.on_vacation?(user, date)
            end

            return !date.saturday? && !date.sunday?
          end
    
          # 일정 배치 가능한 날짜 확인
          def find_available_start_date(start_from, work_days, blocked_dates, assigned_dates, estimated_hours, user = nil)
            current_date = start_from

            loop do
              # 3. start_date는 토요일이나 일요일이 되어선 안됨
              while !is_working_day?(current_date, user)
                current_date += 1.day
              end

              # 현재 날짜부터 작업 기간만큼의 due_date 계산
              tentative_due_date = calculate_due_date(current_date, work_days, user)

              # 4. start_date ~ due_date가 다른 일감의 기간 혹은 blocked_dates와 중첩되지 않는지 확인
              if !date_range_overlaps?(current_date, tentative_due_date, blocked_dates, assigned_dates, estimated_hours)
                return current_date
              end

              # 중첩되면 다음 날로 이동
              current_date += 1.day
            end

            return nil
          end
      
          # 공휴일/휴가를 고려한 due_date 계산
          def calculate_due_date(start_date, work_days, user = nil)
            current_date = start_date
            remaining_days = work_days - 1 # start_date도 하루로 카운트

            while remaining_days > 0
              current_date += 1.day
              # 주말(토요일, 일요일), 공휴일, 휴가는 작업일에 포함하지 않음
              if is_working_day?(current_date, user)
                remaining_days -= 1
              end
            end

            current_date
          end

          # 일정 중첩 여부 확인
          def date_range_overlaps?(start_date, due_date, blocked_dates, assigned_dates, estimated_hours)
            day_estimated_hours = [8.0, estimated_hours.to_f].min
            (start_date..due_date).any? { |date| 
              blocked_dates[date].to_f + assigned_dates[date].to_f + day_estimated_hours.to_f > 8.0
            } 
          end
        end
    end

    # Issue 인스턴스에 필요한 메서드들만 패치
    module IssuePatch
        extend ActiveSupport::Concern

        # 날짜 기반 예상 시간 계산
        def date_based_estimated_hours
          return estimated_hours if estimated_hours.present?
    
          if start_date.present? && due_date.present?
            start_date == due_date ? 8.0 : ( due_date - start_date + 1 ).to_f * 8.0
          else
            0.0
          end
        end
    
        # 차단 관계 확인
        def is_blocking?( issue )
          return true if self.relations.select { |r| ( r.relation_type == 'blocks' || r.relation_type == 'precedes' ) && r.issue_to_id == issue.id && r.issue_from_id == self.id }.any?
          return true if follow_issues.any? { |issue| self.is_blocking?(issue) }
          false
        end

        # 후행 일감 목록
        def follow_issues
          self.relations.select { |r| ( r.relation_type == 'blocks' || r.relation_type == 'precedes' ) && r.issue_from_id == self.id && r.issue_to_id != nil }.map { |r| r.issue_to }
        end

        # 후행 일감들의 예상 시간 합계
        def follow_issues_estimated_hours
          follow_issues = self.relations.select { |r| ( r.relation_type == 'blocks' && r.issue_from_id == self.id ) || ( r.relation_type == 'precedes' && r.issue_from_id == self.id ) }
          follow_issues.map { |r| r.issue_to.date_based_estimated_hours }.sum
        end
    
=begin
        def estimated_hours_plus
          if self.estimated_hours.present?
            if estimated_hours >= 8 then
              "#{estimated_hours / 8}일"
            else
              "#{estimated_hours}시간"
            end
          else
            nil
          end
        end
=end    
    
        # 선행 일감들의 가장 늦은 완료일
        # @param issues_cache [Array<Issue>] 캐시된 이슈 목록 (성능 최적화용)
        # @return [Date, nil] 선행 일감들 중 가장 늦은 완료일
        def latest_predecessor_end_date( issues_cache = nil )

          # 선행 일감들 찾기 (이 일감을 후행하는 관계들)
          predecessor_issue_ids = self.relations.map { |r| 
            if (r.relation_type == 'precedes' || r.relation_type == 'blocks' ) && r.issue_to_id == self.id then
              r.issue_from_id
            elsif (r.relation_type == 'follows' || r.relation_type == 'blocked' ) && r.issue_from_id == self.id then
              r.issue_to_id
            else
              nil
            end
          }.compact.uniq

          #pp [ 'START latest_predecessor_end_date', self.id, predecessor_issue_ids ]
          
          if predecessor_issue_ids.any?
            # 선행 일감들의 완료일 중 가장 늦은 날짜 반환
            latest_dates = predecessor_issue_ids.map { |id|
              in_list = issues_cache&.find { |i| i.id == id }
              predecessor_issue = in_list ? in_list : Issue.find(id)
              #pp [ 'predecessor_issue', id, in_list ? 'in_list' : 'not_in_list', predecessor_issue.due_date ]
              predecessor_issue.due_date
            }.compact

            latest_date = latest_dates.max

            #pp [ 'END latest_predecessor_end_date', self.id, latest_dates, latest_date ] 
            
            return latest_date
          end
    
          nil
        end
    
        
        # 레드마인 기본 working_duration은 estimated_hours를 무시하므로 오버라이드
        # @return [Integer] 작업 소요 일수
        def working_duration
          if self.estimated_hours.present?
            (estimated_hours / 8.0).ceil
          else
            super()
          end
        end
    end
end
