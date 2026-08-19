# frozen_string_literal: true

require "builder"

require "protocol/caldav"

module Protocol
  module Caldav
    class Collection
      attr_reader :path, :type, :displayname, :description, :color, :props

      def initialize(path:, type: :collection, displayname: nil, description: nil, color: nil, props: {})
        @path = path
        @type = type
        @displayname = displayname
        @description = description
        @color = color
        @props = props || {}
      end

      def update_attrs(updates)
        if updates.key?(:displayname)
          @displayname = updates[:displayname]
        end
        if updates.key?(:description)
          @description = updates[:description]
        end
        if updates.key?(:color)
          @color = updates[:color]
        end
        if updates.key?(:props)
          @props = (@props || {}).merge(updates[:props])
        end
        self
      end

      def build_propfind(xml)
        XmlBuilder.response(xml, href: @path.to_s) do
          XmlBuilder.propstat_ok(xml) do
            xml.tag!("d:resourcetype") do
              xml.tag!("d:collection")
              if @type == :calendar
                xml.tag!("c:calendar")
              end
              if @type == :addressbook
                xml.tag!("cr:addressbook")
              end
            end

            if @displayname
              xml.tag!("d:displayname", @displayname)
            end
            if @description
              xml.tag!("c:calendar-description", @description)
            end
            if @color
              xml.tag!("x:calendar-color", @color)
            end

            item_etags = @path.storage_class.list_items(@path.to_s).map { |_, data| data[:etag] }
            ctag = CTag.compute(
              path:        @path.to_s,
              displayname: @displayname,
              description: @description,
              color:       @color,
              item_etags:  item_etags,
            )
            xml.tag!("cs:getctag", ctag)
            xml.tag!("d:sync-token", "http://caldav.local/sync/#{ctag}")

            if @type == :calendar
              xml.tag!("c:supported-calendar-component-set") do
                xml.tag!("c:comp", name: "VEVENT")
                xml.tag!("c:comp", name: "VTODO")
                xml.tag!("c:comp", name: "VJOURNAL")
              end
            end

            xml.tag!("d:current-user-privilege-set") do
              xml.tag!("d:privilege") { xml.tag!("d:read") }
              xml.tag!("d:privilege") { xml.tag!("d:write") }
              xml.tag!("d:privilege") { xml.tag!("d:all") }
            end

            @props.each do |key, value|
              xml.tag!(key, value)
            end
          end
        end
      end

      def build_propname(xml)
        XmlBuilder.response(xml, href: @path.to_s) do
          XmlBuilder.propstat_ok(xml) do
            xml.tag!("d:resourcetype")
            if @displayname
              xml.tag!("d:displayname")
            end
            if @description
              xml.tag!("c:calendar-description")
            end
            if @color
              xml.tag!("x:calendar-color")
            end
            xml.tag!("cs:getctag")
            xml.tag!("d:sync-token")
            if @type == :calendar
              xml.tag!("c:supported-calendar-component-set")
            end
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
    end
  end
end

__END__

def normalize(xml)
  xml.gsub(/>\s+</, '><').strip
end

# Minimal mock storage for Collection tests
class MockStorageForCollection < Protocol::Caldav::Storage
  def list_items(_path)
    []
  end
end

describe "Protocol::Caldav::Collection" do
  def make_collection(type: :calendar, displayname: "Work", **opts)
    storage = MockStorageForCollection.new
    path = Protocol::Caldav::Path.new("/calendars/admin/work/", storage_class: storage)
    Protocol::Caldav::Collection.new(path: path, type: type, displayname: displayname, **opts)
  end

  it "renders calendar resourcetype" do
    xml = make_collection(type: :calendar).to_propfind_xml
    xml.should.include "<c:calendar/>"
  end

  it "renders addressbook resourcetype" do
    xml = make_collection(type: :addressbook).to_propfind_xml
    xml.should.include "<cr:addressbook/>"
  end

  it "includes displayname when set" do
    xml = make_collection(displayname: "Work").to_propfind_xml
    xml.should.include "<d:displayname>Work</d:displayname>"
  end

  it "omits displayname when nil" do
    xml = make_collection(displayname: nil).to_propfind_xml
    xml.should.not.include "displayname"
  end

  it "includes ctag" do
    xml = make_collection.to_propfind_xml
    xml.should.include "<cs:getctag>"
  end

  it "includes supported-calendar-component-set for calendars" do
    xml = make_collection(type: :calendar).to_propfind_xml
    xml.should.include "supported-calendar-component-set"
  end

  it "omits supported-calendar-component-set for addressbooks" do
    xml = make_collection(type: :addressbook).to_propfind_xml
    xml.should.not.include "supported-calendar-component-set"
  end

  it "escapes special characters in displayname" do
    xml = make_collection(displayname: "Work & <Personal>").to_propfind_xml
    xml.should.include "Work &amp; &lt;Personal&gt;"
  end

  it "update_attrs modifies named fields" do
    col = make_collection(displayname: "Old")
    col.update_attrs(displayname: "New")
    col.displayname.should.equal "New"
  end

  it "update_attrs leaves unmentioned fields alone" do
    col = make_collection(displayname: "Work", description: "Desc")
    col.update_attrs(displayname: "New")
    col.description.should.equal "Desc"
  end
end
