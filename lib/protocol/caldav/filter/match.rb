# frozen_string_literal: true

require "protocol/caldav"

module Protocol
  module Caldav
    module Filter
      module Match
        module_function

        # --- Calendar (RFC 4791 §9.7) ---

        def calendar?(filter, component)
          if component
            comp_filter_matches?(filter, component)
          else
            false
          end
        end

        # --- Addressbook (RFC 6352 §10.5) ---

        def addressbook?(filter, card)
          if card
            if filter.prop_filters.empty?
              true
            else
              if filter.test == 'allof'
                filter.prop_filters.all? { |pf| card_prop_filter_matches?(pf, card) }
              else
                filter.prop_filters.any? { |pf| card_prop_filter_matches?(pf, card) }
              end
            end
          else
            false
          end
        end

        # --- Private: Calendar matching ---

        def comp_filter_matches?(filter, component)
          if component.name.casecmp?(filter.name)
            if filter.is_not_defined
              false
            else
              if filter.time_range && !time_range_matches?(filter.time_range, component)
                false
              else
                if filter.prop_filters.all? { |pf| prop_filter_matches?(pf, component) }
                  filter.comp_filters.all? do |cf|
                    children = component.find_components(cf.name)
                    if cf.is_not_defined
                      children.empty?
                    else
                      children.any? { |child| comp_filter_matches?(cf, child) }
                    end
                  end
                else
                  false
                end
              end
            end
          else
            false
          end
        end

        def time_range_matches?(tr, component)
          # Handle recurring events via RRULE expansion
          rrule_prop = component.find_property('RRULE')
          if rrule_prop
            rrule_time_range_matches?(tr, component, rrule_prop)
          else
            if tr.start_time
              filter_start = parse_datetime_string(tr.start_time)
            else
              filter_start = Time.at(0).utc
            end
            if tr.end_time
              filter_end = parse_datetime_string(tr.end_time)
            else
              filter_end = Time.utc(9999)
            end
            comp_start = parse_ical_datetime(component, 'DTSTART')

            if component.name.casecmp?('VTODO')
              due = parse_ical_datetime(component, 'DUE')
              completed = parse_ical_datetime(component, 'COMPLETED')
              created = parse_ical_datetime(component, 'CREATED')

              if comp_start && due
                comp_start < filter_end && due > filter_start
              elsif comp_start
                comp_start < filter_end && (comp_start + 1) > filter_start
              elsif due
                (due - 1) < filter_end && due > filter_start
              elsif completed
                completed >= filter_start && completed < filter_end
              elsif created
                created >= filter_start && created < filter_end
              else
                true
              end
            elsif component.name.casecmp?('VJOURNAL')
              if comp_start
                comp_start >= filter_start && comp_start < filter_end
              else
                false
              end
            else
              comp_end = parse_ical_datetime(component, 'DTEND') ||
                parse_duration_end(component, comp_start) ||
                (comp_start ? comp_start + 1 : nil)

              if comp_start
                comp_start < filter_end && (comp_end || comp_start + 1) > filter_start
              else
                false
              end
            end
          end
        end

        def parse_ical_datetime(component, prop_name)
          prop = component.find_property(prop_name)
          if prop
            parse_datetime_string(prop.value.strip)
          else
            nil
          end
        end

        def parse_duration_end(component, start_time)
          if start_time
            dur = component.find_property('DURATION')
            if dur
              val = dur.value.strip
              seconds = 0
              if m = val.match(/P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?/)
                seconds += (m[1]&.to_i || 0) * 86400
                seconds += (m[2]&.to_i || 0) * 3600
                seconds += (m[3]&.to_i || 0) * 60
                seconds += (m[4]&.to_i || 0)
              end
              seconds > 0 ? start_time + seconds : nil
            else
              nil
            end
          else
            nil
          end
        end

        def parse_datetime_string(str)
          if str && !str.empty?
            str = str.strip
            if str.length == 8 # DATE format: YYYYMMDD
              Time.utc(str[0..3].to_i, str[4..5].to_i, str[6..7].to_i)
            elsif str.end_with?('Z') # UTC datetime
              s = str.chomp('Z')
              Time.utc(
                s[0..3].to_i,
                s[4..5].to_i,
                s[6..7].to_i,
                s[9..10].to_i,
                s[11..12].to_i,
                s[13..14].to_i,
              )
            else # Floating datetime -- treat as UTC per RFC 4791 §9.9
              Time.utc(
                str[0..3].to_i,
                str[4..5].to_i,
                str[6..7].to_i,
                str[9..10].to_i,
                str[11..12].to_i,
                str[13..14].to_i,
              )
            end
          else
            nil
          end
        rescue ArgumentError
          nil
        end

        def prop_filter_matches?(filter, component)
          properties = component.find_all_properties(filter.name)

          if filter.is_not_defined
            properties.empty?
          else
            if properties.empty?
              false
            else
              properties.any? do |prop|
                if filter.text_match && !text_match_matches?(filter.text_match, prop.value)
                  next false
                end
                filter.param_filters.all? { |pf| param_filter_matches?(pf, prop) }
              end
            end
          end
        end

        def param_filter_matches?(filter, property)
          param_value = property.param(filter.name)

          if filter.is_not_defined
            param_value.nil?
          else
            if param_value.nil?
              false
            else
              if filter.text_match
                text_match_matches?(filter.text_match, param_value)
              else
                true
              end
            end
          end
        end

        def text_match_matches?(matcher, value)
          case matcher.match_type
          when 'equals'
            result = collate_equal?(matcher.collation, value, matcher.value)
          when 'starts-with'
            result = collate_starts?(matcher.collation, value, matcher.value)
          when 'ends-with'
            result = collate_ends?(matcher.collation, value, matcher.value)
          else
            result = collate_contains?(matcher.collation, value, matcher.value)
          end
          matcher.negate_condition ? !result : result
        end

        def collate_contains?(collation, haystack, needle)
          if collation == 'i;octet'
            haystack.include?(needle)
          else
            haystack.downcase.include?(needle.downcase)
          end
        end

        def collate_equal?(collation, a, b)
          if collation == 'i;octet'
            a == b
          else
            a.casecmp?(b)
          end
        end

        def collate_starts?(collation, haystack, needle)
          if collation == 'i;octet'
            haystack.start_with?(needle)
          else
            haystack.downcase.start_with?(needle.downcase)
          end
        end

        def collate_ends?(collation, haystack, needle)
          if collation == 'i;octet'
            haystack.end_with?(needle)
          else
            haystack.downcase.end_with?(needle.downcase)
          end
        end

        # --- Private: Addressbook matching ---

        def card_prop_filter_matches?(filter, card)
          properties = card.find_all_properties(filter.name)

          if filter.is_not_defined
            properties.empty?
          else
            if properties.empty?
              false
            else
              properties.any? do |prop|
                if filter.text_match && !text_match_matches?(filter.text_match, prop.value)
                  next false
                end
                filter.param_filters.all? { |pf| param_filter_matches?(pf, prop) }
              end
            end
          end
        end

        def rrule_time_range_matches?(tr, component, rrule_prop)
          dtstart = parse_ical_datetime(component, 'DTSTART')
          if dtstart
            if tr.start_time
              filter_start = parse_datetime_string(tr.start_time)
            else
              filter_start = Time.at(0).utc
            end
            if tr.end_time
              filter_end = parse_datetime_string(tr.end_time)
            else
              filter_end = Time.utc(9999)
            end
            exdates = component.find_all_properties('EXDATE').filter_map do |ex|
              parse_datetime_string(ex.value.strip)
            end
            dtend = parse_ical_datetime(component, 'DTEND')
            duration = nil

            if dtend
              duration = dtend - dtstart
            else
              dur_prop = component.find_property('DURATION')
              duration = 1

              if dur_prop
                duration = parse_duration_seconds(dur_prop.value.strip)
              end
            end
            adjusted_start = filter_start - [duration, 0].max
            occurrences = Ical::Rrule.expand(
              dtstart:     dtstart,
              rrule_value: rrule_prop.value.strip,
              range_start: adjusted_start,
              range_end:   filter_end,
              exdates:     exdates,
              max_count:   10000,
            )
            occurrences.any? do |occ_start|
              occ_end = occ_start + duration
              occ_start < filter_end && occ_end > filter_start
            end
          else
            false
          end
        end

        def parse_duration_seconds(val)
          seconds = 0
          if m = val.match(/P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?/)
            seconds += (m[1]&.to_i || 0) * 604800
            seconds += (m[2]&.to_i || 0) * 86400
            seconds += (m[3]&.to_i || 0) * 3600
            seconds += (m[4]&.to_i || 0) * 60
            seconds += (m[5]&.to_i || 0)
          end
          seconds > 0 ? seconds : 1
        end

        private_class_method :comp_filter_matches?,
          :prop_filter_matches?,
          :param_filter_matches?,
          :text_match_matches?,
          :collate_contains?,
          :collate_equal?,
          :collate_starts?,
          :collate_ends?,
          :card_prop_filter_matches?,
          :time_range_matches?,
          :parse_ical_datetime,
          :parse_duration_end,
          :parse_datetime_string,
          :rrule_time_range_matches?,
          :parse_duration_seconds
      end
    end
  end
