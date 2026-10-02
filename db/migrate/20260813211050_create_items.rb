class CreateItems < ActiveRecord::Migration[8.1]
  def change
    create_table :items do |t|
      t.references :feed, null: false, foreign_key: true
      t.string :guid, null: false
      t.string :title
      t.string :url, null: false
      t.text :summary
      t.datetime :published_at
      t.datetime :read_at

      t.timestamps
    end
    add_index :items, [:feed_id, :guid], unique: true
  end
end
