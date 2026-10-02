class CreateFeeds < ActiveRecord::Migration[8.1]
  def change
    create_table :feeds do |t|
      t.references :user, null: false, foreign_key: true
      t.string :url, null: false
      t.string :title
      t.string :site_url
      t.datetime :last_fetched_at

      t.timestamps
    end
  end
end