end

__END__

def parse_ical(text)
  Protocol::Caldav::Ical::Parser.parse(text)
end

def parse_vcard(text)
  Protocol::Caldav::Vcard::Parser.parse(text)
end

def comp_filter(name, **opts)
  Protocol::Caldav::Filter::Calendar::CompFilter.new(name: name, **opts)
end

def prop_filter(name, **opts)
  Protocol::Caldav::Filter::Calendar::PropFilter.new(name: name, **opts)
end

def text_match(value, **opts)
  Protocol::Caldav::Filter::Calendar::TextMatch.new(value: value, **opts)
end

def ab_filter(**opts)
  Protocol::Caldav::Filter::Addressbook::Filter.new(**opts)
end

def ab_prop_filter(name, **opts)
  Protocol::Caldav::Filter::Addressbook::PropFilter.new(name: name, **opts)
end

def ab_text_match(value, **opts)
  Protocol::Caldav::Filter::Addressbook::TextMatch.new(value: value, **opts)
end

describe "Protocol::Caldav::Filter::Match" do
  describe "CompFilter against component" do
    it "matches when component name equals filter name" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nEND:VCALENDAR")
      Protocol::Caldav::Filter::Match.calendar?(comp_filter("VCALENDAR"), vcal).should.equal true
    end

    it "does not match when names differ" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nEND:VCALENDAR")
      Protocol::Caldav::Filter::Match.calendar?(comp_filter("VEVENT"), vcal).should.equal false
    end

    it "with is_not_defined: does not match when component present" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nEND:VCALENDAR")
      Protocol::Caldav::Filter::Match.calendar?(comp_filter("VCALENDAR", is_not_defined: true), vcal).should.equal false
    end

    it "all nested prop-filters must match (AND semantics)" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY"),
          prop_filter("DESCRIPTION")  # absent -> fails
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "empty filter matches any component of that name" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nEND:VCALENDAR")
      Protocol::Caldav::Filter::Match.calendar?(comp_filter("VCALENDAR"), vcal).should.equal true
    end

    it "is_not_defined on nested comp-filter: matches when absent" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VTODO", is_not_defined: true)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "is_not_defined on nested comp-filter: does not match when present" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", is_not_defined: true)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end
  end

  describe "PropFilter" do
    it "matches when property exists (defined-only check)" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Test\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [prop_filter("SUMMARY")])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "does not match when property absent" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [prop_filter("SUMMARY")])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "with is_not_defined: matches when property absent" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [prop_filter("STATUS", is_not_defined: true)])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "with is_not_defined: does not match when property present" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSTATUS:CONFIRMED\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [prop_filter("STATUS", is_not_defined: true)])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "multi-value: matches if any instance satisfies" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE:alice\r\nATTENDEE:bob\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("ATTENDEE", text_match: text_match("bob"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end
  end

  describe "TextMatch" do
    it "contains (default) matches substring" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Team Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Meeting"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "equals matches whole-string equality" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Meeting", match_type: "equals"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "equals rejects partial match" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Team Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Meeting", match_type: "equals"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "starts-with matches prefix" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Team Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Team", match_type: "starts-with"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "ends-with matches suffix" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Team Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Meeting", match_type: "ends-with"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "i;ascii-casemap (default) is case-insensitive" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:MEETING\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("meeting"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "i;octet is case-sensitive" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:MEETING\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("meeting", collation: "i;octet"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "negate-condition inverts the result" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Meeting\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Meeting", negate_condition: true))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "negate-condition on non-match produces true" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Lunch\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Meeting", negate_condition: true))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end
  end

  describe "text-match on SUMMARY only matches SUMMARY property" do
    it "does not match when text appears in DESCRIPTION but not SUMMARY" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nSUMMARY:Lunch\r\nDESCRIPTION:Alice is coming\r\nEND:VEVENT\r\nEND:VCALENDAR")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("SUMMARY", text_match: text_match("Alice"))
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end
  end

  describe "Addressbook filter" do
    it "anyof returns true if any prop-filter matches" do
      card = parse_vcard("BEGIN:VCARD\r\nFN:John\r\nEMAIL:john@x.com\r\nEND:VCARD")
      f = ab_filter(test: "anyof", prop_filters: [
        ab_prop_filter("FN", text_match: ab_text_match("Jane")),
        ab_prop_filter("EMAIL", text_match: ab_text_match("john"))
      ])
      Protocol::Caldav::Filter::Match.addressbook?(f, card).should.equal true
    end

    it "allof returns true only if all prop-filters match" do
      card = parse_vcard("BEGIN:VCARD\r\nFN:John\r\nEMAIL:john@x.com\r\nEND:VCARD")
      f = ab_filter(test: "allof", prop_filters: [
        ab_prop_filter("FN", text_match: ab_text_match("John")),
        ab_prop_filter("EMAIL", text_match: ab_text_match("jane"))
      ])
      Protocol::Caldav::Filter::Match.addressbook?(f, card).should.equal false
    end

    it "allof returns true when all match" do
      card = parse_vcard("BEGIN:VCARD\r\nFN:John\r\nEMAIL:john@x.com\r\nEND:VCARD")
      f = ab_filter(test: "allof", prop_filters: [
        ab_prop_filter("FN", text_match: ab_text_match("John")),
        ab_prop_filter("EMAIL", text_match: ab_text_match("john"))
      ])
      Protocol::Caldav::Filter::Match.addressbook?(f, card).should.equal true
    end

    it "empty filter list returns true" do
      card = parse_vcard("BEGIN:VCARD\r\nFN:John\r\nEND:VCARD")
      f = ab_filter(prop_filters: [])
      Protocol::Caldav::Filter::Match.addressbook?(f, card).should.equal true
    end
  end

  describe "ParamFilter" do
    it "matches when parameter exists (defined-only check)" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@x.com\r\nEND:VEVENT\r\nEND:VCALENDAR")
      pf = Protocol::Caldav::Filter::Calendar::ParamFilter.new(name: "PARTSTAT")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("ATTENDEE", param_filters: [pf])
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "does not match when parameter absent" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE:mailto:alice@x.com\r\nEND:VEVENT\r\nEND:VCALENDAR")
      pf = Protocol::Caldav::Filter::Calendar::ParamFilter.new(name: "PARTSTAT")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("ATTENDEE", param_filters: [pf])
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "with is_not_defined: matches when parameter absent" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE:mailto:alice@x.com\r\nEND:VEVENT\r\nEND:VCALENDAR")
      pf = Protocol::Caldav::Filter::Calendar::ParamFilter.new(name: "PARTSTAT", is_not_defined: true)
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("ATTENDEE", param_filters: [pf])
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "with text-match: matches when parameter value matches" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE;PARTSTAT=ACCEPTED:mailto:alice@x.com\r\nEND:VEVENT\r\nEND:VCALENDAR")
      pf = Protocol::Caldav::Filter::Calendar::ParamFilter.new(
        name: "PARTSTAT",
        text_match: text_match("ACCEPTED", match_type: "equals")
      )
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("ATTENDEE", param_filters: [pf])
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "with text-match: does not match when parameter value differs" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nATTENDEE;PARTSTAT=DECLINED:mailto:alice@x.com\r\nEND:VEVENT\r\nEND:VCALENDAR")
      pf = Protocol::Caldav::Filter::Calendar::ParamFilter.new(
        name: "PARTSTAT",
        text_match: text_match("ACCEPTED", match_type: "equals")
      )
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", prop_filters: [
          prop_filter("ATTENDEE", param_filters: [pf])
        ])
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end
  end

  describe "time-range on VEVENT" do
    it "matches overlapping event" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260115T090000Z\r\nDTEND:20260115T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "does not match event fully before range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20251215T090000Z\r\nDTEND:20251215T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "does not match event fully after range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260215T090000Z\r\nDTEND:20260215T100000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "half-open: event ending exactly at range start does not match" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20251231T230000Z\r\nDTEND:20260101T000000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "half-open: event starting exactly at range start matches" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T000000Z\r\nDTEND:20260101T010000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end
  end

  describe "time-range on VJOURNAL" do
    it "matches VJOURNAL with DTSTART in range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VJOURNAL\r\nDTSTART:20260115T090000Z\r\nSUMMARY:Note\r\nEND:VJOURNAL\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VJOURNAL", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "does not match VJOURNAL with DTSTART outside range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VJOURNAL\r\nDTSTART:20260315T090000Z\r\nSUMMARY:Note\r\nEND:VJOURNAL\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VJOURNAL", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "does not match VJOURNAL without DTSTART" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VJOURNAL\r\nSUMMARY:Undated\r\nEND:VJOURNAL\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VJOURNAL", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end
  end

  describe "time-range on VEVENT with RRULE" do
    it "matches recurring event with occurrence in range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=30\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260115T000000Z", end_time: "20260116T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "does not match recurring event when all occurrences are outside range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEND:VEVENT\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260201T000000Z", end_time: "20260301T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "matches weekly recurring event" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260105T090000Z\r\nDTEND:20260105T100000Z\r\nRRULE:FREQ=WEEKLY;COUNT=10\r\nEND:VEVENT\r\nEND:VCALENDAR")
      # The 3rd occurrence (Jan 19) should be in this range
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260119T000000Z", end_time: "20260120T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "respects EXDATE when filtering recurring events" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\nDTSTART:20260101T090000Z\r\nDTEND:20260101T100000Z\r\nRRULE:FREQ=DAILY;COUNT=5\r\nEXDATE:20260102T090000Z\r\nEND:VEVENT\r\nEND:VCALENDAR")
      # Range covers only Jan 2 — but that's excluded
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260102T000000Z", end_time: "20260102T120000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VEVENT", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end
  end

  describe "time-range on VTODO" do
    it "matches VTODO with DTSTART and DUE in range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nDTSTART:20260115T090000Z\r\nDUE:20260116T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VTODO", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "does not match VTODO outside range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nDTSTART:20260301T090000Z\r\nDUE:20260302T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VTODO", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal false
    end

    it "matches VTODO with only COMPLETED in range" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nCOMPLETED:20260115T090000Z\r\nEND:VTODO\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VTODO", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end

    it "matches VTODO with no dates (always matches per RFC 4791)" do
      vcal = parse_ical("BEGIN:VCALENDAR\r\nBEGIN:VTODO\r\nSUMMARY:Undated task\r\nEND:VTODO\r\nEND:VCALENDAR")
      tr = Protocol::Caldav::Filter::Calendar::TimeRange.new(start_time: "20260101T000000Z", end_time: "20260201T000000Z")
      f = comp_filter("VCALENDAR", comp_filters: [
        comp_filter("VTODO", time_range: tr)
      ])
      Protocol::Caldav::Filter::Match.calendar?(f, vcal).should.equal true
    end
  end
end
