# frozen_string_literal: true

require 'mini_magick'
require 'tempfile'

module RedmineTxMilestone
  class SlackDashboardNotifier
    FONT = 'Noto-Sans-CJK-KR'
    IMG_WIDTH = 800
    TIMELINE_HEIGHT = 100
    CHART_HEIGHT = 200
    BAR_Y = 45
    BAR_H = 28
    BAR_LEFT = 60
    BAR_RIGHT = IMG_WIDTH - 40
    BAR_W = BAR_RIGHT - BAR_LEFT

    class << self
      # Build dashboard payload for external consumers (e.g. slack_reminder plugin).
      # Caller is responsible for closing the returned Tempfiles.
      # @param version_id [Integer]
      # @return [Hash] { text: String, footer: String, images: [Tempfile, ...] }
      def build_dashboard_payload(version_id)
        overview = SummaryService.dashboard_overview(version_id)
        return nil if overview[:error]

        version = Version.find(version_id)
        project = version.project

        bug_data = build_bug_data(project, version_id)
        timeline_img = generate_timeline_image(overview)
        chart_img = bug_data.present? ? generate_bug_chart_image(bug_data) : nil

        text, footer = build_slack_text(overview, project)

        { text: text, footer: footer, images: [timeline_img, chart_img].compact }
      end

      private

      # ─── Text message ──────────────────────────────────────────

      def build_slack_text(overview, project)
        v = overview[:version]
        roadmap = overview[:roadmap_issues]
        alerts = overview[:alerts]
        risk_top = overview[:assignee_risk_top]

        done_ratio = v[:done_ratio].is_a?(Float) ? v[:done_ratio].round(1) : v[:done_ratio]

        lines = []
        lines << "*#{v[:name]}* (완료율: #{done_ratio}%)"

        meta = []
        meta << "개발마감: *#{v[:dev_deadline]}*" if v[:dev_deadline]
        meta << "릴리즈: *#{v[:due_date]}*" if v[:due_date]
        meta << "전체: #{v[:total_issues]}건 | 로드맵: #{roadmap.size}건"
        lines << meta.join(' | ')

        # Risk banner
        total_past = roadmap.sum { |r| (r[:descendant_stats] || {})[:past_dev_deadline].to_i }
        if v[:dev_deadline] && total_past > 0
          lines << ":rotating_light: *개발마감 초과 리스크* - 개발마감(#{v[:dev_deadline]}) 이후 완료 예정 실무 일감 *#{total_past}건*"
        end

        # Alerts summary
        if alerts.present?
          grouped = alerts.group_by { |a| a[:parent_id] }.sort_by { |_, list| -list.sum { |a| a[:count].to_i + a[:overdue_count].to_i } }
          lines << ""
          lines << "*알림* (#{grouped.size}건)"
          grouped.first(10).each do |parent_id, alert_list|
            parent_name = alert_list.first[:subject]
            parts = alert_list.map do |a|
              case a[:type]
              when 'past_dev_deadline'
                "마감초과 #{a[:count]}건"
              when 'overdue_descendants'
                "지연 #{a[:overdue_count]}건"
              when 'no_due_date_descendants'
                "일정없음 #{a[:count]}건"
              when 'not_started_descendants'
                "미개시 #{a[:count]}건"
              end
            end.compact
            lines << "  #{parent_name}: #{parts.join(', ')}"
          end
        end

        # Assignee risk top 5
        base_url = Setting.protocol + '://' + Setting.host_name
        if risk_top.present? && risk_top.any? { |r| r[:total] > 0 }
          lines << ""
          lines << "*담당자별 리스크 Top 5* (지연 + 미개시)"
          risk_top.each do |r|
            next if r[:total] == 0
            path = r[:type] == 'group' ? 'groups' : 'users'
            name_link = "<#{base_url}/#{path}/#{r[:id]}|#{r[:name]}>"
            lines << "  #{name_link}: 지연 #{r[:overdue]}건, 미개시 #{r[:not_started]}건 (합계 #{r[:total]}건)"
          end
        end

        # Dashboard link (returned separately as footer)
        dash_url = "#{base_url}/projects/#{project.identifier}/milestone/dashboard?version_id=#{overview[:version][:id]}"
        footer = "<#{dash_url}|:bar_chart: 대시보드 바로가기>"

        [lines.join("\n"), footer]
      end

      # ─── Timeline image ────────────────────────────────────────

      def generate_timeline_image(overview)
        v = overview[:version]
        marks = (v[:marks] || []).select { |m| m[:date].present? }
                  .map { |m| { date: Date.parse(m[:date]), name: m[:name], is_deadline: m[:is_deadline] } }
                  .sort_by { |m| m[:date] }

        tl_start = v[:timeline_start] ? Date.parse(v[:timeline_start]) : nil
        tl_end = v[:due_date] ? Date.parse(v[:due_date]) : nil
        return nil unless tl_start && tl_end && tl_start < tl_end

        tl_total = (tl_end - tl_start).to_i.to_f
        today_pct = [[(Date.today - tl_start).to_i / tl_total, 0].max, 1].min
        fill_x = BAR_LEFT + (BAR_W * today_pct).to_i

        tmpfile = Tempfile.new(['timeline', '.png'])

        MiniMagick::Tool::Convert.new do |c|
          c.size "#{IMG_WIDTH}x#{TIMELINE_HEIGHT}"
          c << 'xc:white'

          # Background bar
          c.fill '#e9ecef'
          c.draw "roundrectangle #{BAR_LEFT},#{BAR_Y} #{BAR_RIGHT},#{BAR_Y + BAR_H} 4,4"

          # Progress fill (today)
          if today_pct > 0
            c.fill '#5b9bd5'
            c.draw "roundrectangle #{BAR_LEFT},#{BAR_Y} #{fill_x},#{BAR_Y + BAR_H} 4,4"

            # "오늘" label inside bar
            c.fill 'white'
            c.pointsize '12'
            c.font FONT
            c.gravity 'NorthWest'
            text_x = [fill_x - 30, BAR_LEFT + 4].max
            text_y = BAR_Y + 8
            c.draw "text #{text_x},#{text_y} '오늘'"
          end

          # Mark lines and labels
          marks.each do |m|
            pct = [[(m[:date] - tl_start).to_i / tl_total, 0].max, 1].min
            mx = BAR_LEFT + (BAR_W * pct).to_i
            color = m[:is_deadline] ? '#e67e22' : '#6c757d'

            c.fill color
            c.draw "line #{mx},#{BAR_Y - 6} #{mx},#{BAR_Y + BAR_H + 6}"

            # Label above
            c.pointsize '10'
            c.font FONT
            c.fill color
            c.gravity 'NorthWest'
            label_x = mx - (m[:name].length * 5)
            c.draw "text #{[label_x, 2].max},#{BAR_Y - 18} '#{escape_im(m[:name])}'"

            # Date below
            date_str = m[:date].strftime('%-m/%-d')
            date_x = mx - (date_str.length * 3)
            c.fill '#999999'
            c.pointsize '10'
            c.draw "text #{[date_x, 2].max},#{BAR_Y + BAR_H + 10} '#{date_str}'"
          end

          # Edge dates
          c.fill '#999999'
          c.pointsize '10'
          c.font FONT
          c.gravity 'NorthWest'
          c.draw "text #{BAR_LEFT},#{BAR_Y + BAR_H + 22} '#{tl_start}'"
          c.gravity 'NorthWest'
          end_str = tl_end.to_s
          c.draw "text #{BAR_RIGHT - (end_str.length * 6)},#{BAR_Y + BAR_H + 22} '#{end_str}'"

          c << tmpfile.path
        end

        tmpfile
      end

      # ─── Bug chart image ───────────────────────────────────────

      def generate_bug_chart_image(bug_data)
        return nil if bug_data.empty?

        tmpfile = Tempfile.new(['bugchart', '.png'])
        data = bug_data.last(30) # last 30 days

        max_remaining = data.map { |d| d[:remaining] }.max.to_i
        max_bar = [data.map { |d| d[:created] }.max.to_i, data.map { |d| d[:completed] }.max.to_i].max
        max_remaining = [max_remaining, 1].max
        max_bar = [max_bar, 1].max

        chart_left = 70
        chart_right = IMG_WIDTH - 70
        chart_top = 30
        chart_bottom = CHART_HEIGHT - 30
        chart_w = chart_right - chart_left
        chart_h = chart_bottom - chart_top
        n = data.size
        col_w = chart_w.to_f / n

        MiniMagick::Tool::Convert.new do |c|
          c.size "#{IMG_WIDTH}x#{CHART_HEIGHT}"
          c << 'xc:white'

          # Title
          c.fill '#333333'
          c.pointsize '13'
          c.font FONT
          c.gravity 'NorthWest'
          c.draw "text #{chart_left},5 'BUG 해결 추이'"

          # Remaining bars (yellow)
          bar_w = [(col_w * 0.4).to_i, 2].max
          data.each_with_index do |d, i|
            next if d[:remaining] == 0
            cx = chart_left + (col_w * (i + 0.5)).to_i
            bh = (d[:remaining].to_f / max_remaining * chart_h * 0.9).to_i
            c.fill '#f0ad4e'
            c.draw "rectangle #{cx - bar_w / 2},#{chart_bottom - bh} #{cx + bar_w / 2},#{chart_bottom}"
          end

          # Remaining value labels
          c.fill '#333333'
          c.pointsize '9'
          c.font FONT
          step = [n / 6, 1].max
          data.each_with_index do |d, i|
            next unless (i % step == 0) || i == n - 1
            cx = chart_left + (col_w * (i + 0.5)).to_i
            y = chart_bottom - (d[:remaining].to_f / max_remaining * chart_h * 0.9).to_i
            c.draw "text #{cx - 8},#{[y - 6, chart_top].max} '#{d[:remaining]}'"
          end

          # Created line (red)
          created_points = data.each_with_index.map do |d, i|
            x = chart_left + (col_w * (i + 0.5)).to_i
            y = chart_bottom - (d[:created].to_f / max_bar * chart_h * 0.4).to_i
            "#{x},#{y}"
          end
          if created_points.size >= 2
            c.fill 'none'
            c.stroke '#e74c3c'
            c.strokewidth '2'
            c.draw "polyline #{created_points.join(' ')}"
            c.stroke 'none'
          end

          # Completed line (blue)
          completed_points = data.each_with_index.map do |d, i|
            x = chart_left + (col_w * (i + 0.5)).to_i
            y = chart_bottom - (d[:completed].to_f / max_bar * chart_h * 0.4).to_i
            "#{x},#{y}"
          end
          if completed_points.size >= 2
            c.fill 'none'
            c.stroke '#3498db'
            c.strokewidth '2'
            c.draw "polyline #{completed_points.join(' ')}"
            c.stroke 'none'
          end

          # X-axis labels (dates)
          c.fill '#999999'
          c.pointsize '9'
          label_step = [n / 8, 1].max
          data.each_with_index do |d, i|
            next unless (i % label_step == 0) || i == n - 1
            x = chart_left + (col_w * (i + 0.5)).to_i
            c.draw "text #{x - 12},#{chart_bottom + 12} '#{d[:date]}'"
          end

          # Legend
          legend_y = 8
          c.fill '#f0ad4e'
          c.draw "rectangle #{chart_right - 160},#{legend_y} #{chart_right - 150},#{legend_y + 10}"
          c.fill '#333'
          c.pointsize '10'
          c.draw "text #{chart_right - 147},#{legend_y} '잔여'"
          c.fill '#e74c3c'
          c.draw "rectangle #{chart_right - 115},#{legend_y} #{chart_right - 105},#{legend_y + 10}"
          c.fill '#333'
          c.draw "text #{chart_right - 102},#{legend_y} '생성'"
          c.fill '#3498db'
          c.draw "rectangle #{chart_right - 70},#{legend_y} #{chart_right - 60},#{legend_y + 10}"
          c.fill '#333'
          c.draw "text #{chart_right - 57},#{legend_y} '해결'"

          c << tmpfile.path
        end

        tmpfile
      end

      # ─── Bug data builder ──────────────────────────────────────

      def build_bug_data(project, version_id)
        controller = MilestoneController.new
        controller.instance_variable_set(:@project, project)
        issues_by_days, rest_issue_count, _, _, all_bug_issues, _ =
          controller.send(:process_bugs_data, Date.today, version_id)

        return [] unless issues_by_days.present?

        today_remaining = (rest_issue_count || {})['BUG'] || 0
        remaining = today_remaining

        bug_data = issues_by_days.map do |day_data|
          bug_cat = day_data[:issues_by_category]['BUG']
          created = bug_cat ? bug_cat[:created] : 0
          completed = bug_cat ? bug_cat[:completed] : 0
          entry = { date: day_data[:day].strftime('%m-%d'), created: created, completed: completed, remaining: remaining }
          remaining = remaining + completed - created
          entry
        end
        bug_data.reverse
      end

      def escape_im(str)
        str.gsub("'", "\\\\'")
      end
    end
  end
end
