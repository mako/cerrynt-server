# frozen_string_literal: true

module EnvHelper
  def with_env(vars)
    orig_values = {}
    vars.each_key do |k|
      key = k.to_s
      orig_values[key] = ENV.key?(key) ? ENV[key] : :__unset__
    end

    Feeds::FetchGate.reset!
    vars.each do |k, v|
      key = k.to_s
      if v.nil?
        ENV.delete(key)
      else
        ENV[key] = v.to_s
      end
    end
    Feeds::FetchGate.reset!

    yield
  ensure
    orig_values.each do |key, val|
      if val == :__unset__
        ENV.delete(key)
      else
        ENV[key] = val
      end
    end
    Feeds::FetchGate.reset!
  end
end

RSpec.configure do |config|
  config.include EnvHelper
end
