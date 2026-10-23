# frozen_string_literal: true

require "rails_helper"

RSpec.describe Xml::SafeParser do
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

  describe "default / :reject policy (OPML)" do
    it "successfully parses valid XML without a DOCTYPE" do
      xml = "<opml version=\"2.0\"><head><title>Test</title></head><body/></opml>"
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be true
      expect(result.doc).to be_a(Nokogiri::XML::Document)
      expect(result.doc.root.name).to eq("opml")
    end

    it "rejects plain DOCTYPE declaration" do
      xml = "<!DOCTYPE opml><opml version=\"2.0\"><head/><body/></opml>"
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
    end

    it "rejects DOCTYPE with internal subset" do
      xml = <<~XML
        <!DOCTYPE opml [
          <!ENTITY test "value">
        ]>
        <opml version="2.0"><head/><body/></opml>
      XML
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
    end

    it "rejects DOCTYPE with SYSTEM identifier" do
      xml = '<!DOCTYPE opml SYSTEM "http://example.com/opml.dtd"><opml version="2.0"><head/><body/></opml>'
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
    end

    it "rejects DOCTYPE with PUBLIC identifier" do
      xml = '<!DOCTYPE opml PUBLIC "-//W3C//DTD OPML 2.0//EN" "http://example.com/opml.dtd"><opml version="2.0"><head/><body/></opml>'
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
    end

    it "rejects external general entity file disclosure and never leaks the canary" do
      xxe = <<~XML
        <!DOCTYPE opml [
          <!ENTITY xxe SYSTEM "file://#{canary_file.path}">
        ]>
        <opml version="2.0"><head><title>&xxe;</title></head><body/></opml>
      XML

      result = described_class.parse(xxe, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
      expect(result.inspect).not_to include(canary)
    end

    it "rejects external parameter entity and never leaks the canary" do
      param_xxe = <<~XML
        <!DOCTYPE opml [
          <!ENTITY % pe SYSTEM "file://#{canary_file.path}">
          %pe;
        ]>
        <opml version="2.0"><head><title>Title</title></head><body/></opml>
      XML

      result = described_class.parse(param_xxe, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
      expect(result.inspect).not_to include(canary)
    end

    it "rejects external entity pointing to HTTP URL without libxml2 opening socket connections" do
      conns = with_loopback_listener do |port|
        xxe_http = <<~XML
          <!DOCTYPE opml [
            <!ENTITY ext SYSTEM "http://127.0.0.1:#{port}/secret">
          ]>
          <opml version="2.0"><head><title>&ext;</title></head><body/></opml>
        XML

        result = described_class.parse(xxe_http, doctype: :reject)
        expect(result.ok?).to be false
        expect(result.error).to eq(:doctype_not_allowed)
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
        <opml version="2.0"><head><title>&lol3;</title></head><body/></opml>
      XML

      result = Timeout.timeout(2) do
        described_class.parse(billion_laughs, doctype: :reject)
      end

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
    end

    it "does not enable entity substitution (NOENT) on parsed documents" do
      expect(Nokogiri).to receive(:XML).and_wrap_original do |original_method, *args, &block|
        configured_options = nil
        res = original_method.call(*args) do |config|
          block&.call(config)
          configured_options = config.options
        end
        expect(configured_options & Nokogiri::XML::ParseOptions::NOENT).to eq(0)
        res
      end
      result = described_class.parse("<opml version=\"2.0\"><head/><body/></opml>", doctype: :reject)
      expect(result.ok?).to be true
    end

    it "does not enable DTD loading (DTDLOAD) on parsed documents" do
      expect(Nokogiri).to receive(:XML).and_wrap_original do |original_method, *args, &block|
        configured_options = nil
        res = original_method.call(*args) do |config|
          block&.call(config)
          configured_options = config.options
        end
        expect(configured_options & Nokogiri::XML::ParseOptions::DTDLOAD).to eq(0)
        res
      end
      result = described_class.parse("<opml version=\"2.0\"><head/><body/></opml>", doctype: :reject)
      expect(result.ok?).to be true
    end

    it "enforces NONET on parse options to prevent network access" do
      expect(Nokogiri).to receive(:XML).and_wrap_original do |original_method, *args, &block|
        configured_options = nil
        res = original_method.call(*args) do |config|
          block&.call(config)
          configured_options = config.options
        end
        expect(configured_options & Nokogiri::XML::ParseOptions::NONET).to eq(Nokogiri::XML::ParseOptions::NONET)
        res
      end
      result = described_class.parse("<opml version=\"2.0\"><head/><body/></opml>", doctype: :reject)
      expect(result.ok?).to be true
    end

    it "does not enable HUGE on parse options" do
      expect(Nokogiri).to receive(:XML).and_wrap_original do |original_method, *args, &block|
        configured_options = nil
        res = original_method.call(*args) do |config|
          block&.call(config)
          configured_options = config.options
        end
        expect(configured_options & Nokogiri::XML::ParseOptions::HUGE).to eq(0)
        res
      end
      result = described_class.parse("<opml version=\"2.0\"><head/><body/></opml>", doctype: :reject)
      expect(result.ok?).to be true
    end

    it "parses UTF-8 with BOM normally" do
      xml = "\xEF\xBB\xBF<opml version=\"2.0\"><head><title>BOM</title></head><body/></opml>"
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be true
      expect(result.doc.root.name).to eq("opml")
    end

    it "parses UTF-16LE with BOM normally" do
      xml_str = '<?xml version="1.0" encoding="utf-16"?><opml version="2.0"><head><title>UTF-16</title></head><body/></opml>'
      utf16_payload = "\xFF\xFE".b + xml_str.encode("UTF-16LE").b

      result = described_class.parse(utf16_payload, doctype: :reject)

      expect(result.ok?).to be true
      expect(result.doc.root.name).to eq("opml")
    end

    it "returns :malformed on empty or whitespace body" do
      expect(described_class.parse("", doctype: :reject).error).to eq(:malformed)
      expect(described_class.parse("   \n\t  ", doctype: :reject).error).to eq(:malformed)
      expect(described_class.parse(nil, doctype: :reject).error).to eq(:malformed)
    end

    it "returns :malformed on non-XML text" do
      result = described_class.parse("hello this is not xml", doctype: :reject)
      expect(result.ok?).to be false
      expect(result.error).to eq(:malformed)
    end

    it "returns :malformed on XML with undefined entity reference" do
      xml = "<opml version=\"2.0\"><head><title>&unknownEntity;</title></head><body/></opml>"
      result = described_class.parse(xml, doctype: :reject)

      expect(result.ok?).to be false
      expect(result.error).to eq(:malformed)
    end
  end

  describe ":fetcher_compatible policy" do
    it "parses legacy RSS 0.91 feed with DOCTYPE without internal subset normally" do
      rss_091 = <<~XML
        <?xml version="1.0"?>
        <!DOCTYPE rss PUBLIC "-//Netscape Communications//DTD RSS 0.91//EN" "http://my.netscape.com/publish/formats/rss-0.91.dtd">
        <rss version="0.91">
          <channel>
            <title>Netscape RSS 0.91 Feed</title>
            <link>http://example.com</link>
            <description>Legacy Feed</description>
            <item>
              <title>Legacy Item</title>
              <link>http://example.com/item1</link>
            </item>
          </channel>
        </rss>
      XML

      result = described_class.parse(rss_091, doctype: :fetcher_compatible)

      expect(result.ok?).to be true
      expect(result.doc.root.name).to eq("rss")
    end

    it "rejects internal DTD with children under :fetcher_compatible" do
      internal_dtd = <<~XML
        <!DOCTYPE rss [
          <!ENTITY x "y">
        ]>
        <rss version="2.0"><channel><title>&x;</title></channel></rss>
      XML

      result = described_class.parse(internal_dtd, doctype: :fetcher_compatible)

      expect(result.ok?).to be false
      expect(result.error).to eq(:doctype_not_allowed)
    end

    it "rejects external HTTP entity without opening socket connection under :fetcher_compatible" do
      conns = with_loopback_listener do |port|
        xxe_http = <<~XML
          <!DOCTYPE rss [
            <!ENTITY ext SYSTEM "http://127.0.0.1:#{port}/secret">
          ]>
          <rss version="2.0"><channel><title>&ext;</title></channel></rss>
        XML

        result = described_class.parse(xxe_http, doctype: :fetcher_compatible)
        expect(result.ok?).to be false
        expect(result.error).to eq(:doctype_not_allowed)
      end

      expect(conns).to eq(0)
    end
  end
end
