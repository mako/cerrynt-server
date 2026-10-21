# frozen_string_literal: true

class ApplicationRecord < ActiveRecord::Base
  primary_abstract_class

  def self.write_transaction
    transaction(requires_new: true) do
      connection.materialize_transactions
      yield Time.current
    end
  end
end
