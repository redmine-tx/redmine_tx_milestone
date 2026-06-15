require File.expand_path('../test_helper', __dir__)
require 'ostruct'

class RedmineTxMilestoneHelperTest < ActiveSupport::TestCase
  include RedmineTxMilestoneHelper

  fixtures :projects,
           :users,
           :roles,
           :members,
           :member_roles,
           :issues,
           :issue_statuses,
           :versions,
           :trackers,
           :projects_trackers,
           :issue_categories,
           :enabled_modules,
           :enumerations,
           :attachments,
           :workflows,
           :issue_relations,
           :custom_fields,
           :custom_values,
           :custom_fields_projects,
           :custom_fields_trackers

  def setup
    @original_settings = Setting.plugin_redmine_tx_milestone
    @issue_1 = Issue.find(1)
    @issue_2 = Issue.find(2)
    @issue_1_original_tags = @issue_1.tag_list.dup
    @issue_2_original_tags = @issue_2.tag_list.dup

    @issue_1.tag_list = ['Major']
    @issue_2.tag_list = ['Hotfix']
    @issue_1.save!
    @issue_2.save!
  end

  def teardown
    @issue_1.tag_list = @issue_1_original_tags
    @issue_2.tag_list = @issue_2_original_tags
    @issue_1.save!
    @issue_2.save!
    Setting.plugin_redmine_tx_milestone = @original_settings if @original_settings
  end

  def test_major_issue_tag_names_removes_blank_values
    settings = {
      'setting_milestone_major_issue_tags' => ['', 'Major', 'Major', 'Hotfix']
    }

    assert_equal %w[Major Hotfix], RedmineTxMilestoneHelper.major_issue_tag_names(settings)
  end

  def test_milestone_major_issues_keeps_existing_filter_when_tags_not_selected
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_major_issue_tags' => ['']
    )

    issues = milestone_major_issues([@issue_1, @issue_2]) { |issue| issue.id == @issue_1.id }

    assert_equal [@issue_1.id], issues.map(&:id)
  end

  def test_milestone_major_issues_filters_by_any_selected_tag
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_major_issue_tags' => %w[Hotfix Missing]
    )

    issues = milestone_major_issues([@issue_1, @issue_2])

    assert_equal [@issue_2.id], issues.map(&:id)
  end

  def test_auto_schedule_priority_custom_field_returns_configured_single_list_field
    field = IssueCustomField.find(1)
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_auto_schedule_priority_custom_field_id' => field.id.to_s
    )

    assert_equal field, RedmineTxMilestoneHelper.auto_schedule_priority_custom_field
    assert_equal :"cf_#{field.id}", RedmineTxMilestoneHelper.auto_schedule_priority_column_name
  end

  def test_auto_schedule_priority_custom_field_ignores_non_list_field
    field = IssueCustomField.find(6)
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_auto_schedule_priority_custom_field_id' => field.id.to_s
    )

    assert_nil RedmineTxMilestoneHelper.auto_schedule_priority_custom_field
    assert_nil RedmineTxMilestoneHelper.auto_schedule_priority_column_name
  end

  def test_issue_detail_schedule_summary_tracker_ids_removes_blank_and_duplicate_values
    settings = {
      'setting_milestone_issue_detail_schedule_summary_tracker_ids' => ['', '1', '1', '2', 'invalid']
    }

    assert_equal [1, 2], RedmineTxMilestoneHelper.issue_detail_schedule_summary_tracker_ids(settings)
  end

  def test_issue_detail_schedule_summary_enabled_for_configured_current_issue_tracker
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_issue_detail_schedule_summary_tracker_ids' => [@issue_1.tracker_id.to_s]
    )

    assert RedmineTxMilestoneHelper.issue_detail_schedule_summary_enabled?(@issue_1)
  end

  def test_issue_detail_schedule_summary_disabled_when_current_issue_tracker_is_not_configured
    unconfigured_tracker_id = Tracker.maximum(:id).to_i + 1
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_issue_detail_schedule_summary_tracker_ids' => [unconfigured_tracker_id.to_s]
    )

    assert_not RedmineTxMilestoneHelper.issue_detail_schedule_summary_enabled?(@issue_1)
  end

  def test_auto_schedule_priority_value_extracts_number_from_label
    field = IssueCustomField.create!(
      name: 'Auto schedule priority',
      field_format: 'list',
      possible_values: ['매우높음 (2)', '높음 (1)', '보통 (0)', '낮음 (-1)', '매우낮음 (-2)'],
      is_for_all: true,
      editable: true
    )
    issue = Issue.find(1)
    CustomValue.create!(
      customized: issue,
      custom_field: field,
      value: '매우낮음 (-2)'
    )

    assert_equal(-2, RedmineTxMilestoneHelper.auto_schedule_priority_value(issue.reload, field))
  end

  def test_auto_schedule_priority_value_ignores_decimal_numbers
    field = IssueCustomField.create!(
      name: 'Auto schedule priority decimal',
      field_format: 'list',
      possible_values: ['높음 1.5'],
      is_for_all: true,
      editable: true
    )
    issue = Issue.find(1)
    CustomValue.create!(
      customized: issue,
      custom_field: field,
      value: '높음 1.5'
    )

    assert_equal(0, RedmineTxMilestoneHelper.auto_schedule_priority_value(issue.reload, field))
  end

  def test_auto_schedule_priority_custom_field_sorts_before_redmine_priority
    field = IssueCustomField.create!(
      name: 'Auto schedule priority',
      field_format: 'list',
      possible_values: %w[100 0],
      is_for_all: true,
      editable: true
    )
    Setting.plugin_redmine_tx_milestone = (@original_settings || {}).merge(
      'setting_milestone_auto_schedule_priority_custom_field_id' => field.id.to_s
    )

    lower_redmine_priority_issue = Issue.find(1)
    higher_redmine_priority_issue = Issue.find(7)
    [lower_redmine_priority_issue, higher_redmine_priority_issue].each do |issue|
      issue.update_columns(
        assigned_to_id: 3,
        fixed_version_id: nil,
        start_date: nil,
        due_date: nil,
        estimated_hours: 8.0
      )
    end
    CustomValue.create!(
      customized: lower_redmine_priority_issue,
      custom_field: field,
      value: '100'
    )
    CustomValue.create!(
      customized: higher_redmine_priority_issue,
      custom_field: field,
      value: '0'
    )

    result = RedmineTxMilestoneAutoScheduleHelper::AutoScheduler.auto_schedule_issues(
      [lower_redmine_priority_issue.reload, higher_redmine_priority_issue.reload],
      [lower_redmine_priority_issue.id, higher_redmine_priority_issue.id],
      Date.new(2026, 6, 1)
    )

    assert_equal(
      [lower_redmine_priority_issue.id, higher_redmine_priority_issue.id],
      result.sort_by(&:start_date).map(&:id)
    )
  end

  def test_gantt_child_schedule_warning_map_marks_ancestor_when_descendant_is_missing_due_date
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    ignored_sidejob_child = gantt_issue_stub(id: 201, tracker_id: :sidejob, status_id: :open, start_date: nil, due_date: nil, ancestor_id: 100)
    ignored_implemented_child = gantt_issue_stub(id: 202, tracker_id: :work, status_id: :implemented, start_date: nil, due_date: nil, ancestor_id: 100)
    ignored_no_start_date_child = gantt_issue_stub(id: 203, tracker_id: :work, status_id: :open, start_date: nil, due_date: Date.today, ancestor_id: 100)
    ignored_discarded_child = gantt_issue_stub(id: 204, tracker_id: :work, status_id: :discarded, start_date: nil, due_date: nil, ancestor_id: 100)
    ignored_postponed_child = gantt_issue_stub(id: 205, tracker_id: :work, status_id: :postponed, start_date: nil, due_date: nil, ancestor_id: 100)
    triggering_child = gantt_issue_stub(id: 206, tracker_id: :work, status_id: :open, start_date: Date.today, due_date: nil, ancestor_id: 100)

    with_gantt_schedule_stubs do
      warning_map = gantt_child_schedule_warning_map(
        [parent],
        [
          ignored_sidejob_child,
          ignored_implemented_child,
          ignored_no_start_date_child,
          ignored_discarded_child,
          ignored_postponed_child,
          triggering_child
        ]
      )

      assert_equal true, warning_map[100]
      assert_equal [100], warning_map.keys
    end
  end

  def test_gantt_child_schedule_warning_map_ignores_discarded_and_postponed_descendants_without_due_date
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    discarded_child = gantt_issue_stub(id: 201, tracker_id: :work, status_id: :discarded, start_date: nil, due_date: nil, ancestor_id: 100)
    postponed_child = gantt_issue_stub(id: 202, tracker_id: :work, status_id: :postponed, start_date: nil, due_date: nil, ancestor_id: 100)

    with_gantt_schedule_stubs do
      warning_map = gantt_child_schedule_warning_map(
        [parent],
        [discarded_child, postponed_child]
      )

      assert_equal({}, warning_map)
    end
  end

  def test_gantt_child_schedule_warning_details_map_lists_issue_id_subject_and_reason
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    triggering_child = gantt_issue_stub(
      id: 201,
      tracker_id: :work,
      status_id: :open,
      subject: '완료기한 없는 자식 일감',
      start_date: Date.today,
      due_date: nil,
      ancestor_id: 100
    )

    with_gantt_schedule_stubs do
      warning_details_map = gantt_child_schedule_warning_details_map([parent], [triggering_child])

      assert_equal(
        [{ id: 201, subject: '완료기한 없는 자식 일감', reason: '완료기한 미기입' }],
        warning_details_map[100]
      )
    end
  end

  def test_gantt_prepare_issues_keeps_own_due_date_warning_separate_from_child_schedule_warning
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open, due_date: Date.today)
    descendant = gantt_issue_stub(id: 200, tracker_id: :work, status_id: :open, start_date: nil, due_date: nil, ancestor_id: 100)

    with_gantt_schedule_stubs do
      prepared = gantt_prepare_issues([parent, descendant], { 100 => 0, 200 => 1 }, [descendant])

      parent_info = prepared.find { |item| item[:issue].id == 100 }
      descendant_info = prepared.find { |item| item[:issue].id == 200 }

      assert_equal true, parent_info[:show_missing_child_schedule_warning]
      assert_equal [{ id: 200, subject: 'Issue 200', reason: '완료기한 미기입' }], parent_info[:missing_child_schedule_warning_details]
      assert_equal false, parent_info[:show_no_due_date_warning]
      assert_equal false, descendant_info[:show_missing_child_schedule_warning]
      assert_equal [], descendant_info[:missing_child_schedule_warning_details]
      assert_equal false, descendant_info[:show_no_due_date_warning]
    end
  end

  def test_gantt_status_periods_from_transitions_groups_paused_and_review_periods
    transitions = [
      status_transition(100, Date.new(2026, 4, 1), '1', 'paused'),
      status_transition(100, Date.new(2026, 4, 3), 'paused', 'work'),
      status_transition(100, Date.new(2026, 4, 4), 'work', 'review'),
      status_transition(100, Date.new(2026, 4, 5), 'review', 'review_wait'),
      status_transition(100, Date.new(2026, 4, 6), 'review_wait', 'implemented'),
      status_transition(101, Date.new(2026, 4, 7), 'work', 'review')
    ]

    periods = gantt_status_periods_from_transitions(
      transitions,
      {
        paused: %w[paused],
        review: %w[review review_wait]
      }
    )

    assert_equal(
      [{ entered_at: Date.new(2026, 4, 1), exited_at: Date.new(2026, 4, 3) }],
      periods[:paused][100]
    )
    assert_equal(
      [{ entered_at: Date.new(2026, 4, 4), exited_at: Date.new(2026, 4, 6) }],
      periods[:review][100]
    )
    assert_equal(
      [{ entered_at: Date.new(2026, 4, 7), exited_at: nil }],
      periods[:review][101]
    )
  end

  def test_gantt_bar_period_segment_clips_period_to_visible_bar
    segment = gantt_bar_period_segment(
      { entered_at: Date.new(2026, 4, 1), exited_at: Date.new(2026, 4, 5) },
      Date.new(2026, 4, 3),
      Date.new(2026, 4, 4),
      18
    )

    assert_equal({ left_px: 0, width_px: 36 }, segment)
  end

  def test_gantt_parent_planning_segments_map_collects_direct_child_planning_ranges
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    planning_child = gantt_issue_stub(id: 300, tracker_id: :planning, status_id: :open, parent_id: 100, start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 10))
    non_planning_child = gantt_issue_stub(id: 301, tracker_id: :work, status_id: :open, parent_id: 100, start_date: Date.new(2026, 4, 11), due_date: Date.new(2026, 4, 12))

    with_gantt_schedule_stubs do
      assert_equal(
        { 100 => [{ start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 10) }] },
        gantt_parent_planning_segments_map([parent, planning_child, non_planning_child])
      )
    end
  end

  def test_gantt_schedule_line_css_classes_returns_planning_for_planning_issue
    planning_issue = gantt_issue_stub(id: 400, tracker_id: :planning, status_id: :open)

    with_gantt_schedule_stubs do
      assert_equal 'planning', gantt_schedule_line_css_classes(planning_issue)
    end
  end

  def test_gantt_schedule_line_css_classes_keeps_virtual_priority_over_planning
    planning_issue = gantt_issue_stub(id: 401, tracker_id: :planning, status_id: :open)

    with_gantt_schedule_stubs do
      assert_equal 'virtual', gantt_schedule_line_css_classes(planning_issue, [401])
    end
  end

  def test_gantt_schedule_line_edge_css_classes_marks_both_edges_when_planning_reaches_visible_bounds
    planning_segments = [
      { start_date: Date.new(2026, 4, 8), due_date: Date.new(2026, 4, 12) }
    ]

    assert_equal(
      'planning-before planning-after',
      gantt_schedule_line_edge_css_classes(
        planning_segments,
        Date.new(2026, 4, 9),
        Date.new(2026, 4, 12)
      )
    )
  end

  def test_gantt_schedule_line_edge_css_classes_ignores_segments_that_do_not_touch_visible_edges
    planning_segments = [
      { start_date: Date.new(2026, 4, 10), due_date: Date.new(2026, 4, 11) }
    ]

    assert_equal(
      '',
      gantt_schedule_line_edge_css_classes(
        planning_segments,
        Date.new(2026, 4, 9),
        Date.new(2026, 4, 12)
      )
    )
  end

  def test_gantt_delayed_schedule_segment_returns_extension_after_first_due_date
    issue = gantt_issue_stub(
      id: 500,
      tracker_id: :work,
      status_id: :open,
      start_date: Date.new(2026, 4, 9),
      due_date: Date.new(2026, 4, 14),
      first_due_date: Date.new(2026, 4, 11)
    )

    assert_equal(
      { start_date: Date.new(2026, 4, 12), due_date: Date.new(2026, 4, 14) },
      gantt_delayed_schedule_segment(issue, Date.new(2026, 4, 9), Date.new(2026, 4, 14))
    )
  end

  def test_gantt_delayed_schedule_segment_returns_nil_without_delay
    issue = gantt_issue_stub(
      id: 501,
      tracker_id: :work,
      status_id: :open,
      start_date: Date.new(2026, 4, 9),
      due_date: Date.new(2026, 4, 11),
      first_due_date: Date.new(2026, 4, 11)
    )

    assert_nil gantt_delayed_schedule_segment(issue, Date.new(2026, 4, 9), Date.new(2026, 4, 11))
  end

  def test_gantt_delayed_schedule_age_class_distinguishes_recent_delay_days
    today = Date.new(2026, 4, 15)

    0.upto(5) do |age_days|
      issue = gantt_issue_stub(
        id: 510 + age_days,
        tracker_id: :work,
        status_id: :open,
        end_date_delayed_on: today - age_days.days
      )

      assert_equal "delayed-age-#{age_days}", gantt_delayed_schedule_age_class(issue, today)
    end
  end

  def test_gantt_delayed_schedule_age_class_groups_old_or_untracked_delay
    today = Date.new(2026, 4, 15)

    old_issue = gantt_issue_stub(
      id: 520,
      tracker_id: :work,
      status_id: :open,
      end_date_delayed_on: today - 6.days
    )
    untracked_issue = gantt_issue_stub(id: 521, tracker_id: :work, status_id: :open)

    assert_equal 'delayed-age-old', gantt_delayed_schedule_age_class(old_issue, today)
    assert_equal 'delayed-age-old', gantt_delayed_schedule_age_class(untracked_issue, today)
  end

  def test_gantt_parent_planning_segments_map_treats_due_only_planning_child_as_single_day_segment
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    planning_child = gantt_issue_stub(id: 302, tracker_id: :planning, status_id: :open, parent_id: 100, start_date: nil, due_date: Date.new(2026, 4, 9))

    with_gantt_schedule_stubs do
      assert_equal(
        { 100 => [{ start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 9) }] },
        gantt_parent_planning_segments_map([parent, planning_child])
      )
    end
  end

  def test_gantt_parent_planning_segments_map_merges_overlapping_and_adjacent_ranges
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    first_planning_child = gantt_issue_stub(id: 303, tracker_id: :planning, status_id: :open, parent_id: 100, start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 10))
    second_planning_child = gantt_issue_stub(id: 304, tracker_id: :planning, status_id: :open, parent_id: 100, start_date: Date.new(2026, 4, 11), due_date: Date.new(2026, 4, 12))
    separate_planning_child = gantt_issue_stub(id: 305, tracker_id: :planning, status_id: :open, parent_id: 100, start_date: Date.new(2026, 4, 14), due_date: Date.new(2026, 4, 14))

    with_gantt_schedule_stubs do
      assert_equal(
        {
          100 => [
            { start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 12) },
            { start_date: Date.new(2026, 4, 14), due_date: Date.new(2026, 4, 14) }
          ]
        },
        gantt_parent_planning_segments_map([parent, first_planning_child, second_planning_child, separate_planning_child])
      )
    end
  end

  def test_gantt_parent_planning_segments_map_uses_provided_child_issues_when_display_list_has_only_parents
    parent = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open)
    planning_child = gantt_issue_stub(id: 306, tracker_id: :planning, status_id: :open, parent_id: 200, ancestor_id: 100, start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 9))

    with_gantt_schedule_stubs do
      assert_equal(
        { 100 => [{ start_date: Date.new(2026, 4, 9), due_date: Date.new(2026, 4, 9) }] },
        gantt_parent_planning_segments_map([parent], [planning_child])
      )
    end
  end

  def test_gantt_planning_line_bounds_uses_visible_planning_segment_range
    segments = [
      { start_date: Date.new(2026, 4, 1), due_date: Date.new(2026, 4, 3) },
      { start_date: Date.new(2026, 4, 5), due_date: Date.new(2026, 4, 8) }
    ]

    assert_equal(
      { start_date: Date.new(2026, 4, 2), due_date: Date.new(2026, 4, 6) },
      gantt_planning_line_bounds(segments, Date.new(2026, 4, 2), Date.new(2026, 4, 6))
    )
  end

  def test_gantt_planning_line_bounds_returns_nil_without_visible_segments
    segments = [
      { start_date: Date.new(2026, 4, 1), due_date: Date.new(2026, 4, 3) }
    ]

    assert_nil gantt_planning_line_bounds(segments, Date.new(2026, 4, 4), Date.new(2026, 4, 6))
  end

  def test_gantt_date_range_includes_extra_dates
    issue = gantt_issue_stub(id: 100, tracker_id: :work, status_id: :open, start_date: nil, due_date: nil)
    early_planning_date = Date.today - 40.days
    late_planning_date = Date.today + 45.days

    date_range = gantt_date_range([issue], {}, nil, [early_planning_date, late_planning_date])

    assert_operator date_range[:start_date], :<=, early_planning_date
    assert_operator date_range[:end_date], :>=, late_planning_date
  end

  def test_gantt_date_range_caps_stale_due_date_after_15_days
    due_date = Date.today - 90.days
    issue = gantt_issue_stub(
      id: 100,
      tracker_id: :work,
      status_id: :open,
      start_date: due_date - 5.days,
      due_date: due_date
    )

    date_range = gantt_date_range([issue], {}, due_date)

    assert_equal due_date + 15.days, date_range[:end_date]
    assert_operator date_range[:end_date], :<, Date.today
  end

  def test_gantt_date_range_keeps_late_issue_dates_for_stale_due_date
    due_date = Date.today - 90.days
    late_due_date = due_date + 30.days
    issue = gantt_issue_stub(
      id: 101,
      tracker_id: :work,
      status_id: :open,
      start_date: due_date - 5.days,
      due_date: late_due_date
    )

    date_range = gantt_date_range([issue], {}, due_date)

    assert_equal late_due_date + 5.days, date_range[:end_date]
    assert_operator date_range[:end_date], :<, Date.today
  end

  def test_gantt_date_range_uses_today_window_for_recent_due_date
    due_date = Date.today - 10.days
    issue = gantt_issue_stub(
      id: 102,
      tracker_id: :work,
      status_id: :open,
      start_date: due_date - 5.days,
      due_date: due_date
    )

    date_range = gantt_date_range([issue], {}, due_date)

    assert_operator date_range[:start_date], :<=, Date.today
    assert_operator date_range[:end_date], :>=, Date.today + 5.days
  end

  private

  def gantt_issue_stub(id:, tracker_id:, status_id:, subject: nil, parent_id: nil, start_date: Date.today, due_date: Date.today, first_due_date: nil, end_date_delayed_on: nil, ancestor_id: nil)
    OpenStruct.new(
      id: id,
      subject: subject || "Issue #{id}",
      tracker_id: tracker_id,
      status_id: status_id,
      parent_id: parent_id,
      start_date: start_date,
      due_date: due_date,
      first_due_date: first_due_date,
      end_date_delayed_on: end_date_delayed_on,
      ancestor_id: ancestor_id
    )
  end

  def status_transition(issue_id, created_on, old_value, value)
    OpenStruct.new(
      issue_id: issue_id,
      created_on: created_on,
      old_value: old_value,
      value: value
    )
  end

  def with_gantt_schedule_stubs(&block)
    Tracker.stub(:is_exception?, ->(tracker_id) { tracker_id == :exception }) do
      Tracker.stub(:is_sidejob?, ->(tracker_id) { tracker_id == :sidejob }) do
        Tracker.stub(:is_planning?, ->(tracker_id) { tracker_id == :planning }) do
          IssueStatus.stub(:is_implemented?, ->(status_id) { status_id == :implemented }) do
            IssueStatus.stub(:is_discarded?, ->(status_id) { status_id == :discarded }) do
              IssueStatus.stub(:is_postponed?, ->(status_id) { status_id == :postponed }, &block)
            end
          end
        end
      end
    end
  end
end
