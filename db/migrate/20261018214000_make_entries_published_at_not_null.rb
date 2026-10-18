# frozen_string_literal: true

class MakeEntriesPublishedAtNotNull < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE entries SET published_at = created_at WHERE published_at IS NULL"
    change_column_null :entries, :published_at, false
  end

  def down
    change_column_null :entries, :published_at, true
  end
end
