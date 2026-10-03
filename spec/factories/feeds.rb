FactoryBot.define do
  factory :feed do
    sequence(:url) { |n| "https://example.com/feed#{n}.xml" }
    title { "Example Feed" }
    status { "active" }
    consecutive_failures { 0 }
  end
end
