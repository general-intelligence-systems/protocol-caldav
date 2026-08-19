# frozen_string_literal: true

require "protocol/caldav"

module Protocol
  module Caldav
    module Ical
      module Expand
        module_function

        # Expand a recurring VCALENDAR into individual instances.
        # Returns a serialized VCALENDAR string with RRULE removed
        # and each occurrence as a separate VEVENT with RECURRENCE-ID.
        def expand(component, range_start:, range_end:, max_occurrences: 10000)
          if component.name.casecmp?('VCALENDAR')
            base = component.find_components('VEVENT').find { |v| v.find_property('RRULE') }
            if base
              uid = base.find_property('UID')&.value
              overrides = {}
              component.find_components('VEVENT').each do |v|
                rid = v.find_property('RECURRENCE-ID')
                if rid && v.find_property('UID')&.value == uid
                  rid_time = Filter::Match.send(:parse_datetime_string, rid.value.strip)
                  if rid_time
                    overrides[rid_time] = v
                  end
                end
              end
              dtstart_prop = base.find_property('DTSTART')
              dtstart = Filter::Match.send(:parse_datetime_string, dtstart_prop.value.strip)
              if dtstart
                dtend = Filter::Match.send(:parse_ical_datetime, base, 'DTEND')
                if dtend
                  duration = (dtend - dtstart).to_i
                else
                  duration = 3600
                end
                rrule = base.find_property('RRULE').value.strip
                exdates = base.find_all_properties('EXDATE').filter_map do |ex|
                  Filter::Match.send(:parse_datetime_string, ex.value.strip)
                end
                occurrences = Rrule.expand(
                  dtstart:     dtstart,
                  rrule_value: rrule,
                  range_start: range_start,
                  range_end:   range_end,
                  exdates:     exdates,
                  max_count:   max_occurrences,
                )
                instances = occurrences.map do |occ_start|
                  override = overrides[occ_start]
                  if override
                    serialize_vevent_instance(override, occ_start)
                  else
                    serialize_expanded_instance(base, occ_start, duration)
                  end
                end
                overrides.each do |rid_time, override_vevent|
                  if occurrences.any? { |o| Rrule.send(:times_equal?, o, rid_time) }
                    next
                  end
                  odt = Filter::Match.send(:parse_ical_datetime, override_vevent, 'DTSTART')
                  unless odt && odt >= range_start && odt < range_end
                    next
                  end
                  instances << serialize_vevent_instance(override_vevent, rid_time)
                end
                "BEGIN:VCALENDAR\r\n#{instances.join}END:VCALENDAR\r\n"
              else
                serialize_component(component)
              end
            else
              serialize_component(component)
            end
          else
            serialize_component(component)
          end
        end

        def serialize_expanded_instance(base, occ_start, duration)
          occ_end = occ_start + duration
          lines = []
          lines << "BEGIN:VEVENT"
          lines << "RECURRENCE-ID:#{format_utc(occ_start)}"
          lines << "DTSTART:#{format_utc(occ_start)}"
          lines << "DTEND:#{format_utc(occ_end)}"

          base.properties.each do |prop|
            if %w[DTSTART DTEND RRULE EXDATE RDATE EXRULE RECURRENCE-ID DURATION].include?(prop.name.upcase)
              next
            end
            lines << "#{prop.name}:#{prop.value}"
          end

          lines << "END:VEVENT"
          lines.map { |l| "#{l}\r\n" }.join
        end

        def serialize_vevent_instance(vevent, rid_time)
          lines = []
          lines << "BEGIN:VEVENT"
          has_rid = false
          vevent.properties.each do |prop|
            if %w[RRULE EXDATE RDATE EXRULE].include?(prop.name.upcase)
              next
            end
            if prop.name.casecmp?('RECURRENCE-ID')
              has_rid = true
            end
            lines << "#{prop.name}:#{prop.value}"
          end
          unless has_rid
            lines.insert(1, "RECURRENCE-ID:#{format_utc(rid_time)}")
          end
          lines << "END:VEVENT"
          lines.map { |l| "#{l}\r\n" }.join
        end

        def serialize_component(component)
          lines = ["BEGIN:#{component.name}\r\n"]
          component.properties.each { |p| lines << "#{p.name}:#{p.value}\r\n" }
          component.components.each { |c| lines << serialize_component(c) }
          lines << "END:#{component.name}\r\n"
          lines.join
        end

        def format_utc(time)
          time.utc.strftime('%Y%m%dT%H%M%SZ')
        end

        private_class_method :serialize_expanded_instance,
          :serialize_vevent_instance,
          :serialize_component,
          :format_utc
      end
    end
  end
