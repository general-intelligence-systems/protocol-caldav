# frozen_string_literal: true

require "bundler/setup"
require "scampi"
require "builder"

module Protocol
  module Caldav
    class Multistatus
      def initialize(responses = [])
        @responses = responses
      end

      def to_xml(&block)
        XmlBuilder.multistatus do |xml|
          if block
            block.call(xml)
          else
            @responses.each { |r| r.build_xml(xml) }
          end
        end
      end
    end
  end
end


test do
  def normalize(xml)
    xml.gsub(/>\s+</, '><').strip
  end

  # Minimal wrapper so tests can pass objects with build_xml
  class FakeResponse
    def initialize(href)
      @href = href
    end

    def build_xml(xml)
      xml.tag!("d:response") { xml.tag!("d:href", @href) }
    end
  end

  describe "Protocol::Caldav::Multistatus" do
    it "declares all four required namespaces" do
      xml = Protocol::Caldav::Multistatus.new([]).to_xml
      xml.should.include 'xmlns:d="DAV:"'
      xml.should.include 'xmlns:c="urn:ietf:params:xml:ns:caldav"'
      xml.should.include 'xmlns:cr="urn:ietf:params:xml:ns:carddav"'
      xml.should.include 'xmlns:cs="http://calendarserver.org/ns/"'
    end

    it "emits responses in the order given" do
      responses = [FakeResponse.new("/a"), FakeResponse.new("/b")]
      xml = Protocol::Caldav::Multistatus.new(responses).to_xml
      xml.index("/a").should.be < xml.index("/b")
    end

    it "produces valid XML for empty response array" do
      xml = Protocol::Caldav::Multistatus.new([]).to_xml
      xml.should.include '<?xml version="1.0"'
      xml.should.include '<d:multistatus'
      xml.should.include '</d:multistatus>'
    end

    it "does not double-escape when using builder" do
      xml = Protocol::Caldav::Multistatus.new.to_xml do |x|
        x.tag!("d:response") { x.tag!("d:href", "/Work & Personal") }
      end
      xml.should.include '&amp;'
      xml.should.not.include '&amp;amp;'
    end

    it "supports block form for custom content" do
      xml = Protocol::Caldav::Multistatus.new.to_xml do |x|
        x.tag!("d:response") { x.tag!("d:href", "/test") }
        x.tag!("d:sync-token", "token-123")
      end
      xml.should.include '/test'
      xml.should.include 'token-123'
    end
  end
end
