/* TX Milestone 간트 차트
 * - 다중 차트 스크롤 동기화 (율리우스일 기준)
 * - 일정 드래그 편집 (이동/시작일/목표일) + 벌크 저장
 * - 행 하이라이트, 컨텍스트 메뉴, 툴팁 가드
 *
 * 사용법: 차트 파셜에서 TxMilestoneGanttChart.init(containerId) 호출.
 * 차트별 설정(cell 크기, 날짜 범위)은 컨테이너의 data-gantt-* 속성에서 읽는다.
 */
(function() {
  'use strict';

  function ensureGanttSyncManager() {
    if (window.TxMilestoneGanttSyncManager) {
      return window.TxMilestoneGanttSyncManager;
    }

    window.TxMilestoneGanttSyncManager = {
      isSyncing: false,

      register: function(sourceEl) {
        if (!sourceEl || sourceEl.getAttribute('data-gantt-sync-bound') === 'true') {
          return;
        }

        sourceEl.setAttribute('data-gantt-sync-bound', 'true');

        var manager = this;
        sourceEl.addEventListener('scroll', function() {
          manager.syncFrom(sourceEl);
        });
      },

      syncFrom: function(sourceEl) {
        if (this.isSyncing) {
          return;
        }

        var sourceCellWidth = parseFloat(sourceEl.getAttribute('data-gantt-cell-width'));
        var sourceStartJd = parseFloat(sourceEl.getAttribute('data-gantt-start-jd'));
        if (!sourceCellWidth || isNaN(sourceStartJd)) {
          return;
        }

        var visibleStartJd = sourceStartJd + (sourceEl.scrollLeft / sourceCellWidth);

        this.isSyncing = true;
        try {
          $('.gantt-container[data-gantt-sync="true"]').each(function(_, targetEl) {
            if (targetEl === sourceEl) {
              return;
            }

            var targetCellWidth = parseFloat(targetEl.getAttribute('data-gantt-cell-width'));
            var targetStartJd = parseFloat(targetEl.getAttribute('data-gantt-start-jd'));
            if (!targetCellWidth || isNaN(targetStartJd)) {
              return;
            }

            var targetScrollLeft = (visibleStartJd - targetStartJd) * targetCellWidth;
            var maxScrollLeft = Math.max(targetEl.scrollWidth - targetEl.clientWidth, 0);
            targetEl.scrollLeft = Math.max(0, Math.min(targetScrollLeft, maxScrollLeft));
          });
        } finally {
          this.isSyncing = false;
        }
      }
    };

    return window.TxMilestoneGanttSyncManager;
  }

  function setupGanttScheduleDrag($wrapper, ganttEl, cellWidth, cellHeight) {
    if (!ganttEl || ganttEl.getAttribute('data-gantt-schedule-drag-bound') === 'true') {
      return;
    }

    ganttEl.setAttribute('data-gantt-schedule-drag-bound', 'true');

    var chartStartJd = parseInt(ganttEl.getAttribute('data-gantt-start-jd'), 10);
    var chartEndJd = parseInt(ganttEl.getAttribute('data-gantt-end-jd'), 10);
    var chartStartDate = ganttEl.getAttribute('data-gantt-start-date');
    var activeDrag = null;
    var pendingChanges = {};
    var saveInProgress = false;
    var $bulkActions = $wrapper.find('[data-gantt-bulk-actions]');
    var $saveButton = $bulkActions.find('[data-gantt-save]');
    var $discardButton = $bulkActions.find('[data-gantt-discard]');

    function csrfToken() {
      var meta = document.querySelector('meta[name="csrf-token"]');
      return meta ? meta.getAttribute('content') : '';
    }

    function clamp(value, min, max) {
      return Math.max(min, Math.min(value, max));
    }

    function addDays(isoDate, days) {
      var parts = isoDate.split('-').map(function(part) { return parseInt(part, 10); });
      var date = new Date(Date.UTC(parts[0], parts[1] - 1, parts[2]));
      date.setUTCDate(date.getUTCDate() + days);
      return date.toISOString().slice(0, 10);
    }

    function isoFromJd(jd) {
      return addDays(chartStartDate, jd - chartStartJd);
    }

    function jdFromIso(isoDate) {
      if (!isoDate) {
        return null;
      }

      var startParts = chartStartDate.split('-').map(function(part) { return parseInt(part, 10); });
      var dateParts = isoDate.split('-').map(function(part) { return parseInt(part, 10); });
      var startDate = new Date(Date.UTC(startParts[0], startParts[1] - 1, startParts[2]));
      var targetDate = new Date(Date.UTC(dateParts[0], dateParts[1] - 1, dateParts[2]));
      var diffDays = Math.round((targetDate.getTime() - startDate.getTime()) / 86400000);
      return chartStartJd + diffDays;
    }

    function scheduleSelector(issueId) {
      return '[data-gantt-schedule="true"][data-issue-id="' + issueId + '"]';
    }

    function firstScheduleElement(issueId) {
      return $wrapper.find(scheduleSelector(issueId)).first()[0];
    }

    function optionalJd(element, attrName) {
      var value = element.getAttribute(attrName);
      if (value === null || value === '') {
        return null;
      }

      var parsed = parseInt(value, 10);
      return isNaN(parsed) ? null : parsed;
    }

    function scheduleStateForIssue(issueId) {
      var element = firstScheduleElement(issueId);
      if (!element) {
        return null;
      }

      var displayStartJd = optionalJd(element, 'data-start-jd');
      var displayDueJd = optionalJd(element, 'data-due-jd');
      var originalDisplayStartJd = optionalJd(element, 'data-original-display-start-jd');
      var originalDisplayDueJd = optionalJd(element, 'data-original-display-due-jd');
      if (displayStartJd === null || displayDueJd === null || originalDisplayStartJd === null || originalDisplayDueJd === null) {
        return null;
      }

      return {
        hasStartDate: element.getAttribute('data-has-start-date') === 'true',
        hasDueDate: element.getAttribute('data-has-due-date') === 'true',
        originalStartJd: optionalJd(element, 'data-original-start-jd'),
        originalDueJd: optionalJd(element, 'data-original-due-jd'),
        originalDisplayStartJd: originalDisplayStartJd,
        originalDisplayDueJd: originalDisplayDueJd,
        displayStartJd: displayStartJd,
        displayDueJd: displayDueJd,
        virtualSchedule: element.getAttribute('data-virtual-schedule') === 'true'
      };
    }

    function pendingCount() {
      return Object.keys(pendingChanges).length;
    }

    function updateBulkActions() {
      var count = pendingCount();
      if (!$bulkActions.length) {
        return;
      }

      if (count > 0) {
        $bulkActions.css('display', 'flex');
      } else {
        $bulkActions.hide();
      }

      $saveButton.prop('disabled', saveInProgress || count === 0);
      $discardButton.prop('disabled', saveInProgress || count === 0);
    }

    function rangeForDelta(drag, deltaDays) {
      if (drag.hasStartDate && !drag.hasDueDate) {
        var startOnlyJd = clamp(drag.editStartJd + deltaDays, chartStartJd, chartEndJd);
        return {
          startJd: startOnlyJd,
          dueJd: chartEndJd,
          editStartJd: startOnlyJd,
          editDueJd: null
        };
      }

      if (!drag.hasStartDate && drag.hasDueDate) {
        var dueOnlyJd = clamp(drag.editDueJd + deltaDays, chartStartJd, chartEndJd);
        return {
          startJd: chartStartJd,
          dueJd: dueOnlyJd,
          editStartJd: null,
          editDueJd: dueOnlyJd
        };
      }

      var durationDays = drag.dueJd - drag.startJd;
      var nextStartJd = drag.startJd;
      var nextDueJd = drag.dueJd;

      if (drag.mode === 'start') {
        nextStartJd = clamp(drag.startJd + deltaDays, chartStartJd, drag.dueJd);
      } else if (drag.mode === 'due') {
        nextDueJd = clamp(drag.dueJd + deltaDays, drag.startJd, chartEndJd);
      } else {
        nextStartJd = clamp(drag.startJd + deltaDays, chartStartJd, chartEndJd - durationDays);
        nextDueJd = nextStartJd + durationDays;
      }

      return {
        startJd: nextStartJd,
        dueJd: nextDueJd,
        editStartJd: nextStartJd,
        editDueJd: nextDueJd
      };
    }

    function updatePreview(drag, range) {
      var left = (range.startJd - drag.anchorJd) * cellWidth;
      var width = (range.dueJd - range.startJd + 1) * cellWidth;

      drag.preview.style.left = left + 'px';
      drag.preview.style.top = Math.max(cellHeight - 7, 0) + 'px';
      drag.preview.style.width = width + 'px';
    }

    function updateScheduleElements(issueId, startJd, dueJd, options) {
      options = options || {};
      var updateLine = options.updateLine !== false;
      var $elements = $wrapper.find(scheduleSelector(issueId));

      $elements.attr('data-start-jd', startJd);
      $elements.attr('data-due-jd', dueJd);

      $elements.each(function(_, element) {
        var $element = $(element);
        var anchorJd = parseInt(element.getAttribute('data-anchor-jd'), 10);
        var left = (startJd - anchorJd) * cellWidth;
        var width = (dueJd - startJd + 1) * cellWidth;
        var moveScheduleLine = $element.hasClass('gantt-schedule-line') && updateLine;

        if (moveScheduleLine || $element.hasClass('gantt-schedule-move-hit')) {
          element.style.left = left + 'px';
          element.style.width = width + 'px';
        } else if (element.getAttribute('data-drag-mode') === 'start') {
          element.style.left = (left - cellWidth) + 'px';
          element.style.display = startJd > chartStartJd ? '' : 'none';
        } else if (element.getAttribute('data-drag-mode') === 'due') {
          element.style.left = (left + width) + 'px';
          element.style.display = dueJd < chartEndJd ? '' : 'none';
        }

        if (moveScheduleLine) {
          $element.toggleClass('show-before', startJd >= chartStartJd);
          $element.toggleClass('show-after', dueJd <= chartEndJd);
        }
      });
    }

    function setOptionalJdAttr($elements, attrName, value) {
      if (value === null || typeof value === 'undefined') {
        $elements.attr(attrName, '');
      } else {
        $elements.attr(attrName, value);
      }
    }

    function updateOriginalRange(issueId, startJd, dueJd, displayStartJd, displayDueJd) {
      var $elements = $wrapper.find(scheduleSelector(issueId));
      setOptionalJdAttr($elements, 'data-original-start-jd', startJd);
      setOptionalJdAttr($elements, 'data-original-due-jd', dueJd);
      $elements.attr('data-original-display-start-jd', displayStartJd);
      $elements.attr('data-original-display-due-jd', displayDueJd);
    }

    function removePendingLine(issueId) {
      $wrapper.find('.gantt-schedule-pending-line[data-issue-id="' + issueId + '"]').remove();
    }

    function renderPendingLine(issueId, startJd, dueJd) {
      var sourceLine = $wrapper.find('.gantt-schedule-line[data-issue-id="' + issueId + '"]').first()[0] || firstScheduleElement(issueId);
      if (!sourceLine) {
        return;
      }

      var anchorJd = parseInt(sourceLine.getAttribute('data-anchor-jd'), 10);
      var sourceLane = $(sourceLine).closest('.task-lane')[0];
      if (!sourceLane || isNaN(anchorJd)) {
        return;
      }

      var pendingLine = $wrapper.find('.gantt-schedule-pending-line[data-issue-id="' + issueId + '"]').first()[0];
      if (!pendingLine) {
        pendingLine = document.createElement('div');
        pendingLine.className = 'gantt-schedule-pending-line';
        pendingLine.setAttribute('data-issue-id', issueId);
        pendingLine.setAttribute('data-issue-tooltip', issueId);
        sourceLane.appendChild(pendingLine);
      }

      pendingLine.classList.toggle('virtual', sourceLine.getAttribute('data-virtual-schedule') === 'true');
      pendingLine.style.left = ((startJd - anchorJd) * cellWidth) + 'px';
      pendingLine.style.top = Math.max(cellHeight - 8, 0) + 'px';
      pendingLine.style.width = ((dueJd - startJd + 1) * cellWidth) + 'px';
      pendingLine.setAttribute('title', isoFromJd(startJd) + ' - ' + isoFromJd(dueJd));
    }

    function setPendingChange(issueId, range, updateUrl) {
      var state = scheduleStateForIssue(issueId);
      if (!state) {
        return;
      }

      var sameStart = !state.hasStartDate || range.editStartJd === state.originalStartJd;
      var sameDue = !state.hasDueDate || range.editDueJd === state.originalDueJd;

      if (sameStart && sameDue) {
        delete pendingChanges[issueId];
        removePendingLine(issueId);
        updateScheduleElements(issueId, state.originalDisplayStartJd, state.originalDisplayDueJd);
        updateBulkActions();
        return;
      }

      pendingChanges[issueId] = {
        issue_id: parseInt(issueId, 10),
        has_start_date: state.hasStartDate,
        has_due_date: state.hasDueDate,
        start_jd: range.startJd,
        due_jd: range.dueJd,
        edit_start_jd: range.editStartJd,
        edit_due_jd: range.editDueJd,
        start_date: state.hasStartDate ? isoFromJd(range.editStartJd) : null,
        due_date: state.hasDueDate ? isoFromJd(range.editDueJd) : null,
        virtual_schedule: state.virtualSchedule,
        update_url: updateUrl
      };

      renderPendingLine(issueId, range.startJd, range.dueJd);
      updateScheduleElements(issueId, range.startJd, range.dueJd, { updateLine: false });
      updateBulkActions();
    }

    function clearActiveDrag() {
      if (!activeDrag) {
        return;
      }

      if (activeDrag.preview && activeDrag.preview.parentNode) {
        activeDrag.preview.parentNode.removeChild(activeDrag.preview);
      }

      $wrapper.removeClass('gantt-schedule-dragging');
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);
      activeDrag = null;
    }

    function onMouseMove(event) {
      if (!activeDrag) {
        return;
      }

      var deltaDays = Math.round((event.clientX - activeDrag.startClientX) / cellWidth);
      var range = rangeForDelta(activeDrag, deltaDays);
      activeDrag.nextStartJd = range.startJd;
      activeDrag.nextDueJd = range.dueJd;
      activeDrag.nextRange = range;
      activeDrag.changed = range.editStartJd !== activeDrag.editStartJd || range.editDueJd !== activeDrag.editDueJd;
      updatePreview(activeDrag, range);
    }

    function onMouseUp() {
      if (!activeDrag) {
        return;
      }

      var drag = activeDrag;
      document.removeEventListener('mousemove', onMouseMove);
      document.removeEventListener('mouseup', onMouseUp);

      if (!drag.changed) {
        clearActiveDrag();
        return;
      }

      setPendingChange(drag.issueId, drag.nextRange, drag.updateUrl);
      clearActiveDrag();
    }

    function pendingPayloads() {
      return Object.keys(pendingChanges).map(function(issueId) {
        var change = pendingChanges[issueId];
        return {
          issue_id: change.issue_id,
          start_date: change.start_date,
          due_date: change.due_date,
          start_jd: change.start_jd,
          due_jd: change.due_jd,
          edit_start_jd: change.edit_start_jd,
          edit_due_jd: change.edit_due_jd,
          has_start_date: change.has_start_date,
          has_due_date: change.has_due_date,
          virtual_schedule: change.virtual_schedule,
          update_url: change.update_url
        };
      });
    }

    function payloadForChange(change) {
      var payload = {
        issue_id: change.issue_id
      };

      if (change.has_start_date) {
        payload.start_date = change.start_date;
      }

      if (change.has_due_date) {
        payload.due_date = change.due_date;
      }

      return payload;
    }

    function applySavedScheduleChange(change, savedSchedule) {
      var issueId = String(change.issue_id);
      var savedStartJd = jdFromIso(savedSchedule.start_date);
      var savedDueJd = jdFromIso(savedSchedule.due_date);
      var displayStartJd = savedStartJd !== null ? savedStartJd : (savedDueJd !== null ? chartStartJd : change.start_jd);
      var displayDueJd = savedDueJd !== null ? savedDueJd : (savedStartJd !== null ? chartEndJd : change.due_jd);

      updateScheduleElements(issueId, displayStartJd, displayDueJd);
      updateOriginalRange(issueId, savedStartJd, savedDueJd, displayStartJd, displayDueJd);
      removePendingLine(issueId);
    }

    function applyVirtualScheduleChange(change) {
      var issueId = String(change.issue_id);
      updateScheduleElements(issueId, change.start_jd, change.due_jd);
      updateOriginalRange(issueId, change.edit_start_jd, change.edit_due_jd, change.start_jd, change.due_jd);
      removePendingLine(issueId);
    }

    function parseJsonResponse(response, fallbackMessage) {
      return response.text().then(function(text) {
        var data = {};
        try {
          data = text ? JSON.parse(text) : {};
        } catch (error) {
          data = {};
        }

        if (!response.ok || !data.success) {
          throw new Error(data.message || fallbackMessage);
        }
        return data;
      });
    }

    function saveChangesRequest(changes) {
      var bulkUpdateUrl = ganttEl.getAttribute('data-gantt-bulk-update-url');
      var headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'X-CSRF-Token': csrfToken()
      };

      if (bulkUpdateUrl) {
        return fetch(bulkUpdateUrl, {
          method: 'POST',
          credentials: 'same-origin',
          headers: headers,
          body: JSON.stringify({
            schedules: changes.map(function(change) {
              return payloadForChange(change);
            })
          })
        }).then(function(response) {
          return parseJsonResponse(response, '일정 저장에 실패했습니다.');
        });
      }

      return Promise.all(changes.map(function(change) {
        return fetch(change.update_url, {
          method: 'POST',
          credentials: 'same-origin',
          headers: headers,
          body: JSON.stringify(payloadForChange(change))
        }).then(function(response) {
          return parseJsonResponse(response, '일정 저장에 실패했습니다.');
        });
      }));
    }

    function savePendingChanges() {
      var changes = pendingPayloads();
      if (saveInProgress || changes.length === 0) {
        return;
      }

      var virtualChanges = changes.filter(function(change) {
        return change.virtual_schedule;
      });
      var persistedChanges = changes.filter(function(change) {
        return !change.virtual_schedule;
      });

      saveInProgress = true;
      $wrapper.addClass('gantt-schedule-bulk-saving');
      updateBulkActions();

      var request = persistedChanges.length > 0 ? saveChangesRequest(persistedChanges) : Promise.resolve({ schedules: [] });

      request.then(function(data) {
        var savedSchedules = Array.isArray(data) ? data : (data.schedules || []);
        var savedByIssueId = {};
        savedSchedules.forEach(function(savedSchedule) {
          savedByIssueId[String(savedSchedule.issue_id)] = savedSchedule;
        });

        persistedChanges.forEach(function(change) {
          var issueId = String(change.issue_id);
          var savedSchedule = savedByIssueId[issueId];
          if (!savedSchedule) {
            throw new Error('일정 저장 결과를 확인할 수 없습니다.');
          }

          applySavedScheduleChange(change, savedSchedule);
        });

        virtualChanges.forEach(function(change) {
          applyVirtualScheduleChange(change);
        });

        pendingChanges = {};
        saveInProgress = false;
        $wrapper.removeClass('gantt-schedule-bulk-saving');
        updateBulkActions();
      }).catch(function(error) {
        saveInProgress = false;
        $wrapper.removeClass('gantt-schedule-bulk-saving');
        updateBulkActions();
        alert(error.message || '일정 저장에 실패했습니다.');
      });
    }

    function discardPendingChanges() {
      if (saveInProgress) {
        return;
      }

      Object.keys(pendingChanges).forEach(function(issueId) {
        var state = scheduleStateForIssue(issueId);
        if (state) {
          updateScheduleElements(issueId, state.originalDisplayStartJd, state.originalDisplayDueJd);
        }
        removePendingLine(issueId);
      });

      pendingChanges = {};
      updateBulkActions();
    }

    $saveButton.on('click', savePendingChanges);
    $discardButton.on('click', discardPendingChanges);

    $wrapper.on('mousedown', '.gantt-schedule-draggable', function(event) {
      if (activeDrag || saveInProgress) {
        return;
      }

      if (event.button !== 0) {
        return;
      }

      var target = this;
      var issueId = target.getAttribute('data-issue-id');
      var startJd = parseInt(target.getAttribute('data-start-jd'), 10);
      var dueJd = parseInt(target.getAttribute('data-due-jd'), 10);
      var anchorJd = parseInt(target.getAttribute('data-anchor-jd'), 10);
      var updateUrl = target.getAttribute('data-update-url');
      var mode = target.getAttribute('data-drag-mode') || 'move';
      var sourceLane = $(target).closest('.task-lane')[0];
      var hasStartDate = target.getAttribute('data-has-start-date') === 'true';
      var hasDueDate = target.getAttribute('data-has-due-date') === 'true';

      if (!issueId || !updateUrl || !sourceLane || (!hasStartDate && !hasDueDate) || isNaN(startJd) || isNaN(dueJd) || isNaN(anchorJd)) {
        return;
      }

      event.preventDefault();
      event.stopPropagation();

      var preview = document.createElement('div');
      preview.className = 'gantt-schedule-drag-preview mode-' + mode;
      preview.setAttribute('data-issue-tooltip', issueId);
      sourceLane.appendChild(preview);

      activeDrag = {
        target: target,
        issueId: issueId,
        mode: mode,
        startClientX: event.clientX,
        startJd: startJd,
        dueJd: dueJd,
        editStartJd: hasStartDate ? startJd : null,
        editDueJd: hasDueDate ? dueJd : null,
        hasStartDate: hasStartDate,
        hasDueDate: hasDueDate,
        anchorJd: anchorJd,
        nextStartJd: startJd,
        nextDueJd: dueJd,
        nextRange: {
          startJd: startJd,
          dueJd: dueJd,
          editStartJd: hasStartDate ? startJd : null,
          editDueJd: hasDueDate ? dueJd : null
        },
        updateUrl: updateUrl,
        preview: preview,
        changed: false
      };

      $wrapper.addClass('gantt-schedule-dragging');
      updatePreview(activeDrag, { startJd: startJd, dueJd: dueJd });
      document.addEventListener('mousemove', onMouseMove);
      document.addEventListener('mouseup', onMouseUp);
    });
  }

  window.TxMilestoneGanttChart = {
    init: function(wrapperId) {
      var ganttEl = document.getElementById(wrapperId);
      if (!ganttEl) {
        return;
      }

      var cellWidth = parseFloat(ganttEl.getAttribute('data-gantt-cell-width')) || 18;
      var cellHeight = parseFloat(ganttEl.getAttribute('data-gantt-cell-height')) || 18;
      var todayIndex = parseInt(ganttEl.getAttribute('data-gantt-today-index'), 10) || 0;

      var initialScrollLeft = (todayIndex - 25) * cellWidth;
      var maxInitialScrollLeft = Math.max(ganttEl.scrollWidth - ganttEl.clientWidth, 0);
      ganttEl.scrollLeft = Math.max(0, Math.min(initialScrollLeft, maxInitialScrollLeft));
      ensureGanttSyncManager().register(ganttEl);

      // 캐싱
      var $wrapper = $('.mouseover-wrapper-' + wrapperId);
      var cursorEl = $wrapper.find('[class*="cursor-container-"]')[0];
      var $taskNameElements = $wrapper.find('.gantt-info-container .task-name');
      var headerHeight = $taskNameElements.first().outerHeight() || cellHeight * 2;
      var wrapperOffsetTop = null;

      setupGanttScheduleDrag($wrapper, ganttEl, cellWidth, cellHeight);

      // 행 하이라이트 - 이벤트 위임
      $wrapper.on('mouseenter', '.mouseover-' + wrapperId, function() {
        var rows = $wrapper.find('.mouseover-' + wrapperId);
        var rowIndex = rows.index(this);

        // 좌측 정보 영역과 우측 간트 차트 영역의 행을 구분
        if (rowIndex >= rows.length / 2) rowIndex = rowIndex - rows.length / 2;

        // 현재 간트차트 내의 요소들만 선택
        if ($taskNameElements.length > rowIndex + 1) { // +1은 헤더 제외
          var targetElement = $taskNameElements[rowIndex + 1];
          if (wrapperOffsetTop === null) wrapperOffsetTop = $wrapper.offset().top;
          var rowTop = $(targetElement).offset().top - wrapperOffsetTop;
          cursorEl.style.top = rowTop + 'px';
          cursorEl.style.height = cellHeight + 'px';
          cursorEl.style.display = 'block';
          return;
        }

        // fallback
        var rowTop = headerHeight + (rowIndex * cellHeight);
        cursorEl.style.top = rowTop + 'px';
        cursorEl.style.height = cellHeight + 'px';
        cursorEl.style.display = 'block';
      });

      $wrapper.on('mouseleave', function() {
        cursorEl.style.display = 'none';
        wrapperOffsetTop = null; // lazy 캐싱 리셋
      });

      var contextMenuTooltipGuardTimer = null;

      function hideTxIssueTooltip() {
        $('.tx-issue-tooltip, .tx-issue-tooltip-loading').hide();
      }

      function suppressTooltipWhileContextMenuOpen() {
        var startedAt = Date.now();

        if (contextMenuTooltipGuardTimer) {
          clearTimeout(contextMenuTooltipGuardTimer);
        }

        var watchContextMenu = function() {
          var contextMenuVisible = $('#context-menu').is(':visible');
          hideTxIssueTooltip();

          if (contextMenuVisible || Date.now() - startedAt < 1000) {
            $wrapper.addClass('tx-issue-no-tooltip');
            contextMenuTooltipGuardTimer = setTimeout(watchContextMenu, 150);
          } else {
            $wrapper.removeClass('tx-issue-no-tooltip');
            contextMenuTooltipGuardTimer = null;
          }
        };

        watchContextMenu();
      }

      // 간트 차트 우측 영역 컨텍스트 메뉴 지원
      $wrapper.on('contextmenu', '[data-issue-tooltip]', function(event) {
        var target = $(event.target);
        if (target.is('a:not(.js-contextmenu)')) return;

        var issueId = $(this).data('issue-tooltip');
        if (!issueId) return;

        var tr = $wrapper.find('#issue-' + issueId + '.hascontextmenu');
        if (tr.length < 1) return;

        event.preventDefault();
        event.stopImmediatePropagation();
        hideTxIssueTooltip();
        $wrapper.addClass('tx-issue-no-tooltip');

        if (!contextMenuIsSelected(tr)) {
          contextMenuUnselectAll();
          contextMenuAddSelection(tr);
          contextMenuSetLastSelected(tr);
        }
        contextMenuShow(event);
        suppressTooltipWhileContextMenuOpen();
      });
    }
  };
})();
