module RedmineTxMilestoneHelper

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

  module_function :get_version_color, :build_issue_query, :render_issues

  class RedmineTxMilestoneHook < Redmine::Hook::ViewListener
    # HTML head에 JS와 CSS 추가
     def view_issues_show_details_bottom( c={} )

       return unless Tracker.is_in_roadmap?( c[:issue].tracker_id )

      link = link_to "로드맵", "/projects/#{c[:project].identifier}/milestone/gantt/issues/#{c[:issue].id}"
        o = <<EOS
<script>
	$(document).ready(function() {
		$('div.subject h3').append( \" <font size=-1>[#{link.gsub('"', '\"')}]</font>\" ); 
	});
</script>
EOS
     end
  end

  module VersionPatch
    def marks
      return [] unless effective_date
      date_marks = []
      (1..5).each do |i|
          v1 = Setting[:plugin_redmine_tx_milestone]["setting_milestone_days_#{i}"]
          v2 = Setting[:plugin_redmine_tx_milestone]["setting_milestone_title_#{i}"]
          next if v1 == '' || v1 == nil

          date = (effective_date - v1.to_i.days).to_date

          date_marks.push({ date: , name: v2 })
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
  end

  

  

end