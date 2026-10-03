require 'rails_helper'

RSpec.describe Feed, type: :model do
  describe "validations" do
    it "is valid with valid attributes" do
      expect(build(:feed)).to be_valid
    end

    it "requires a url" do
      feed = build(:feed, url: nil)
      expect(feed).not_to be_valid
      expect(feed.errors[:url]).to include("can't be blank")
    end

    it "requires a valid url format (http/https)" do
      feed = build(:feed, url: "ftp://example.com")
      expect(feed).not_to be_valid
      expect(feed.errors[:url]).to include("is invalid")
    end

    it "rejects urls with embedded spaces like 'foo http://example.com bar'" do
      feed = build(:feed, url: "foo http://example.com bar")
      expect(feed).not_to be_valid
      expect(feed.errors[:url]).to include("is invalid")
    end

    it "rejects javascript urls like 'javascript:alert(1)//http://x.com'" do
      feed = build(:feed, url: "javascript:alert(1)//http://x.com")
      expect(feed).not_to be_valid
      expect(feed.errors[:url]).to include("is invalid")
    end

    it "requires a unique url" do
      create(:feed, url: "https://example.com/feed")
      feed = build(:feed, url: "https://example.com/feed")
      expect(feed).not_to be_valid
      expect(feed.errors[:url]).to include("has already been taken")
    end

    it "raises database error on duplicate url" do
      create(:feed, url: "https://example.com/feed")
      expect {
        build(:feed, url: "https://example.com/feed").save(validate: false)
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "normalization" do
    it "downcases scheme and host, removes fragment, keeps trailing slash on non-root paths" do
      feed = Feed.new(url: "  HTTP://EXAMPLE.COM/feed/path/#frag  ")
      expect(feed.url).to eq("http://example.com/feed/path/")
    end

    it "removes empty path (trailing slash on host)" do
      feed = Feed.new(url: "https://example.com/")
      expect(feed.url).to eq("https://example.com")
    end

    it "ignores invalid URIs gracefully" do
      feed = Feed.new(url: "  not_a_url  ")
      expect(feed.url).to eq("not_a_url")
    end
  end

  describe "associations" do
    it "destroys associated records when destroyed" do
      feed = create(:feed)
      create(:subscription, feed: feed)
      create(:entry, feed: feed)

      expect { feed.destroy }.to change(Subscription, :count).by(-1)
        .and change(Entry, :count).by(-1)
    end
  end
end
