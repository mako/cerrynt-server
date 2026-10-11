require 'rails_helper'

RSpec.describe Plan do
  describe ".limits_for" do
    it "returns limits for free plan" do
      expect(described_class.limits_for("free")).to eq({ max_feeds: 2 })
    end

    it "returns limits for pro plan" do
      expect(described_class.limits_for("pro")).to eq({ max_feeds: 100 })
    end

    it "falls back to free plan limits for unknown plan" do
      expect(described_class.limits_for("unknown")).to eq({ max_feeds: 2 })
    end
  end
end
