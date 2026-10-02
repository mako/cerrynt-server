class CreateEntryStates < ActiveRecord::Migration[8.1]
  def change
    create_table :entry_states do |t|
      t.references :user, null: false, foreign_key: true
      t.references :entry, null: false, foreign_key: true
      t.datetime :read_at
      t.datetime :starred_at

      t.timestamps
    end
    add_index :entry_states, [:user_id, :entry_id], unique: true
    add_index :entry_states, [:user_id, :updated_at]
  end
end
