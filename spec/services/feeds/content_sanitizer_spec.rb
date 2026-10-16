# frozen_string_literal: true

require "rails_helper"
require "uri"
require "set"

RSpec.describe Feeds::ContentSanitizer do
  EXPECTED_ALLOWED_ATTRIBUTES = {
    "a" => %w[href title rel].to_set,
    "img" => %w[src alt title width height].to_set,
    "td" => %w[colspan rowspan].to_set,
    "th" => %w[colspan rowspan].to_set,
    "time" => %w[datetime].to_set,
    "abbr" => %w[title].to_set
  }.freeze

  def assert_safe_html!(output)
    return if output.nil?

    lower = output.downcase
    expect(lower).not_to include("<script")
    expect(lower).not_to include("<style")
    expect(lower).not_to include("<iframe")
    expect(lower).not_to include("javascript:")
    expect(lower).not_to include("vbscript:")
    expect(lower).not_to include("data:text")

    frag = Nokogiri::HTML5.fragment(output)

    frag.search("*").each do |el|
      expect(described_class::TAGS).to include(el.name)

      allowed_attrs = EXPECTED_ALLOWED_ATTRIBUTES[el.name] || Set.new
      el.attribute_nodes.each do |attr_node|
        expect(allowed_attrs).to include(attr_node.name)
        expect(attr_node.name).not_to match(/\Aon/i)
      end
    end

    frag.css("a[href]").each do |a|
      uri = URI.parse(a["href"])
      expect(%w[http https mailto]).to include(uri.scheme&.downcase)
      expect(uri.userinfo).to be_blank if uri.respond_to?(:userinfo)
      expect(uri.user).to be_blank if uri.respond_to?(:user)
      if %w[http https].include?(uri.scheme&.downcase)
        expect(uri.host).to be_present
      elsif uri.scheme&.downcase == "mailto"
        expect(uri).to be_a(URI::MailTo)
        expect(uri.to).to be_present
      end

      rel_parts = a["rel"].to_s.split
      expect(rel_parts).to include("nofollow")
      expect(rel_parts).to include("noopener")
      expect(rel_parts).to include("noreferrer")
    end

    frag.css("img[src]").each do |img|
      uri = URI.parse(img["src"])
      expect(%w[http https]).to include(uri.scheme&.downcase)
      expect(uri.host).to be_present
      expect(uri.userinfo).to be_blank if uri.respond_to?(:userinfo)
      expect(uri.user).to be_blank if uri.respond_to?(:user)
    end
  end

  MALICIOUS_VECTORS = [
    # 1. script tags with and without attributes
    { name: "script tag without attributes", input: "<script>alert(1)</script>" },
    { name: "script tag with attributes", input: "<script src=\"https://evil.com/evil.js\" type=\"text/javascript\"></script>" },

    # 2. img onerror
    { name: "img onerror", input: "<img src=\"https://example.com/pic.png\" onerror=\"alert(1)\">" },

    # 3. img/a with javascript: (plain, mixed case, leading whitespace, tab/newline/entity-split)
    { name: "a href javascript: plain", input: "<a href=\"javascript:alert(1)\">link</a>" },
    { name: "img src javascript: plain", input: "<img src=\"javascript:alert(1)\">" },
    { name: "a href javascript: mixed case", input: "<a href=\"JavaSCRIPT:alert(1)\">link</a>" },
    { name: "img src javascript: mixed case", input: "<img src=\"JaVaScRiPt:alert(1)\">" },
    { name: "a href javascript: leading whitespace", input: "<a href=\"   javascript:alert(1)\">link</a>" },
    { name: "a href javascript: tab split", input: "<a href=\"java\tscript:alert(1)\">link</a>" },
    { name: "a href javascript: newline split", input: "<a href=\"java\nscript:alert(1)\">link</a>" },
    { name: "a href javascript: tab entity split", input: "<a href=\"java&#09;script:alert(1)\">link</a>" },
    { name: "a href javascript: decimal entity split", input: "<a href=\"&#106;avascript:alert(1)\">link</a>" },

    # 4. svg onload
    { name: "svg onload", input: "<svg onload=\"alert(1)\"><circle r=\"10\"/></svg>" },

    # 5. math and known mXSS patterns
    { name: "mXSS math/mtext/mglyph/style combination", input: "<math><mtext><table><mglyph><style><!--</style><img src=x onerror=alert(1)>" },
    { name: "mXSS noscript closing tag in title", input: "<noscript><p title=\"</noscript><img src=x onerror=alert(1)>\">" },
    { name: "mXSS nested form/math/mtext", input: "<form><math><mtext></form><form><mglyph><style></math><img src=x onerror=alert(1)>" },

    # 6. iframe, object, embed, applet, frame, frameset
    { name: "iframe", input: "<iframe src=\"https://evil.com\"></iframe>" },
    { name: "object", input: "<object data=\"evil.swf\"></object>" },
    { name: "embed", input: "<embed src=\"evil.swf\">" },
    { name: "applet", input: "<applet code=\"Evil.class\"></applet>" },
    { name: "frame", input: "<frame src=\"evil.html\">" },
    { name: "frameset", input: "<frameset><frame></frameset>" },

    # 7. base href
    { name: "base href", input: "<base href=\"https://evil.com\">" },

    # 8. meta refresh
    { name: "meta refresh", input: "<meta http-equiv=\"refresh\" content=\"0; url=https://evil.com\">" },

    # 9. link stylesheet
    { name: "link stylesheet", input: "<link rel=\"stylesheet\" href=\"https://evil.com/evil.css\">" },

    # 10. style tags with @import
    { name: "style tag with @import", input: "<style>@import \"https://evil.com/evil.css\";</style>" },

    # 11. style attributes (expression, url(javascript:))
    { name: "style attribute expression()", input: "<p style=\"background: expression(alert(1))\">text</p>" },
    { name: "style attribute url(javascript:)", input: "<p style=\"background: url(javascript:alert(1))\">text</p>" },

    # 12. a href with data:text/html
    { name: "a href data:text/html", input: "<a href=\"data:text/html,<script>alert(1)</script>\">link</a>" },

    # 13. img src with data:image/svg+xml
    { name: "img src data:image/svg+xml", input: "<img src=\"data:image/svg+xml;base64,PHN2Zy...\">" },

    # 14. vbscript:
    { name: "a href vbscript:", input: "<a href=\"vbscript:msgbox(1)\">link</a>" },

    # 15. input, button, textarea, select, video/audio/source with handlers
    { name: "input onfocus", input: "<input type=\"text\" onfocus=\"alert(1)\">" },
    { name: "button onclick", input: "<button onclick=\"alert(1)\">click</button>" },
    { name: "textarea oninput", input: "<textarea oninput=\"alert(1)\"></textarea>" },
    { name: "select onchange", input: "<select onchange=\"alert(1)\"><option>1</option></select>" },
    { name: "video/source with onerror", input: "<video controls onplay=\"alert(1)\"><source src=\"https://example.com/v.mp4\" onerror=\"alert(1)\"></video>" },
    { name: "audio onplaying", input: "<audio src=\"https://example.com/a.mp3\" onplaying=\"alert(1)\"></audio>" },

    # 16. details ontoggle
    { name: "details ontoggle", input: "<details ontoggle=\"alert(1)\"><summary>More</summary>Text</details>" },

    # 17. body onload
    { name: "body onload", input: "<body onload=\"alert(1)\"><p>Text</p></body>" },

    # 18. marquee
    { name: "marquee onstart", input: "<marquee onstart=\"alert(1)\">scrolling</marquee>" },

    # 19. unknown custom tags
    { name: "unknown custom tags", input: "<custom-widget evil=\"true\">content</custom-widget>" },

    # 20. HTML comments including conditional comments
    { name: "normal comment", input: "<!-- normal comment -->" },
    { name: "conditional comment with script", input: "<!--[if IE]><script>alert(1)</script><![endif]-->" },

    # 21. CDATA
    { name: "cdata with script", input: "<![CDATA[<script>alert(1)</script>]]>" },

    # 22. unclosed tags and quotes
    { name: "unclosed quotes", input: "<p><a href=\"https://example.com>Unclosed quote</a></p>" },
    { name: "unclosed tags", input: "<p><b><i>unclosed tags" },

    # 23. NUL bytes in tag and attribute names
    { name: "nul byte in tag name", input: "<scr\0ipt>alert(1)</scr\0ipt>" },
    { name: "nul byte in attribute name", input: "<a on\0click=\"alert(1)\">link</a>" },
    { name: "nul byte before href", input: "<a\0href=\"https://example.com\">link</a>" },

    # 24. invalid UTF-8
    { name: "invalid UTF-8 bytes", input: "Invalid \x80\xFF UTF-8 <p>text</p>".b },

    # 25. very long attribute values
    { name: "very long attribute value", input: "<a href=\"https://example.com\" title=\"#{'a' * 50_000}\">link</a>" },

    # 26. srcset, ping, formaction, target
    { name: "target and ping attributes", input: "<a href=\"https://example.com\" target=\"_blank\" ping=\"https://evil.com/track\">link</a>" },
    { name: "formaction attribute", input: "<button formaction=\"https://evil.com\">submit</button>" },
    { name: "srcset attribute", input: "<img src=\"https://example.com/pic.png\" srcset=\"https://evil.com/evil.jpg 2x\">" },

    # 27. protocol-relative //evil.example/x with an https base
    { name: "protocol-relative URL with https base", input: "<a href=\"//evil.example/x\">link</a>", base_url: "https://base.example/feed" },

    # 28. relative /x, ../y, ?q, #frag
    { name: "relative path /x", input: "<a href=\"/x\">link</a>", base_url: "https://base.example/dir/feed.xml" },
    { name: "relative dotdot ../y", input: "<a href=\"../y\">link</a>", base_url: "https://base.example/dir/feed.xml" },
    { name: "relative query ?q", input: "<a href=\"?q\">link</a>", base_url: "https://base.example/dir/feed.xml" },
    { name: "relative fragment #frag", input: "<a href=\"#frag\">link</a>", base_url: "https://base.example/dir/feed.xml" },

    # 29. mailto allowed
    { name: "mailto URL", input: "<a href=\"mailto:alice@example.com\">mail</a>" },

    # 30. tel: and ftp: removed
    { name: "tel: scheme removed", input: "<a href=\"tel:+12345678\">call</a>" },
    { name: "ftp: scheme removed", input: "<a href=\"ftp://example.com/file\">download</a>" },

    # 31. userinfo URLs removed
    { name: "userinfo in a href removed", input: "<a href=\"https://user:pass@example.com\">secret</a>" },
    { name: "userinfo in img src removed", input: "<img src=\"https://user:pass@example.com/img.png\">" },

    # 32. URLs over 2048 characters removed
    { name: "a href URL over 2048 chars", input: "<a href=\"https://example.com/#{'a' * 2050}\">long</a>" },

    # 33. relative links with no base_url removed
    { name: "relative a href with no base_url", input: "<a href=\"/relative\">link</a>", base_url: nil },
    { name: "relative img src with no base_url", input: "<img src=\"/pic.png\">", base_url: nil }
  ].freeze

  BENIGN_CASES = [
    { name: "paragraphs", html: "<p>Hello world paragraph.</p>" },
    { name: "nested lists", html: "<ul><li>Item 1<ol><li>Sub 1</li><li>Sub 2</li></ol></li><li>Item 2</li></ul>" },
    { name: "blockquote", html: "<blockquote><p>Quote text</p></blockquote>" },
    { name: "pre and code", html: "<pre><code>def foo; :bar; end</code></pre>" },
    { name: "headings h1-h6", html: "<h1>H1</h1><h2>H2</h2><h3>H3</h3><h4>H4</h4><h5>H5</h5><h6>H6</h6>" },
    { name: "tables", html: "<table><thead><tr><th colspan=\"2\">Header</th></tr></thead><tbody><tr><td>D1</td><td>D2</td></tr></tbody><tfoot><tr><td>F1</td><td>F2</td></tr></tfoot></table>" },
    { name: "figure and figcaption", html: "<figure><img src=\"https://example.com/img.jpg\" alt=\"alt\"><figcaption>Caption</figcaption></figure>" },
    { name: "bold and italic", html: "<p><b>bold</b> and <i>italic</i> and <em>em</em> and <strong>strong</strong> and <del>del</del> and <ins>ins</ins></p>" },
    { name: "links with title", html: "<p><a href=\"https://example.com/page\" title=\"My Title\">Link text</a></p>" },
    { name: "images with alt/width/height", html: "<p><img src=\"https://example.com/img.jpg\" alt=\"Description\" width=\"300\" height=\"200\" title=\"Photo\"></p>" },
    { name: "entities Unicode and emoji", html: "<p>&amp; &lt; &copy; 🚀 日本語 éàü</p>" }
  ].freeze

  describe "safety invariants and idempotence across malicious test vectors" do
    MALICIOUS_VECTORS.each do |vec|
      it "enforces safety invariants and idempotence for #{vec[:name]}" do
        output = described_class.call(vec[:input], base_url: vec[:base_url])
        assert_safe_html!(output)

        idempotent_output = described_class.call(output, base_url: vec[:base_url])
        expect(idempotent_output).to eq(output)
      end
    end
  end

  describe "benign content preservation and idempotence" do
    BENIGN_CASES.each do |vec|
      it "preserves structure, text content, and is idempotent for #{vec[:name]}" do
        output = described_class.call(vec[:html])
        expect(output).not_to be_nil
        assert_safe_html!(output)

        orig_text = Nokogiri::HTML5.fragment(vec[:html]).text
        san_text = Nokogiri::HTML5.fragment(output).text
        expect(san_text).to eq(orig_text)

        idempotent_output = described_class.call(output)
        expect(idempotent_output).to eq(output)
      end
    end
  end

  describe "specific element and attribute rules" do
    it "keeps the link text when a link loses its href" do
      result = described_class.call("<a href=\"javascript:alert(1)\">Keep this text</a>")
      expect(result).to eq("<a>Keep this text</a>")
    end

    it "removes an img entirely when it loses its src" do
      result = described_class.call("<p>Before <img src=\"javascript:alert(1)\" alt=\"pic\"> After</p>")
      expect(result).to eq("<p>Before  After</p>")
    end

    it "removes an img without src entirely" do
      result = described_class.call("<p><img alt=\"no src\"></p>")
      expect(result).to eq("<p></p>")
    end

    it "adds rel=\"nofollow noopener noreferrer\" to every remaining a[href]" do
      result = described_class.call("<a href=\"https://example.com/link\">Link</a>")
      expect(result).to eq("<a href=\"https://example.com/link\" rel=\"nofollow noopener noreferrer\">Link</a>")
    end

    it "overwrites existing rel on a[href] with nofollow noopener noreferrer" do
      result = described_class.call("<a href=\"https://example.com/link\" rel=\"author\">Link</a>")
      expect(result).to eq("<a href=\"https://example.com/link\" rel=\"nofollow noopener noreferrer\">Link</a>")
    end

    it "resolves relative links against base_url" do
      result = described_class.call("<a href=\"/relative/path\">Link</a>", base_url: "https://example.com/sub/index.html")
      expect(result).to eq("<a href=\"https://example.com/relative/path\" rel=\"nofollow noopener noreferrer\">Link</a>")
    end

    it "removes relative links when base_url is nil" do
      result = described_class.call("<a href=\"/relative/path\">Link</a>", base_url: nil)
      expect(result).to eq("<a>Link</a>")
    end

    it "removes relative links when base_url is invalid" do
      result = described_class.call("<a href=\"/relative/path\">Link</a>", base_url: "ftp://example.com")
      expect(result).to eq("<a>Link</a>")
    end

    it "removes URLs with userinfo" do
      result = described_class.call("<a href=\"https://user:pass@example.com/home\">Link</a>")
      expect(result).to eq("<a>Link</a>")
    end

    it "removes URLs longer than 2048 characters" do
      long_path = "a" * 2040
      result = described_class.call("<a href=\"https://example.com/#{long_path}\">Link</a>")
      expect(result).to eq("<a>Link</a>")
    end

    it "keeps img width and height only if digits only and at most 4 digits" do
      valid = described_class.call("<img src=\"https://example.com/pic.jpg\" width=\"800\" height=\"600\">")
      expect(valid).to include("width=\"800\"")
      expect(valid).to include("height=\"600\"")

      invalid_alpha = described_class.call("<img src=\"https://example.com/pic.jpg\" width=\"800px\" height=\"600%\">")
      expect(invalid_alpha).not_to include("width")
      expect(invalid_alpha).not_to include("height")

      too_long = described_class.call("<img src=\"https://example.com/pic.jpg\" width=\"10000\">")
      expect(too_long).not_to include("width")
    end

    it "allows td and th colspan/rowspan and time datetime and abbr title" do
      input = "<table><tr><th colspan=\"2\">Header</th></tr><tr><td rowspan=\"2\">Cell</td></tr></table><time datetime=\"2026-10-15\">Date</time><abbr title=\"World Wide Web\">WWW</abbr>"
      result = described_class.call(input)
      expect(result).to include("colspan=\"2\"")
      expect(result).to include("rowspan=\"2\"")
      expect(result).to include("datetime=\"2026-10-15\"")
      expect(result).to include("title=\"World Wide Web\"")
    end
  end

  describe "limits and defensive handling" do
    it "returns nil for nil, blank, or whitespace-only inputs" do
      expect(described_class.call(nil)).to be_nil
      expect(described_class.call("")).to be_nil
      expect(described_class.call("   ")).to be_nil
      expect(described_class.call("\n\t  \r")).to be_nil
    end

    it "truncates input over MAX_INPUT_CHARS and keeps output safe" do
      expect(described_class::MAX_INPUT_CHARS).to eq(200_000)
      huge_input = "<p>" + ("a" * 600_000) + "</p>"
      result = described_class.call(huge_input)
      expect(result).not_to be_nil
      expect(result.length).to be <= (described_class::MAX_INPUT_CHARS + 20)
      assert_safe_html!(result)
    end

    it "completes without exception, logs ArgumentError class name only, and produces safe output for pathological nesting (20_000 divs)" do
      allow(Rails.logger).to receive(:warn)
      pathological = "<div>" * 20_000 + "nested text" + "</div>" * 20_000
      result = described_class.call(pathological)
      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with("[Feeds::ContentSanitizer] ArgumentError")
      assert_safe_html!(result)
    end

    it "completes without exception, logs ArgumentError class name only, and produces safe output for pathological nesting (20_000 b tags)" do
      allow(Rails.logger).to receive(:warn)
      pathological = "<b>" * 20_000 + "nested text" + "</b>" * 20_000
      result = described_class.call(pathological)
      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with("[Feeds::ContentSanitizer] ArgumentError")
      assert_safe_html!(result)
    end

    it "finishes 512 KB of tag soup within 3 seconds" do
      soup_unit = "<div class=\"entry\"><p>Hello <b>world</b> and <a href=\"https://example.com/item\">link</a> with <i>italic</i> &amp; <img src=\"https://example.com/img.png\" alt=\"pic\" width=\"100\" height=\"100\"></p><blockquote><p>Quote text</p></blockquote></div>\n"
      soup = (soup_unit * (512_000 / soup_unit.bytesize + 1))[0, 512_000]

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = described_class.call(soup)
      t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      elapsed = t1 - t0
      expect(elapsed).to be < 3.0
      assert_safe_html!(result)
    end

    it "rescues StandardError in the first pass, logs only the error class name, and returns nil" do
      allow(Rails.logger).to receive(:warn)
      sanitizer_instance = instance_double(Rails::HTML5::SafeListSanitizer)
      allow(Rails::HTML5::SafeListSanitizer).to receive(:new).and_return(sanitizer_instance)
      allow(sanitizer_instance).to receive(:sanitize).and_raise(StandardError, "secret html content leak")

      result = described_class.call("<p>secret html</p>", base_url: "https://secret.example/url")
      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with("[Feeds::ContentSanitizer] StandardError")
    end

    it "rescues StandardError in the Nokogiri second-pass parse, logs only the error class name, and returns nil" do
      allow(Rails.logger).to receive(:warn)
      allow(Nokogiri::HTML5).to receive(:fragment).and_raise(StandardError, "nokogiri parse failure")

      result = described_class.call("<p>secret html</p>", base_url: "https://secret.example/url")
      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with("[Feeds::ContentSanitizer] StandardError")
    end

    it "rescues StandardError in URL resolution, logs only the error class name, and returns nil" do
      allow(Rails.logger).to receive(:warn)
      allow(described_class).to receive(:resolve_and_validate_url).and_raise(StandardError, "url resolution failure")

      result = described_class.call("<p><a href=\"https://secret.example/path\">link</a></p>", base_url: "https://secret.example/url")
      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with("[Feeds::ContentSanitizer] StandardError")
    end
  end
end
