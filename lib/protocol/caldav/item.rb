# frozen_string_literal: true

require "builder"
require "protocol/caldav"

module Protocol
  module Caldav
    class Item
      attr_reader :path, :body, :content_type, :etag

      def initialize(path:, body:, content_type:, etag:, new_record: false)
        @path = path
        @body = body
        @content_type = content_type
        @etag = etag
        @new_record = new_record
      end

      def new?
        @new_record
      end

      def build_propfind(xml)
        XmlBuilder.response(xml, href: @path.to_s) do
          XmlBuilder.propstat_ok(xml) do
            xml.tag!("d:getetag", @etag)
            xml.tag!("d:getcontenttype", @content_type)
          end
        end
      end

      def build_propname(xml)
        XmlBuilder.response(xml, href: @path.to_s) do
          XmlBuilder.propstat_ok(xml) do
            xml.tag!("d:getetag")
            xml.tag!("d:getcontenttype")
          end
        end
      end

      def build_report(xml, data_tag:)
        XmlBuilder.response(xml, href: @path.to_s) do
          XmlBuilder.propstat_ok(xml) do
            xml.tag!("d:getetag", @etag)
            xml.tag!(data_tag, @body)
          end
        end
      end

      def build_xml(xml)
        build_propfind(xml)
      end

      def to_propfind_xml
        x = Builder::XmlMarkup.new
        build_propfind(x)
        x.target!
      end

      def to_propname_xml
        x = Builder::XmlMarkup.new
        build_propname(x)
        x.target!
      end

      def to_report_xml(data_tag:)
        x = Builder::XmlMarkup.new
        build_report(x, data_tag: data_tag)
        x.target!
      end
    end
  end
end

__END__

def normalize(xml)
  xml.gsub(/>\s+</, '><').strip
end

describe "Protocol::Caldav::Item" do
  def make_item(**opts)
    defaults = {
      path: Protocol::Caldav::Path.new("/calendars/admin/work/event.ics"),
      body: "BEGIN:VCALENDAR\r\nEND:VCALENDAR",
      content_type: "text/calendar",
      etag: '"abc123"'
    }
    Protocol::Caldav::Item.new(**defaults.merge(opts))
  end

  it "exposes path, body, content_type, etag" do
    item = make_item
    item.path.to_s.should.equal "/calendars/admin/work/event.ics"
    item.body.should.include "VCALENDAR"
    item.content_type.should.equal "text/calendar"
    item.etag.should.equal '"abc123"'
  end

  it "new? returns new_record state" do
    make_item(new_record: true).new?.should.equal true
    make_item(new_record: false).new?.should.equal false
  end

  it "to_propfind_xml includes etag and content-type" do
    xml = make_item.to_propfind_xml
    xml.should.include "getetag"
    xml.should.include "getcontenttype"
    xml.should.include "text/calendar"
  end

  it "to_report_xml includes data tag with body" do
    xml = make_item.to_report_xml(data_tag: "c:calendar-data")
    xml.should.include "c:calendar-data"
    xml.should.include "VCALENDAR"
  end

  it "to_propname_xml includes empty prop elements" do
    xml = make_item.to_propname_xml
    xml.should.include "<d:getetag/>"
    xml.should.include "<d:getcontenttype/>"
  end
end
