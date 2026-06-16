/* TX Milestone schedule summary helpers */
(function(window, document) {
  'use strict';

  var MS_PER_DAY = 1000 * 60 * 60 * 24;
  var RESOLVED_SCHEDULES_CACHE_KEY = '__txMilestoneResolvedSchedules';

  function parseDate(dateStr) {
    return new Date(dateStr + 'T00:00:00');
  }

  function formatDate(date) {
    var year = date.getFullYear();
    var month = String(date.getMonth() + 1).padStart(2, '0');
    var day = String(date.getDate()).padStart(2, '0');
    return year + '-' + month + '-' + day;
  }

  function cloneSchedule(schedule) {
    var copy = {};
    for (var key in schedule) {
      if (Object.prototype.hasOwnProperty.call(schedule, key)) {
        copy[key] = schedule[key];
      }
    }
    return copy;
  }

  function clonePlainObject(source) {
    var copy = {};
    source = source || {};
    for (var key in source) {
      if (key !== RESOLVED_SCHEDULES_CACHE_KEY && Object.prototype.hasOwnProperty.call(source, key)) {
        copy[key] = source[key];
      }
    }
    return copy;
  }

  function calendarDayNumber(dateStr) {
    var parts = String(dateStr || '').split('-').map(function(part) {
      return parseInt(part, 10);
    });
    if (parts.length === 3 && parts.every(function(part) { return !isNaN(part); })) {
      return Math.floor(Date.UTC(parts[0], parts[1] - 1, parts[2]) / MS_PER_DAY);
    }
    return Math.floor(parseDate(dateStr).getTime() / MS_PER_DAY);
  }

  function resolveScheduleOverlaps(schedules) {
    if (!schedules || schedules.length <= 1) return schedules;

    var dayNumberCache = {};

    function dayNumber(dateStr) {
      if (!Object.prototype.hasOwnProperty.call(dayNumberCache, dateStr)) {
        dayNumberCache[dateStr] = calendarDayNumber(dateStr);
      }
      return dayNumberCache[dateStr];
    }

    function formatDateFromDayNumber(dayNum) {
      return new Date(dayNum * MS_PER_DAY).toISOString().slice(0, 10);
    }

    function durationDays(schedule) {
      return dayNumber(schedule.endDate) - dayNumber(schedule.startDate) + 1;
    }

    function addOccupiedRange(ranges, range) {
      var insertAt = ranges.length;
      while (insertAt > 0 && ranges[insertAt - 1].start > range.start) {
        insertAt -= 1;
      }
      ranges.splice(insertAt, 0, range);
    }

    var sorted = schedules.slice().sort(function(a, b) {
      if (a.isMuted !== b.isMuted) {
        return a.isMuted ? 1 : -1;
      }

      var startDiff = dayNumber(a.startDate) - dayNumber(b.startDate);
      return startDiff !== 0 ? startDiff : durationDays(b) - durationDays(a);
    });

    var result = [];
    var mainOccupiedRanges = [];
    var allOccupiedRanges = [];

    sorted.forEach(function(schedule) {
      var schedStart = dayNumber(schedule.startDate);
      var schedEnd = dayNumber(schedule.endDate);

      if (schedule.isMuted) {
        var periodsToProcess = [{ start: schedStart, end: schedEnd }];

        allOccupiedRanges.forEach(function(occupied) {
          var nextPeriods = [];

          periodsToProcess.forEach(function(period) {
            if (period.start <= occupied.end && period.end >= occupied.start) {
              if (period.start < occupied.start) {
                var beforeEnd = occupied.start - 1;
                if (beforeEnd >= period.start) {
                  nextPeriods.push({ start: period.start, end: beforeEnd });
                }
              }

              if (period.end > occupied.end) {
                var afterStart = occupied.end + 1;
                if (afterStart <= period.end) {
                  nextPeriods.push({ start: afterStart, end: period.end });
                }
              }
            } else {
              nextPeriods.push(period);
            }
          });

          periodsToProcess = nextPeriods;
        });

        periodsToProcess.forEach(function(period) {
          var adjustedSchedule = cloneSchedule(schedule);
          adjustedSchedule.startDate = formatDateFromDayNumber(period.start);
          adjustedSchedule.endDate = formatDateFromDayNumber(period.end);

          if (schedule.startDate !== adjustedSchedule.startDate || schedule.endDate !== adjustedSchedule.endDate) {
            adjustedSchedule.originalStartDate = schedule.startDate;
            adjustedSchedule.originalEndDate = schedule.endDate;
          }

          result.push(adjustedSchedule);
          addOccupiedRange(allOccupiedRanges, { start: period.start, end: period.end });
        });
      } else {
        var adjustedStart = schedStart;
        var adjustedEnd = schedEnd;

        mainOccupiedRanges.forEach(function(occupied) {
          if (adjustedStart <= occupied.end && adjustedEnd >= occupied.start) {
            var nextDay = occupied.end + 1;
            if (nextDay > adjustedStart) {
              adjustedStart = nextDay;
            }
          }
        });

        if (adjustedStart > adjustedEnd) return;

        var adjustedMainSchedule = cloneSchedule(schedule);
        adjustedMainSchedule.startDate = formatDateFromDayNumber(adjustedStart);
        adjustedMainSchedule.endDate = formatDateFromDayNumber(adjustedEnd);

        if (schedule.startDate !== adjustedMainSchedule.startDate) {
          adjustedMainSchedule.originalStartDate = schedule.startDate;
        }

        result.push(adjustedMainSchedule);
        var rangeEntry = { start: adjustedStart, end: adjustedEnd };
        addOccupiedRange(allOccupiedRanges, rangeEntry);
        addOccupiedRange(mainOccupiedRanges, rangeEntry);
      }
    });

    return result.sort(function(a, b) {
      return dayNumber(a.startDate) - dayNumber(b.startDate);
    });
  }

  function decorateFullDayVacationCells(containerSelector, data, vacationMap) {
    if (!vacationMap || Object.keys(vacationMap).length === 0) return;

    var container = document.querySelector(containerSelector);
    if (!container) return;

    var table = container.querySelector('.tx-timeline-table');
    if (!table) return;

    Array.prototype.forEach.call(table.querySelectorAll('td.tx-full-day-vacation-cell'), function(cell) {
      cell.classList.remove('tx-full-day-vacation-cell');
      Array.prototype.forEach.call(cell.querySelectorAll('.tx-full-day-vacation-segment'), function(segment) {
        if (segment.parentNode) segment.parentNode.removeChild(segment);
      });
    });

    var dayCells = Array.prototype.slice.call(table.querySelectorAll('thead .tx-day-row .tx-day-cell[data-day-index]'));
    var rowEls = Array.prototype.slice.call(table.querySelectorAll('tbody tr.tx-data-row'));
    if (!dayCells.length || !rowEls.length) return;

    var dayCellWidth = dayCells[0].getBoundingClientRect().width;
    var startDate = parseDate(data.options.startDate);
    var dayOfWeek = startDate.getDay();
    var daysToSubtract = dayOfWeek === 0 ? 6 : dayOfWeek - 1;
    if (daysToSubtract > 0) {
      startDate.setDate(startDate.getDate() - daysToSubtract);
    }

    var dateIndexByDate = {};
    dayCells.forEach(function(dayCell) {
      var dayIndex = parseInt(dayCell.getAttribute('data-day-index'), 10);
      if (isNaN(dayIndex)) return;

      var markerDate = new Date(startDate);
      markerDate.setDate(startDate.getDate() + dayIndex);
      dateIndexByDate[formatDate(markerDate)] = dayIndex;
    });

    var vacationDayIndexesByLogin = {};
    Object.keys(vacationMap).forEach(function(dateKey) {
      var dayIndex = dateIndexByDate[dateKey];
      if (typeof dayIndex !== 'number') return;

      var dayVacationMap = vacationMap[dateKey] || {};
      Object.keys(dayVacationMap).forEach(function(login) {
        if (!vacationDayIndexesByLogin[login]) {
          vacationDayIndexesByLogin[login] = [];
        }
        vacationDayIndexesByLogin[login].push(dayIndex);
      });
    });
    Object.keys(vacationDayIndexesByLogin).forEach(function(login) {
      vacationDayIndexesByLogin[login].sort(function(a, b) { return a - b; });
    });

    var rowIndex = 0;
    (data.categories || []).forEach(function(category) {
      (category.events || []).forEach(function(event) {
        var rowEl = rowEls[rowIndex];
        rowIndex += 1;
        if (!rowEl || !event.login) return;

        var vacationDayIndexes = vacationDayIndexesByLogin[event.login];
        if (!vacationDayIndexes || !vacationDayIndexes.length) return;

        var cellEntries = [];
        var dayCursor = 0;
        Array.prototype.forEach.call(rowEl.querySelectorAll('td.tx-schedule-cell'), function(cell) {
          var colspan = parseInt(cell.getAttribute('colspan') || '1', 10);
          var safeColspan = isNaN(colspan) || colspan < 1 ? 1 : colspan;

          cellEntries.push({
            cell: cell,
            startIndex: dayCursor,
            colspan: safeColspan
          });
          dayCursor += safeColspan;
        });

        var cellCursor = 0;
        vacationDayIndexes.forEach(function(dayIndex) {
          while (
            cellCursor < cellEntries.length &&
            dayIndex >= cellEntries[cellCursor].startIndex + cellEntries[cellCursor].colspan
          ) {
            cellCursor += 1;
          }

          var cellEntry = cellEntries[cellCursor];
          if (cellEntry && dayIndex < cellEntry.startIndex) return;
          if (!cellEntry) return;

          var cell = cellEntry.cell;
          cell.classList.add('tx-full-day-vacation-cell');
          if (!cell.classList.contains('tx-schedule-bar')) return;

          var segment = document.createElement('span');
          segment.className = 'tx-full-day-vacation-segment';
          segment.setAttribute('aria-hidden', 'true');
          segment.style.left = ((dayIndex - cellEntry.startIndex) * dayCellWidth) + 'px';
          segment.style.width = dayCellWidth + 'px';
          cell.appendChild(segment);
        });
      });
    });
  }

  function setResolvedSchedulesCache(event, schedules) {
    if (!event) return;

    try {
      Object.defineProperty(event, RESOLVED_SCHEDULES_CACHE_KEY, {
        value: schedules,
        writable: true,
        configurable: true
      });
    } catch (error) {
      event[RESOLVED_SCHEDULES_CACHE_KEY] = schedules;
    }
  }

  function resolvedSchedulesForEvent(event) {
    if (!event) return [];

    var cachedSchedules = event[RESOLVED_SCHEDULES_CACHE_KEY];
    if (!cachedSchedules) {
      cachedSchedules = resolveScheduleOverlaps((event.schedules || []).slice());
      setResolvedSchedulesCache(event, cachedSchedules);
    }

    return cachedSchedules.map(cloneSchedule);
  }

  function cloneEventWithResolvedSchedules(event) {
    var copy = clonePlainObject(event);
    copy.schedules = resolvedSchedulesForEvent(event);
    return copy;
  }

  function cloneCategoryWithEvents(category, hiddenEvents) {
    var copy = clonePlainObject(category);
    var events = (category && category.events ? category.events : []).concat(hiddenEvents || []);
    copy.events = events.map(cloneEventWithResolvedSchedules);
    return copy;
  }

  function buildTimelineData(baseData, hiddenEventsByCategoryIndex, expandedIndexes) {
    baseData = baseData || {};
    hiddenEventsByCategoryIndex = hiddenEventsByCategoryIndex || {};
    expandedIndexes = expandedIndexes || {};

    return {
      options: clonePlainObject(baseData.options),
      legends: (baseData.legends || []).map(clonePlainObject),
      categories: (baseData.categories || []).map(function(category, categoryIndex) {
        var key = String(categoryIndex);
        var hiddenEvents = expandedIndexes[key] ? hiddenEventsByCategoryIndex[key] : [];
        return cloneCategoryWithEvents(category, hiddenEvents);
      })
    };
  }

  window.TxMilestoneScheduleSummary = {
    resolveScheduleOverlaps: resolveScheduleOverlaps,
    decorateFullDayVacationCells: decorateFullDayVacationCells,
    buildTimelineData: buildTimelineData
  };
})(window, document);
