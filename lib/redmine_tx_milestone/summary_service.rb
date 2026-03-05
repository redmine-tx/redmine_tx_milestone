module RedmineTxMilestone
  # Provides structured progress summaries for versions and parent issues.
  # Used by both Redmine views (dashboards) and external consumers (MCP chatbot).
  #
  # All public methods return plain Hash/Array structures — no ActiveRecord objects leak out.
  class SummaryService
    STAGE_IMPLEMENTED = 4   # 구현끝 이상 — 실질적 완료
    STAGE_DISCARDED   = -2  # 폐기
    STAGE_NEW         = 0   # 신규 — 미개시 판정 기준

    class << self
      # ─── Version Overview ──────────────────────────────────────
      # Returns a version with all top-level parent issues summarized,
      # plus standalone issue stats, stage distribution, and alerts.
      #
      # @param version_id [Integer]
      # @return [Hash] with keys :version, :parent_issues, :standalone, :stage_summary, :alerts
      def version_overview(version_id)
        version = Version.find(version_id)
        all_issues = version.fixed_issues.visible
                       .includes(:status, :tracker, :assigned_to, :priority, :category, :fixed_version)
                       .to_a

        parent_issues = all_issues.select { |i| i.children.any? }
        standalone_issues = all_issues.select { |i| i.parent_id.nil? && i.children.empty? }

        today = Date.today
        alerts = []
        stage_counts = Hash.new(0)

        parent_summaries = parent_issues.filter_map do |parent|
          children = parent.children.visible
                       .includes(:status, :tracker, :assigned_to, :priority, :category)
                       .to_a

          schedule_children = children.reject { |c| non_schedule_leaf?(c) }

          stage_name = stage_name_for(parent)
          stage_counts[stage_name] += 1

          open_children = schedule_children.reject { |c| c.status.is_closed? }
          closed_children = schedule_children.select { |c| c.status.is_closed? }
          overdue_children = open_children.select { |c| c.due_date && c.due_date < today }
          stale_children = open_children.select { |c| c.updated_on < 7.days.ago }
          unassigned_children = open_children.select { |c| c.assigned_to.nil? }

          # Alerts
          if overdue_children.any?
            alerts << {
              type: "overdue_children", parent_id: parent.id, subject: parent.subject,
              overdue_count: overdue_children.size,
              overdue_issues: overdue_children.map { |c| { id: c.id, subject: c.subject, due_date: c.due_date.iso8601, days_overdue: (today - c.due_date).to_i } }
            }
          end
          if !parent.status.is_closed? && parent.updated_on < 7.days.ago
            alerts << {
              type: "stale_parent", parent_id: parent.id, subject: parent.subject,
              days_since_update: ((Time.now - parent.updated_on) / 1.day).to_i
            }
          end

          {
            id: parent.id,
            subject: parent.subject,
            tracker: { id: parent.tracker_id, name: parent.tracker.name },
            status: format_status(parent),
            priority: parent.priority ? { id: parent.priority_id, name: parent.priority.name } : nil,
            assigned_to: format_user(parent.assigned_to),
            category: parent.category ? { id: parent.category_id, name: parent.category.name } : nil,
            stage: stage_name,
            done_ratio: parent.done_ratio,
            start_date: parent.start_date&.iso8601,
            due_date: parent.due_date&.iso8601,
            estimated_hours: parent.estimated_hours,
            is_closed: parent.status.is_closed?,
            tip: tip_fields(parent),
            children_stats: {
              total: schedule_children.size,
              completed: closed_children.size,
              in_progress: open_children.size,
              overdue: overdue_children.size,
              stale: stale_children.size,
              unassigned: unassigned_children.size,
              avg_done_ratio: schedule_children.size > 0 ? (schedule_children.sum { |c| c.done_ratio.to_i } / schedule_children.size.to_f).round(1) : 0,
              estimated_hours: schedule_children.sum { |c| c.estimated_hours.to_f },
              spent_hours: schedule_children.sum { |c| c.spent_hours.to_f }
            },
            type_breakdown: build_type_breakdown(children)
          }
        end

        # Standalone issues stage counts
        schedule_standalone = standalone_issues.reject { |i| non_schedule_leaf?(i) }
        schedule_standalone.each { |i| stage_counts[stage_name_for(i)] += 1 }
        standalone_open = schedule_standalone.reject { |i| i.status.is_closed? }
        standalone_overdue = standalone_open.select { |i| i.due_date && i.due_date < today }

        # Sort: overdue first, then by remaining work
        sorted = parent_summaries.sort_by do |p|
          [p[:children_stats][:overdue] > 0 ? 0 : 1, -(p[:children_stats][:total] - p[:children_stats][:completed])]
        end

        {
          version: {
            id: version.id,
            name: version.name,
            description: version.description,
            status: version.status,
            due_date: version.effective_date&.iso8601,
            done_ratio: version.completed_percent,
            overdue: version.overdue?,
            behind_schedule: version.behind_schedule?,
            total_issues: all_issues.size,
            created_on: version.created_on&.iso8601,
            updated_on: version.updated_on&.iso8601
          },
          parent_issues: sorted,
          standalone: {
            total: schedule_standalone.size,
            open: standalone_open.size,
            overdue: standalone_overdue.size
          },
          stage_summary: stage_counts,
          alerts: alerts
        }
      rescue ActiveRecord::RecordNotFound
        { error: "Version not found" }
      end

      # ─── Dashboard Overview ──────────────────────────────────────
      # Returns a version overview focused on roadmap issues (is_in_roadmap trackers).
      # Stats are calculated from ALL descendants (not just direct children),
      # excluding bug/exception leaf nodes from schedule metrics.
      #
      # @param version_id [Integer]
      # @return [Hash] with keys :version, :roadmap_issues, :stage_summary, :alerts
      def dashboard_overview(version_id)
        version = Version.find(version_id)
        roadmap_tracker_ids = Tracker.respond_to?(:roadmap_trackers_ids) ? Tracker.roadmap_trackers_ids : []

        all_issues = version.fixed_issues.visible
                       .includes(:status, :tracker, :assigned_to, :priority, :category)
                       .to_a

        roadmap_issues = all_issues.select { |i| roadmap_tracker_ids.include?(i.tracker_id) && !discarded?(i) }
        non_roadmap = all_issues.reject { |i| roadmap_tracker_ids.include?(i.tracker_id) }

        # Dev deadline from version marks (deadline flag)
        dev_deadline = nil
        if version.respond_to?(:marks)
          dev_mark = version.marks.find { |m| m[:is_deadline] }
          dev_deadline = dev_mark[:date] if dev_mark
        end

        today = Date.today
        alerts = []
        stage_counts = Hash.new(0)

        roadmap_summaries = roadmap_issues.map do |rm|
          # All descendants, not just direct children
          descendants = rm.descendants.visible
                          .includes(:status, :tracker, :assigned_to, :priority)
                          .to_a

          # Exclude discarded, then exclude bug/exception/sidejob leaf nodes
          descendants = descendants.reject { |d| discarded?(d) }
          schedule_descendants = descendants.reject { |d| non_schedule_leaf?(d) }
          work_leaves = schedule_descendants.select { |d| d.children.empty? }

          done_work = work_leaves.select { |d| implemented_or_above?(d) }
          open_work = work_leaves - done_work
          overdue_work = open_work.select { |d| d.due_date && d.due_date < today }
          no_due_date_work = open_work.select { |d| d.due_date.nil? }
          not_started_work = open_work.select { |d| d.start_date && d.start_date < today && d.status.respond_to?(:stage) && d.status.stage.to_i == STAGE_NEW }
          unassigned_work = open_work.select { |d| d.assigned_to.nil? }

          # Work leaves whose due_date exceeds dev deadline — risk to QA time
          past_dev_deadline = if dev_deadline
                                open_work.select { |d| d.due_date && d.due_date > dev_deadline }
                              else
                                []
                              end

          stage_name = stage_name_for(rm)
          stage_code = rm.status.respond_to?(:stage) ? rm.status.stage.to_i : 0
          stage_counts[stage_name] += 1

          if overdue_work.any?
            alerts << {
              type: "overdue_descendants", parent_id: rm.id, subject: rm.subject,
              overdue_count: overdue_work.size,
              overdue_issues: overdue_work.first(5).map { |d|
                { id: d.id, subject: d.subject, due_date: d.due_date.iso8601,
                  days_overdue: (today - d.due_date).to_i, assigned_to: format_user(d.assigned_to) }
              }
            }
          end
          if past_dev_deadline.any?
            alerts << {
              type: "past_dev_deadline", parent_id: rm.id, subject: rm.subject,
              count: past_dev_deadline.size,
              dev_deadline: dev_deadline.iso8601
            }
          end
          if no_due_date_work.any?
            alerts << {
              type: "no_due_date", parent_id: rm.id, subject: rm.subject,
              count: no_due_date_work.size
            }
          end
          if not_started_work.any?
            alerts << {
              type: "not_started", parent_id: rm.id, subject: rm.subject,
              count: not_started_work.size
            }
          end

          {
            id: rm.id,
            subject: rm.subject,
            tracker: { id: rm.tracker_id, name: rm.tracker.name },
            status: format_status(rm),
            priority: rm.priority ? { id: rm.priority_id, name: rm.priority.name } : nil,
            assigned_to: format_user(rm.assigned_to),
            category: rm.category ? { id: rm.category_id, name: rm.category.name } : nil,
            stage: stage_name,
            stage_code: stage_code,
            done_ratio: rm.done_ratio,
            start_date: rm.start_date&.iso8601,
            due_date: rm.due_date&.iso8601,
            is_closed: rm.status.is_closed?,
            descendant_stats: {
              total: work_leaves.size,
              implemented: done_work.size,
              in_progress: open_work.size,
              overdue: overdue_work.size,
              past_dev_deadline: past_dev_deadline.size,
              no_due_date: no_due_date_work.size,
              not_started: not_started_work.size,
              unassigned: unassigned_work.size,
              avg_done_ratio: work_leaves.size > 0 ? (work_leaves.sum { |d| d.done_ratio.to_i } / work_leaves.size.to_f).round(1) : 0,
              estimated_hours: work_leaves.sum { |d| d.estimated_hours.to_f },
              ids_total: work_leaves.map(&:id).join(','),
              ids_implemented: done_work.map(&:id).join(','),
              ids_overdue: overdue_work.map(&:id).join(','),
              ids_past_dev_deadline: past_dev_deadline.map(&:id).join(','),
              ids_no_due_date: no_due_date_work.map(&:id).join(','),
              ids_not_started: not_started_work.map(&:id).join(','),
            },
            type_breakdown: build_type_breakdown(descendants)
          }
        end

        # Non-roadmap stage counts (issues not under a roadmap parent)
        non_roadmap_roots = non_roadmap.select { |i| i.parent_id.nil? || !roadmap_issues.any? { |rm| rm.id == i.root_id } }
        schedule_others = non_roadmap_roots.reject { |i| non_schedule_leaf?(i) }
        schedule_others.each { |i| stage_counts[stage_name_for(i)] += 1 }
        other_open = schedule_others.reject { |i| i.status.is_closed? }
        other_overdue = other_open.select { |i| i.due_date && i.due_date < today }

        sorted = roadmap_summaries.sort_by do |r|
          [r[:stage_code] >= 4 ? 1 : 0,
           r[:descendant_stats][:overdue] > 0 ? 0 : 1,
           -(r[:descendant_stats][:total] - r[:descendant_stats][:implemented])]
        end

        {
          version: {
            id: version.id,
            name: version.name,
            description: version.description,
            status: version.status,
            due_date: version.effective_date&.iso8601,
            dev_deadline: dev_deadline&.iso8601,
            done_ratio: version.completed_percent,
            overdue: version.overdue?,
            behind_schedule: version.behind_schedule?,
            total_issues: all_issues.size,
          },
          roadmap_issues: sorted,
          other_issues: {
            total: schedule_others.size,
            open: other_open.size,
            overdue: other_overdue.size
          },
          stage_summary: stage_counts,
          alerts: alerts
        }
      rescue ActiveRecord::RecordNotFound
        { error: "Version not found" }
      end

      # ─── Children Summary ──────────────────────────────────────
      # Returns a parent issue with all children grouped by stage,
      # aggregate statistics, and alerts.
      #
      # @param parent_id [Integer]
      # @return [Hash] with keys :parent, :summary, :children_by_stage, :alerts
      def children_summary(parent_id)
        parent = Issue.visible.find(parent_id)
        children = parent.children.visible
                     .includes(:status, :tracker, :assigned_to, :priority, :category, :fixed_version)
                     .to_a

        today = Date.today
        grouped = {}
        alerts = []

        children.each do |child|
          stage = stage_name_for(child)

          grouped[stage] ||= []
          grouped[stage] << format_child(child)

          next if non_schedule_leaf?(child)

          if child.due_date && child.due_date < today && !child.status.is_closed?
            alerts << {
              type: "overdue", issue_id: child.id, subject: child.subject,
              assigned_to: format_user(child.assigned_to),
              due_date: child.due_date.iso8601,
              days_overdue: (today - child.due_date).to_i
            }
          end
          if child.assigned_to.nil? && !child.status.is_closed?
            alerts << { type: "unassigned", issue_id: child.id, subject: child.subject }
          end
          if !child.status.is_closed? && child.updated_on < 7.days.ago
            alerts << {
              type: "stale", issue_id: child.id, subject: child.subject,
              assigned_to: format_user(child.assigned_to),
              days_since_update: ((Time.now - child.updated_on) / 1.day).to_i
            }
          end
        end

        schedule_children = children.reject { |c| non_schedule_leaf?(c) }
        open_children = schedule_children.reject { |c| c.status.is_closed? }
        closed_children = schedule_children.select { |c| c.status.is_closed? }
        overdue_children = open_children.select { |c| c.due_date && c.due_date < today }

        {
          parent: format_issue_full(parent),
          summary: {
            total: schedule_children.size,
            completed: closed_children.size,
            in_progress: open_children.size,
            overdue: overdue_children.size,
            done_ratio: schedule_children.size > 0 ? (schedule_children.sum { |c| c.done_ratio.to_i } / schedule_children.size.to_f).round(1) : 0,
            estimated_hours: schedule_children.sum { |c| c.estimated_hours.to_f },
            spent_hours: schedule_children.sum { |c| c.spent_hours.to_f },
            type_breakdown: build_type_breakdown(children)
          },
          children_by_stage: grouped,
          alerts: alerts
        }
      rescue ActiveRecord::RecordNotFound
        { error: "Issue not found" }
      end

      private

      # ─── Formatting helpers ────────────────────────────────────

      def format_status(issue)
        status = issue.status
        result = {
          id: status.id,
          name: status.name,
          is_closed: status.is_closed?
        }
        result[:stage] = status.stage if status.respond_to?(:stage)
        result[:stage_name] = status.stage_name if status.respond_to?(:stage_name)
        result[:is_paused] = status.is_paused? if status.respond_to?(:is_paused?)
        result
      end

      def format_user(user)
        return nil unless user
        { id: user.id, name: user.name }
      end

      def tip_fields(issue)
        return nil unless issue.respond_to?(:guide_tag)
        code = issue.guide_tag
        return nil unless code
        { code: code.to_s, message: issue.tip }
      end

      def format_child(child)
        {
          id: child.id,
          subject: child.subject,
          tracker: { id: child.tracker_id, name: child.tracker.name },
          status: format_status(child),
          priority: child.priority ? { id: child.priority_id, name: child.priority.name } : nil,
          assigned_to: format_user(child.assigned_to),
          category: child.category ? { id: child.category_id, name: child.category.name } : nil,
          stage: stage_name_for(child),
          done_ratio: child.done_ratio,
          start_date: child.start_date&.iso8601,
          due_date: child.due_date&.iso8601,
          estimated_hours: child.estimated_hours,
          spent_hours: child.spent_hours,
          is_overdue: child.due_date && child.due_date < Date.today && !child.status.is_closed?,
          is_closed: child.status.is_closed?,
          updated_on: child.updated_on&.iso8601,
          tip: tip_fields(child)
        }
      end

      def format_issue_full(issue)
        {
          id: issue.id,
          subject: issue.subject,
          description: issue.description,
          project: { id: issue.project_id, name: issue.project.name, identifier: issue.project.identifier },
          tracker: { id: issue.tracker_id, name: issue.tracker.name },
          status: format_status(issue),
          priority: issue.priority ? { id: issue.priority_id, name: issue.priority.name } : nil,
          author: format_user(issue.author),
          assigned_to: format_user(issue.assigned_to),
          category: issue.category ? { id: issue.category_id, name: issue.category.name } : nil,
          fixed_version: issue.fixed_version ? { id: issue.fixed_version_id, name: issue.fixed_version.name } : nil,
          parent_issue: issue.parent ? { id: issue.parent_id, subject: issue.parent.subject } : nil,
          start_date: issue.start_date&.iso8601,
          due_date: issue.due_date&.iso8601,
          estimated_hours: issue.estimated_hours,
          spent_hours: issue.spent_hours,
          done_ratio: issue.done_ratio,
          created_on: issue.created_on&.iso8601,
          updated_on: issue.updated_on&.iso8601,
          closed_on: issue.closed_on&.iso8601,
          tip: tip_fields(issue)
        }
      end

      # ─── Classification helpers ────────────────────────────────

      def stage_name_for(issue)
        if issue.status.respond_to?(:stage_name) && issue.status.stage_name.present?
          issue.status.stage_name
        elsif issue.status.is_closed?
          "Completed"
        else
          issue.status.name
        end
      end

      # Stage >= 4 (구현끝 이상) is treated as done
      def implemented_or_above?(issue)
        issue.status.respond_to?(:stage) && issue.status.stage.to_i >= STAGE_IMPLEMENTED
      end

      # Discarded issues (stage -2) are excluded entirely
      def discarded?(issue)
        issue.status.respond_to?(:stage) && issue.status.stage.to_i == STAGE_DISCARDED
      end

      # Bug/exception/sidejob tracker leaf nodes are excluded from schedule calculations
      def non_schedule_leaf?(issue)
        return false unless Tracker.respond_to?(:is_bug?)
        issue.children.empty? && (Tracker.is_bug?(issue.tracker_id) || Tracker.is_exception?(issue.tracker_id) || Tracker.is_sidejob?(issue.tracker_id))
      end

      def build_type_breakdown(issues)
        return nil unless Tracker.respond_to?(:is_bug?)

        buckets = { work: [], bug: [], sidejob: [], exception: [] }
        issues.each do |i|
          tid = i.tracker_id
          if Tracker.is_bug?(tid)
            buckets[:bug] << i
          elsif Tracker.is_sidejob?(tid)
            buckets[:sidejob] << i
          elsif Tracker.is_exception?(tid)
            buckets[:exception] << i
          else
            buckets[:work] << i
          end
        end

        result = {}
        buckets.each do |type, list|
          next if list.empty?
          closed = list.count { |i| i.status.is_closed? }
          result[type] = { total: list.size, completed: closed, open: list.size - closed }
        end
        result.presence
      end
    end
  end
end
