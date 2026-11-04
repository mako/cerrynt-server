# frozen_string_literal: true

require "rails_helper"

RSpec.describe Opml::Export do
  include ActiveSupport::Testing::TimeHelpers
  def count_queries(&block)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      sql = payload[:sql].to_s.strip
      name = payload[:name].to_s
      unless name == "SCHEMA" || name == "TRANSACTION" || sql.match?(/\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)\b/i)
        queries << sql
      end
    end
    block.call
    queries.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  let(:user) { create(:user) }

  describe ".call" do
    context "with empty subscriptions" do
      it "returns a valid parseable OPML document with an empty body and zero outlines" do
        xml = described_class.call(user: user)

        expect(xml).to be_a(String)
        expect(xml).to include("<body/>")
        doc = Nokogiri::XML(xml)
        expect(doc.errors).to be_empty
        expect(doc.xpath("//outline")).to be_empty

        result = Opml::Parser.parse(xml)
        expect(result.ok?).to be true
        expect(result.outlines).to be_empty
      end
    end

    context "document structure and metadata" do
      it "includes the UTF-8 XML declaration, head title, and returns a UTF-8 String" do
        create(:subscription, user: user, feed: create(:feed, title: "Test Feed"))
        xml = described_class.call(user: user)

        expect(xml.encoding).to eq(Encoding::UTF_8)
        expect(xml).to start_with(%(<?xml version="1.0" encoding="UTF-8"?>))
        doc = Nokogiri::XML(xml)
        expect(doc.at_xpath("/opml/head/title")&.text).to eq("Cerrynt subscriptions")
        expect(doc.at_xpath("/opml")["version"]).to eq("2.0")
      end

      it "does not emit a DOCTYPE declaration" do
        create(:subscription, user: user, feed: create(:feed))
        xml = described_class.call(user: user)

        expect(xml).not_to include("<!DOCTYPE")
        doc = Nokogiri::XML(xml)
        expect(doc.internal_subset).to be_nil
        expect(doc.external_subset).to be_nil
      end

      it "produces byte-identical deterministic output across two calls separated by time travel" do
        create(:subscription, user: user, feed: create(:feed, title: "Feed 1"))
        output1 = described_class.call(user: user)

        output2 = travel_to 2.days.from_now do
          described_class.call(user: user)
        end

        expect(output2).to eq(output1)
      end
    end

    context "outline ordering and user scoping" do
      it "orders flat outlines by subscription created_at ASC, id ASC including two subscriptions with the same created_at" do
        fixed_time = 1.day.ago
        feed_old = create(:feed, title: "Old Subscription Feed")
        feed_same_a = create(:feed, title: "Tie Feed A")
        feed_same_b = create(:feed, title: "Tie Feed B")

        sub_old = create(:subscription, user: user, feed: feed_old, created_at: fixed_time - 1.hour)
        sub_same_a = create(:subscription, user: user, feed: feed_same_a, created_at: fixed_time)
        sub_same_b = create(:subscription, user: user, feed: feed_same_b, created_at: fixed_time)

        # Ensure sub_same_a.id < sub_same_b.id
        first_tie, second_tie = [ sub_same_a, sub_same_b ].sort_by(&:id)

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outlines = doc.xpath("//body/outline")

        expect(outlines.size).to eq(3)
        expect(outlines[0]["xmlUrl"]).to eq(sub_old.feed.url)
        expect(outlines[1]["xmlUrl"]).to eq(first_tie.feed.url)
        expect(outlines[2]["xmlUrl"]).to eq(second_tie.feed.url)
      end

      it "only exports the given user's subscriptions and excludes other users' subscriptions" do
        other_user = create(:user)
        shared_feed = create(:feed, title: "Shared Feed")
        other_feed = create(:feed, title: "Other User Private Feed")
        user_feed = create(:feed, title: "User Private Feed")

        create(:subscription, user: user, feed: shared_feed, custom_title: "My Shared Feed")
        create(:subscription, user: user, feed: user_feed)
        create(:subscription, user: other_user, feed: shared_feed, custom_title: "Other Person Shared Feed")
        create(:subscription, user: other_user, feed: other_feed)

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        titles = doc.xpath("//outline").map { |node| node["title"] }
        urls = doc.xpath("//outline").map { |node| node["xmlUrl"] }

        expect(titles).to contain_exactly("My Shared Feed", "User Private Feed")
        expect(urls).to contain_exactly(shared_feed.url, user_feed.url)
        expect(titles).not_to include("Other Person Shared Feed")
        expect(urls).not_to include(other_feed.url)
      end
    end

    context "outline attributes and NAME fallback chain" do
      it "emits type='rss', text, title, and xmlUrl attributes on outline elements" do
        feed = create(:feed, url: "https://example.com/rss.xml", title: "Ruby Feed")
        create(:subscription, user: user, feed: feed)

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outline = doc.at_xpath("//outline")

        expect(outline["type"]).to eq("rss")
        expect(outline["text"]).to eq("Ruby Feed")
        expect(outline["title"]).to eq("Ruby Feed")
        expect(outline["xmlUrl"]).to eq("https://example.com/rss.xml")
      end

      it "prefers custom_title over the feed title" do
        feed = create(:feed, title: "Original Feed Title")
        create(:subscription, user: user, feed: feed, custom_title: "My Custom Title")

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outline = doc.at_xpath("//outline")

        expect(outline["text"]).to eq("My Custom Title")
        expect(outline["title"]).to eq("My Custom Title")
      end

      it "falls back to the feed title when custom_title is blank" do
        feed = create(:feed, title: "Original Feed Title")
        create(:subscription, user: user, feed: feed, custom_title: "   ")

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outline = doc.at_xpath("//outline")

        expect(outline["text"]).to eq("Original Feed Title")
        expect(outline["title"]).to eq("Original Feed Title")
      end

      it "falls back to the feed URL when both custom_title and feed title are blank" do
        feed = create(:feed, title: nil, url: "https://example.com/notitle.xml")
        create(:subscription, user: user, feed: feed, custom_title: nil)

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outline = doc.at_xpath("//outline")

        expect(outline["text"]).to eq("https://example.com/notitle.xml")
        expect(outline["title"]).to eq("https://example.com/notitle.xml")
      end

      it "falls through the fallback chain when a custom_title contains only illegal control characters" do
        feed = create(:feed, title: "Fallback Feed Title")
        create(:subscription, user: user, feed: feed, custom_title: " \u0007 \u0000 \t \u001F ")

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outline = doc.at_xpath("//outline")

        expect(outline["text"]).to eq("Fallback Feed Title")
        expect(outline["title"]).to eq("Fallback Feed Title")
      end

      it "emits htmlUrl only when site_url is present, and never emits an empty htmlUrl attribute" do
        feed_with_site = create(:feed, site_url: "https://example.com/home")
        feed_without_site = create(:feed, site_url: nil)
        feed_blank_site = create(:feed, site_url: "   ")

        create(:subscription, user: user, feed: feed_with_site)
        create(:subscription, user: user, feed: feed_without_site)
        create(:subscription, user: user, feed: feed_blank_site)

        xml = described_class.call(user: user)
        doc = Nokogiri::XML(xml)
        outlines = doc.xpath("//outline")

        expect(outlines[0]["htmlUrl"]).to eq("https://example.com/home")
        expect(outlines[1].attributes).not_to have_key("htmlUrl")
        expect(outlines[2].attributes).not_to have_key("htmlUrl")
        expect(xml).not_to include('htmlUrl=""')
      end
    end

    context "character escaping and sanitisation" do
      it "escapes special XML characters in titles and URLs, producing well-formed XML that survives a round trip" do
        special_title = %(<Feed> & "Special" 'Name')
        special_url = "https://example.com/feed.xml?a=1&b=2"
        feed = create(:feed, url: special_url, title: "ignored")
        create(:subscription, user: user, feed: feed, custom_title: special_title)

        xml = described_class.call(user: user)

        expect(xml).to include("&lt;Feed&gt; &amp; &quot;Special&quot; 'Name'")
        expect(xml).to include("https://example.com/feed.xml?a=1&amp;b=2")

        doc = Nokogiri::XML(xml)
        expect(doc.errors).to be_empty

        result = Opml::Parser.parse(xml)
        expect(result.ok?).to be true
        expect(result.outlines.first[:title]).to eq(special_title)
        expect(result.outlines.first[:url]).to eq(special_url)
      end

      it "removes XML 1.0 illegal control characters and U+FFFE from titles and URLs so the document stays well-formed" do
        dirty_title = "Title \u0007 \u0008 \u000B \u000C \u000E \u001F \u007F \uFFFE \uFFFF End"
        dirty_url = "https://example.com/feed\u0007\u0000.xml"
        feed = create(:feed, title: "ignored")
        feed.update_column(:url, dirty_url)
        create(:subscription, user: user, feed: feed, custom_title: dirty_title)

        xml = described_class.call(user: user)

        expect(xml).not_to match(/[\u0000-\u0008\u000B-\u000C\u000E-\u001F\u007F\uFFFE\uFFFF]/)
        doc = Nokogiri::XML(xml)
        expect(doc.errors).to be_empty

        result = Opml::Parser.parse(xml)
        expect(result.ok?).to be true
        expect(result.outlines.first[:title]).to eq("Title End")
        expect(result.outlines.first[:url]).to eq("https://example.com/feed.xml")
      end
    end

    context "round trip and non-ASCII support" do
      it "successfully round-trips through Opml::Parser with identical URLs, titles, and htmlUrls in order, including multibyte and emoji characters" do
        feed1 = create(:feed, title: "Árvíztűrő feed", url: "https://example.com/arviz.xml", site_url: "https://example.com/arviz")
        feed2 = create(:feed, title: "Fox 🦊 Reader", url: "https://example.com/fox.xml", site_url: nil)

        create(:subscription, user: user, feed: feed1, created_at: 2.hours.ago)
        create(:subscription, user: user, feed: feed2, created_at: 1.hour.ago)

        xml = described_class.call(user: user)

        result = Opml::Parser.parse(xml)
        expect(result.ok?).to be true
        expect(result.outlines.size).to eq(2)

        expect(result.outlines[0]).to eq({
          url: "https://example.com/arviz.xml",
          title: "Árvíztűrő feed",
          html_url: "https://example.com/arviz"
        })
        expect(result.outlines[1]).to eq({
          url: "https://example.com/fox.xml",
          title: "Fox 🦊 Reader",
          html_url: nil
        })
      end
    end

    context "database query performance" do
      it "executes a constant number of SQL queries for 1 vs 5 vs 50 subscriptions" do
        user1 = create(:user)
        user5 = create(:user)
        user50 = create(:user)

        feed = create(:feed)
        create(:subscription, user: user1, feed: feed)

        5.times { create(:subscription, user: user5, feed: create(:feed)) }
        50.times { create(:subscription, user: user50, feed: create(:feed)) }

        queries_1 = count_queries { described_class.call(user: user1) }
        queries_5 = count_queries { described_class.call(user: user5) }
        queries_50 = count_queries { described_class.call(user: user50) }

        expect(queries_1).to eq(2)
        expect(queries_5).to eq(2)
        expect(queries_50).to eq(2)
      end
    end
  end
end
