FactoryBot.define do
  factory :api_token do
    user
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("token#{n}") }
    name { "test-device" }
  end
end