end

__END__

describe "Protocol::Caldav::Ical::Expand" do
  def parse(text)
    Protocol::Caldav::Ical::Parser.parse(text)
  end

  it "returns serialized component when not VCALENDAR" do
    vevent = parse("BEGIN:VEVENT\r\nSUMMARY:Hello\r\nEND:VEVENT")
    result = Protocol::Caldav::Ical::Expand.expand(vevent, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 12, 31))
    result.should.include "BEGIN:VEVENT"
    result.should.include "SUMMARY:Hello"
    result.should.include "END:VEVENT"
  end

  it "returns serialized component when no RRULE found" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nSUMMARY:Once\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 12, 31))
    result.should.include "BEGIN:VCALENDAR"
    result.should.include "SUMMARY:Once"
    result.should.include "END:VCALENDAR"
  end

  it "expands daily RRULE into individual instances" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nUID:expand-test\r\nSUMMARY:Daily\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 1, 10))
    result.scan("BEGIN:VEVENT").length.should.equal 3
    result.should.include "RECURRENCE-ID"
    result.should.include "SUMMARY:Daily"
  end

  it "removes RRULE from expanded output" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nUID:no-rrule\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 1, 10))
    result.should.not.include "RRULE"
  end

  it "applies override VEVENT replacing base occurrence" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nUID:override-test\r\nSUMMARY:Base\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nDTSTART:20260102T140000Z\r\nDTEND:20260102T150000Z\r\nRECURRENCE-ID:20260102T090000Z\r\nUID:override-test\r\nSUMMARY:Override\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 1, 10))
    result.scan("BEGIN:VEVENT").length.should.equal 3
    result.should.include "SUMMARY:Override"
    result.should.include "SUMMARY:Base"
  end

  it "non-recurring event passes through unchanged" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nUID:single\r\nSUMMARY:Once\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 12, 31))
    result.scan("BEGIN:VEVENT").length.should.equal 1
    result.should.include "SUMMARY:Once"
    result.should.not.include "RECURRENCE-ID"
  end

  it "respects EXDATE exclusions" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEXDATE:20260102T090000Z\r\nUID:exdate-test\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 1, 10))
    result.scan("BEGIN:VEVENT").length.should.equal 2
  end

  it "only returns instances within range" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=10\r\nUID:range-test\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 3), range_end: Time.utc(2026, 1, 6))
    result.scan("BEGIN:VEVENT").length.should.equal 3
    result.should.include "20260103T090000Z"
    result.should.include "20260105T090000Z"
  end

  it "preserves non-recurrence properties in expanded instances" do
    ical = "BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nUID:props-test\r\nSUMMARY:Keep Me\r\nLOCATION:Room 1\r\nEND:VEVENT\r\nEND:VCALENDAR"
    component = parse(ical)
    result = Protocol::Caldav::Ical::Expand.expand(component, range_start: Time.utc(2026, 1, 1), range_end: Time.utc(2026, 1, 10))
    # Both instances should have SUMMARY and LOCATION
    result.scan("SUMMARY:Keep Me").length.should.equal 2
    result.scan("LOCATION:Room 1").length.should.equal 2
  end
end
