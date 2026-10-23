# frozen_string_literal: true

require "rails_helper"

RSpec.describe Opml::Parser do
  def with_loopback_listener
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      conns = 0
      trap("TERM") do
        writer.write(conns.to_s)
        writer.close
        exit!(0)
      end

      loop do
        sock = server.accept
        conns += 1
        sock.close rescue nil
      end
    end

    writer.close

    begin
      yield port
    ensure
      server.close rescue nil
      Process.kill("TERM", pid) rescue nil
      Process.wait(pid) rescue nil
    end

    reader.read.to_i
  end

  let(:canary) { "CANARY_SECRET_DATA_TOKEN_12345" }
  let(:canary_file) do
    file = Tempfile.new("cerrynt_xxe_canary")
    file.write(canary)
    file.flush
    file
  end

  after do
    canary_file.close
    canary_file.unlink
  end

  describe ".parse" do
    it "parses valid OPML 2.0 with nested folders in document order" do
      opml = <<~XML
        <opml version="2.0">
          <head>
            <title>My Subscriptions</title>
          </head>
          <body>
            <outline text="Tech">
              <outline text="Ruby News" title="Ruby News Blog" xmlUrl="https://example.com/ruby.xml" htmlUrl="https://example.com/ruby"/>
              <outline text="Sub-Tech">
                <outline text="Rails World" xmlUrl="https://example.com/rails.xml"/>
              </outline>
            </outline>
            <outline text="Top Level Feed" xmlUrl="https://example.com/top.xml"/>
          </body>
        </opml>
      XML

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.error).to be_nil
      expect(result.reason).to be_nil
      expect(result.outlines.size).to eq(3)

      expect(result.outlines[0]).to eq({
        url: "https://example.com/ruby.xml",
        title: "Ruby News Blog",
        html_url: "https://example.com/ruby"
      })
      expect(result.outlines[1]).to eq({
        url: "https://example.com/rails.xml",
        title: "Rails World",
        html_url: nil
      })
      expect(result.outlines[2]).to eq({
        url: "https://example.com/top.xml",
        title: "Top Level Feed",
        html_url: nil
      })
    end

    it "matches attribute names case-insensitively (xmlUrl, xmlurl, XMLURL)" do
      opml = <<~XML
        <opml version="2.0">
          <body>
            <outline TITLE="Feed 1" XMLURL="https://example.com/1.xml" HTMLURL="https://example.com/1"/>
            <outline title="Feed 2" xmlurl="https://example.com/2.xml" htmlurl="https://example.com/2"/>
            <outline title="Feed 3" xmlUrl="https://example.com/3.xml" htmlUrl="https://example.com/3"/>
          </body>
        </opml>
      XML

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines.size).to eq(3)
      expect(result.outlines[0][:url]).to eq("https://example.com/1.xml")
      expect(result.outlines[0][:title]).to eq("Feed 1")
      expect(result.outlines[0][:html_url]).to eq("https://example.com/1")
      expect(result.outlines[1][:url]).to eq("https://example.com/2.xml")
      expect(result.outlines[2][:url]).to eq("https://example.com/3.xml")
    end

    it "falls back to text attribute when title attribute is missing or blank" do
      opml = <<~XML
        <opml version="2.0">
          <body>
            <outline title="" text="Fallback Title 1" xmlUrl="https://example.com/1.xml"/>
            <outline text="Fallback Title 2" xmlUrl="https://example.com/2.xml"/>
            <outline title="Explicit Title" text="Ignored Text" xmlUrl="https://example.com/3.xml"/>
          </body>
        </opml>
      XML

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines[0][:title]).to eq("Fallback Title 1")
      expect(result.outlines[1][:title]).to eq("Fallback Title 2")
      expect(result.outlines[2][:title]).to eq("Explicit Title")
    end

    it "ignores outlines with a blank xmlUrl and treats them as folders while traversing their children" do
      opml = <<~XML
        <opml version="2.0">
          <body>
            <outline text="Empty URL Feed" xmlUrl="   ">
              <outline text="Child Inside Blank Feed" xmlUrl="https://example.com/child1.xml"/>
            </outline>
            <outline text="Pure Folder Without xmlUrl">
              <outline text="Child Inside Folder" xmlUrl="https://example.com/child2.xml"/>
            </outline>
          </body>
        </opml>
      XML

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines.size).to eq(2)
      expect(result.outlines.map { |o| o[:url] }).to eq([
        "https://example.com/child1.xml",
        "https://example.com/child2.xml"
      ])
    end

    it "accepts an OPML document with exactly 500 feed outlines" do
      items = (1..500).map do |i|
        %(<outline text="Feed #{i}" xmlUrl="https://example.com/#{i}.xml"/>)
      end.join("\n")
      opml = %(<opml version="2.0"><body>#{items}</body></opml>)

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines.size).to eq(500)
    end

    it "rejects an OPML document with 501 feed outlines as :too_many_outlines" do
      items = (1..501).map do |i|
        %(<outline text="Feed #{i}" xmlUrl="https://example.com/#{i}.xml"/>)
      end.join("\n")
      opml = %(<opml version="2.0"><body>#{items}</body></opml>)

      result = described_class.parse(opml)

      expect(result.ok?).to be false
      expect(result.reason).to eq(:too_many_outlines)
    end

    it "accepts an OPML document of exactly 1 MB (1_048_576 bytes)" do
      header = %(<opml version="2.0"><head><!-- )
      footer = %( --></head><body><outline text="Feed" xmlUrl="https://example.com/feed.xml"/></body></opml>)
      padding_needed = 1_048_576 - (header.bytesize + footer.bytesize)
      expect(padding_needed).to be > 0

      exact_1mb_opml = header + ("a" * padding_needed) + footer
      expect(exact_1mb_opml.bytesize).to eq(1_048_576)

      result = described_class.parse(exact_1mb_opml)

      expect(result.ok?).to be true
      expect(result.outlines.size).to eq(1)
    end

    it "rejects an OPML document of 1 MB + 1 byte (1_048_577 bytes) as :too_large before calling Nokogiri" do
      header = %(<opml version="2.0"><head><!-- )
      footer = %( --></head><body><outline text="Feed" xmlUrl="https://example.com/feed.xml"/></body></opml>)
      padding_needed = 1_048_577 - (header.bytesize + footer.bytesize)

      oversized_opml = header + ("a" * padding_needed) + footer
      expect(oversized_opml.bytesize).to eq(1_048_577)

      expect(Nokogiri).not_to receive(:XML)

      result = described_class.parse(oversized_opml)

      expect(result.ok?).to be false
      expect(result.reason).to eq(:too_large)
    end

    it "returns :malformed on empty body, whitespace only, non-XML text, and truncated XML" do
      expect(described_class.parse("").reason).to eq(:malformed)
      expect(described_class.parse("   \n\t   ").reason).to eq(:malformed)
      expect(described_class.parse("plain text not xml").reason).to eq(:malformed)
      expect(described_class.parse("<opml version=\"2.0\"><head><title>Truncated").reason).to eq(:malformed)
    end

    it "returns :malformed on XML with undefined entity reference" do
      xml = %(<opml version="2.0"><body><outline text="&unknownEntity;" xmlUrl="https://example.com/feed.xml"/></body></opml>)
      result = described_class.parse(xml)

      expect(result.ok?).to be false
      expect(result.reason).to eq(:malformed)
    end

    it "returns :not_opml when root element is not opml (e.g. rss or atom)" do
      rss = %(<rss version="2.0"><channel><title>RSS</title></channel></rss>)
      atom = %(<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title></feed>)

      expect(described_class.parse(rss).reason).to eq(:not_opml)
      expect(described_class.parse(atom).reason).to eq(:not_opml)
    end

    describe "DOCTYPE rejection" do
      it "rejects plain DOCTYPE as :doctype_not_allowed" do
        xml = %(<!DOCTYPE opml><opml version="2.0"><body/></opml>)
        result = described_class.parse(xml)

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
      end

      it "rejects DOCTYPE with internal subset as :doctype_not_allowed" do
        xml = <<~XML
          <!DOCTYPE opml [
            <!ENTITY x "y">
          ]>
          <opml version="2.0"><body/></opml>
        XML
        result = described_class.parse(xml)

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
      end

      it "rejects DOCTYPE SYSTEM as :doctype_not_allowed" do
        xml = %(<!DOCTYPE opml SYSTEM "http://example.com/opml.dtd"><opml version="2.0"><body/></opml>)
        result = described_class.parse(xml)

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
      end

      it "rejects DOCTYPE PUBLIC as :doctype_not_allowed" do
        xml = %(<!DOCTYPE opml PUBLIC "-//W3C//DTD OPML 2.0//EN" "http://example.com/opml.dtd"><opml version="2.0"><body/></opml>)
        result = described_class.parse(xml)

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
      end

      it "rejects external general entity file disclosure and never leaks the canary" do
        xxe = <<~XML
          <!DOCTYPE opml [
            <!ENTITY xxe SYSTEM "file://#{canary_file.path}">
          ]>
          <opml version="2.0"><body><outline text="&xxe;" xmlUrl="https://example.com/1"/></body></opml>
        XML

        result = described_class.parse(xxe)

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
        expect(result.inspect).not_to include(canary)
      end

      it "rejects external parameter entity and never leaks the canary" do
        param_xxe = <<~XML
          <!DOCTYPE opml [
            <!ENTITY % pe SYSTEM "file://#{canary_file.path}">
            %pe;
          ]>
          <opml version="2.0"><body/></opml>
        XML

        result = described_class.parse(param_xxe)

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
        expect(result.inspect).not_to include(canary)
      end

      it "rejects external entity pointing to HTTP URL without libxml2 opening socket connections" do
        conns = with_loopback_listener do |port|
          xxe_http = <<~XML
            <!DOCTYPE opml [
              <!ENTITY ext SYSTEM "http://127.0.0.1:#{port}/secret">
            ]>
            <opml version="2.0"><body><outline text="&ext;" xmlUrl="https://example.com/1"/></body></opml>
          XML

          result = described_class.parse(xxe_http)
          expect(result.ok?).to be false
          expect(result.reason).to eq(:doctype_not_allowed)
        end

        expect(conns).to eq(0)
      end

      it "rejects billion-laughs payload quickly without hanging" do
        billion_laughs = <<~XML
          <?xml version="1.0"?>
          <!DOCTYPE lolz [
           <!ENTITY lol "lol">
           <!ELEMENT lolz (#PCDATA)>
           <!ENTITY lol1 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
           <!ENTITY lol2 "&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;&lol1;">
           <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;">
          ]>
          <opml version="2.0"><body><outline text="&lol3;" xmlUrl="https://example.com/1"/></body></opml>
        XML

        result = Timeout.timeout(2) do
          described_class.parse(billion_laughs)
        end

        expect(result.ok?).to be false
        expect(result.reason).to eq(:doctype_not_allowed)
      end
    end

    it "parses UTF-8 BOM and UTF-16LE with BOM correctly" do
      utf8_bom = "\xEF\xBB\xBF<opml version=\"2.0\"><body><outline text=\"BOM\" xmlUrl=\"https://example.com/bom.xml\"/></body></opml>"
      expect(described_class.parse(utf8_bom).ok?).to be true

      utf16_xml = '<?xml version="1.0" encoding="utf-16"?><opml version="2.0"><body><outline text="UTF16" xmlUrl="https://example.com/16.xml"/></body></opml>'
      utf16_payload = "\xFF\xFE".b + utf16_xml.encode("UTF-16LE").b
      expect(described_class.parse(utf16_payload).ok?).to be true
    end

    it "rejects 10,000 nested outlines as :malformed quickly without crashing" do
      nested = %(<opml version="2.0"><head/><body>) + ("<outline text=\"F\">" * 10_000) + ("</outline>" * 10_000) + %(</body></opml>)

      result = Timeout.timeout(5) do
        described_class.parse(nested)
      end

      expect(result.ok?).to be false
      expect(result.reason).to eq(:malformed)
    end

    it "rejects deeply nested outlines (> 256 depth) as :malformed without HUGE enabled" do
      nested = %(<opml version="2.0"><head/><body>) + ("<outline text=\"F\">" * 500) + ("</outline>" * 500) + %(</body></opml>)

      result = Timeout.timeout(5) do
        described_class.parse(nested)
      end

      expect(result.ok?).to be false
      expect(result.reason).to eq(:malformed)
    end

    it "removes DEL and other post-parse characters from attribute values; a raw illegal control character and invalid UTF-8 in the body => :malformed" do
      del_title = "Title\x7FEnd"
      del_url = "https://example.com/feed\x7F.xml"
      del_html = "https://example.com/site\x7F"
      opml = %(<opml version="2.0"><body><outline title="#{del_title}" xmlUrl="#{del_url}" htmlUrl="#{del_html}"/></body></opml>)

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      outline = result.outlines.first
      expect(outline[:title]).to eq("TitleEnd")
      expect(outline[:url]).to eq("https://example.com/feed.xml")
      expect(outline[:html_url]).to eq("https://example.com/site")

      raw_ctrl = %(<opml version="2.0"><body><outline title="Title\x07" xmlUrl="https://example.com/1.xml"/></body></opml>)
      expect(described_class.parse(raw_ctrl).reason).to eq(:malformed)

      bad_utf8 = %(<opml version="2.0"><body><outline title="Title\xFF" xmlUrl="https://example.com/1.xml"/></body></opml>)
      expect(described_class.parse(bad_utf8).reason).to eq(:malformed)
    end

    it "ensures title clamped to 500, url NOT truncated, html_url nil above 2048" do
      long_title = "T" * 600
      long_url = "https://example.com/" + ("u" * 2500)
      long_html = "https://example.com/" + ("h" * 2500)
      opml = %(<opml version="2.0"><body><outline title="#{long_title}" xmlUrl="#{long_url}" htmlUrl="#{long_html}"/></body></opml>)

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      outline = result.outlines.first
      expect(outline[:title].length).to eq(500)
      expect(outline[:title]).to eq("T" * 500)
      expect(outline[:url]).to eq(long_url)
      expect(outline[:url].length).to eq(long_url.length)
      expect(outline[:html_url]).to be_nil
    end

    it "parses an ASCII-8BIT UTF-8 document with a multibyte title ('Árvíztűrő feed') into valid UTF-8" do
      opml = %(<opml version="2.0"><body><outline text="Árvíztűrő feed" xmlUrl="https://example.com/feed.xml"/></body></opml>).b
      result = described_class.parse(opml)

      expect(result.ok?).to be true
      outline = result.outlines.first
      expect(outline[:title]).to eq("Árvíztűrő feed")
      expect(outline[:title].encoding).to eq(Encoding::UTF_8)
      expect(outline[:title].valid_encoding?).to be true
    end

    it "parses an ISO-8859-1-declared document containing the byte 0xE9 in a title into 'é'" do
      iso_opml = %(<?xml version="1.0" encoding="ISO-8859-1"?>\n<opml version="2.0"><body><outline title="Caf\xE9" xmlUrl="https://example.com/feed.xml"/></body></opml>).b
      expect(Xml::SafeParser).to receive(:parse).with(satisfy { |b| b.encoding == Encoding::ASCII_8BIT }, doctype: :reject).and_call_original

      result = described_class.parse(iso_opml)

      expect(result.ok?).to be true
      expect(result.outlines.first[:title]).to eq("Café")
    end

    it "parses UTF-16LE with BOM passed as ASCII-8BIT" do
      utf16_xml = '<?xml version="1.0" encoding="utf-16"?><opml version="2.0"><body><outline text="UTF16 Feed" xmlUrl="https://example.com/16.xml"/></body></opml>'
      utf16_payload = ("\xFF\xFE".b + utf16_xml.encode("UTF-16LE").b).force_encoding("ASCII-8BIT")

      result = described_class.parse(utf16_payload)

      expect(result.ok?).to be true
      expect(result.outlines.first[:title]).to eq("UTF16 Feed")
      expect(result.outlines.first[:url]).to eq("https://example.com/16.xml")
    end

    it "returns a 5000-character xmlUrl with length 5000 without truncation" do
      long_url = "https://example.com/" + ("u" * 4980)
      expect(long_url.length).to eq(5000)
      opml = %(<opml version="2.0"><body><outline text="Long Feed" xmlUrl="#{long_url}"/></body></opml>)

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines.first[:url].length).to eq(5000)
      expect(result.outlines.first[:url]).to eq(long_url)
    end

    it "returns nil for a 2049-character html_url" do
      long_html = "https://example.com/" + ("h" * (2049 - "https://example.com/".length))
      expect(long_html.length).to eq(2049)
      opml = %(<opml version="2.0"><body><outline text="Feed" xmlUrl="https://example.com/feed.xml" htmlUrl="#{long_html}"/></body></opml>)

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines.first[:html_url]).to be_nil
    end

    it "returns output hashes containing only plain Ruby Strings or nil, with no Nokogiri objects" do
      opml = <<~XML
        <opml version="2.0">
          <body>
            <outline title="Feed 1" xmlUrl="https://example.com/1.xml" htmlUrl="https://example.com/1"/>
            <outline text="Feed 2" xmlUrl="https://example.com/2.xml"/>
          </body>
        </opml>
      XML

      result = described_class.parse(opml)

      expect(result.ok?).to be true
      expect(result.outlines).to be_an(Array)
      result.outlines.each do |outline|
        expect(outline).to be_a(Hash)
        expect(outline[:url]).to be_a(String)
        expect(outline[:title]).to be_a(String).or be_nil
        expect(outline[:html_url]).to be_a(String).or be_nil

        outline.each_value do |v|
          expect(v).not_to be_a(Nokogiri::XML::Node)
        end
      end
    end
  end
end
