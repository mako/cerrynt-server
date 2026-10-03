class Feed < ApplicationRecord
  has_many :subscriptions, dependent: :destroy
  has_many :users, through: :subscriptions
  has_many :entries, dependent: :destroy

  normalizes :url, with: ->(url) do
    return url if url.blank?

    begin
      uri = URI.parse(url.strip)
      return url.strip unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

      uri.scheme = uri.scheme&.downcase
      uri.host = uri.host&.downcase
      uri.fragment = nil
      uri.path = "" if uri.path == "/"
      uri.to_s
    rescue URI::InvalidURIError
      url.strip
    end
  end

  validates :url, presence: true, uniqueness: true
  validates :status, presence: true
  validate :url_must_be_valid_http

  private

  def url_must_be_valid_http
    return if url.blank?

    uri = URI.parse(url)
    errors.add(:url, :invalid) unless uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    errors.add(:url, :invalid)
  end
end
