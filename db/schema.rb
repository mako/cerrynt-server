# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_02_232119) do
  create_table "api_tokens", force: :cascade do |t|
    t.integer "user_id", null: false
    t.string "token_digest", null: false
    t.string "name"
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "entries", force: :cascade do |t|
    t.integer "feed_id", null: false
    t.string "guid", null: false
    t.string "url"
    t.string "title"
    t.string "author"
    t.text "summary"
    t.text "content"
    t.datetime "published_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_id", "guid"], name: "index_entries_on_feed_id_and_guid", unique: true
    t.index ["feed_id", "published_at"], name: "index_entries_on_feed_id_and_published_at"
    t.index ["feed_id"], name: "index_entries_on_feed_id"
  end

  create_table "entry_states", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "entry_id", null: false
    t.datetime "read_at"
    t.datetime "starred_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entry_id"], name: "index_entry_states_on_entry_id"
    t.index ["user_id", "entry_id"], name: "index_entry_states_on_user_id_and_entry_id", unique: true
    t.index ["user_id", "updated_at"], name: "index_entry_states_on_user_id_and_updated_at"
    t.index ["user_id"], name: "index_entry_states_on_user_id"
  end

  create_table "feeds", force: :cascade do |t|
    t.string "url", null: false
    t.string "title"
    t.string "site_url"
    t.string "etag"
    t.string "last_modified"
    t.datetime "last_fetched_at"
    t.datetime "last_success_at"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "next_fetch_at"
    t.string "status", default: "active", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["next_fetch_at"], name: "index_feeds_on_next_fetch_at"
    t.index ["url"], name: "index_feeds_on_url", unique: true
  end

  create_table "subscriptions", force: :cascade do |t|
    t.integer "user_id", null: false
    t.integer "feed_id", null: false
    t.string "custom_title"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["feed_id"], name: "index_subscriptions_on_feed_id"
    t.index ["user_id", "feed_id"], name: "index_subscriptions_on_user_id_and_feed_id", unique: true
    t.index ["user_id"], name: "index_subscriptions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email", null: false
    t.string "password_digest", null: false
    t.string "plan", default: "free", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "api_tokens", "users"
  add_foreign_key "entries", "feeds"
  add_foreign_key "entry_states", "entries"
  add_foreign_key "entry_states", "users"
  add_foreign_key "subscriptions", "feeds"
  add_foreign_key "subscriptions", "users"
end
