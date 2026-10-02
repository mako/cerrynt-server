class ItemSerializer
  include Alba::Resource

  attributes :id, :feed_id, :title, :url, :summary, :published_at, :read_at

  attribute :read do |item|
    item.read_at.present?
  end
end
