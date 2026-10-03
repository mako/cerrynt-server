FactoryBot.define do
  factory :entry do
    feed
    sequence(:guid) { |n| "guid-#{n}" }
    sequence(:url) { |n| "https://example.com/post#{n}" }
    title { "A Post" }
    published_at { Time.current }
  end
end
