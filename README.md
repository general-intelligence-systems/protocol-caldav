# protocol-caldav

Pure protocol implementation for CalDAV (RFC 4791) and CardDAV (RFC 6352). No I/O, no server, no framework dependencies.

Handles iCalendar/vCard parsing, XML rendering, ETags, CTags, path semantics, REPORT filters, recurrence expansion, and free/busy calculation.

Pair with [async-caldav](../async-caldav) for a working server.

## Install

```ruby
gem "protocol-caldav", "~> 0.1"
```

## Usage

```ruby
require "protocol/caldav"

# Parse iCalendar
component = Protocol::Caldav::Ical::Parser.parse(ical_string)
vevent = component.find_components("VEVENT").first
vevent.find_property("SUMMARY").value  # => "Team Meeting"

# Parse vCard
card = Protocol::Caldav::Vcard::Parser.parse(vcard_string)
card.find_property("FN").value  # => "Alice"

# ETags
Protocol::Caldav::ETag.compute(body)  # => '"a1b2c3..."'

# RRULE expansion
Protocol::Caldav::Ical::Rrule.expand(
  dtstart: Time.utc(2026, 1, 1, 9, 0),
  rrule_value: "FREQ=WEEKLY;BYDAY=MO,WE,FR;COUNT=10",
  range_start: Time.utc(2026, 1, 1),
  range_end: Time.utc(2026, 3, 1)
)

# REPORT filter parsing & matching
filter = Protocol::Caldav::Filter::Parser.parse_calendar(filter_xml)
Protocol::Caldav::Filter::Match.calendar?(filter, component)  # => true/false

# Collection XML rendering
collection = Protocol::Caldav::Collection.new(
  path: path, type: :calendar, displayname: "Work"
)
collection.to_propfind_xml  # => DAV:multistatus XML fragment
```

## What's inside

| Module | Purpose |
|---|---|
| `Ical::Parser` | Parse iCalendar text into component trees |
| `Ical::Rrule` | Expand RRULE into concrete occurrence times |
| `Ical::Expand` | Expand recurring VCALENDARs for a date range |
| `Ical::FreeBusy` | Calculate VFREEBUSY from events |
| `Vcard::Parser` | Parse vCard text |
| `Filter::Parser` | Parse CalDAV/CardDAV REPORT filter XML |
| `Filter::Match` | Match items against filters (comp, prop, text, time-range, param) |
| `Collection` | Collection metadata + PROPFIND XML rendering |
| `Item` | Item metadata + PROPFIND/REPORT XML rendering |
| `ETag` / `CTag` | Content and collection change tracking |
| `Path` | CalDAV path normalization and semantics |
| `Storage` | Abstract storage interface (subclass for your backend) |

## Tests

```
bundle install
bundle exec scampi
```

## License

Apache-2.0
