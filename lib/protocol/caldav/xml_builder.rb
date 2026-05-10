# frozen_string_literal: true

require "builder"

module Protocol
  module Caldav
    module XmlBuilder
      NAMESPACES = {
        "xmlns:d"  => "DAV:",
        "xmlns:c"  => "urn:ietf:params:xml:ns:caldav",
        "xmlns:cr" => "urn:ietf:params:xml:ns:carddav",
        "xmlns:cs" => "http://calendarserver.org/ns/",
        "xmlns:x"  => "http://apple.com/ns/ical/"
      }.freeze

      module_function

      def multistatus
        xml = Builder::XmlMarkup.new
        xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
        xml.tag!("d:multistatus", NAMESPACES) do
          yield xml
        end
        xml.target!
      end

      def response(xml, href:)
        xml.tag!("d:response") do
          xml.tag!("d:href", href)
          yield xml if block_given?
        end
      end

      def propstat_ok(xml)
        xml.tag!("d:propstat") do
          xml.tag!("d:prop") do
            yield xml
          end
          xml.tag!("d:status", "HTTP/1.1 200 OK")
        end
      end
    end
  end
end
