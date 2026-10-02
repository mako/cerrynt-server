class FeedSerializer
  include Alba::Resource

  attributes :id, :url, :title, :site_url, :last_fetched_at
end
