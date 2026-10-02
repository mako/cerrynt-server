class CreateFeeds < ActiveRecord::Migration[8.1]
  def change
    create_table :feeds do |t|
      t.string :url, null: false
      t.string :title
      t.string :site_url
      t.string :etag
      t.string :last_modified
      t.datetime :last_fetched_at
      t.datetime :last_success_at
      t.integer :consecutive_failures, null: false, default: 0
      t.datetime :next_fetch_at
      t.string :status, null: false, default: "active"

      t.timestamps
    end
    add_index :feeds, :url, unique: true
    add_index :feeds, :next_fetch_at
  end
end
