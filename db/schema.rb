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

ActiveRecord::Schema[8.1].define(version: 2026_08_13_211050) do
  create_table "feeds", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_fetched_at"
    t.string "site_url"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_feeds_on_user_id"
  end

  create_table "items", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "feed_id", null: false
    t.string "guid", null: false
    t.datetime "published_at"
    t.datetime "read_at"
    t.text "summary"
    t.string "title"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.index ["feed_id", "guid"], name: "index_items_on_feed_id_and_guid", unique: true
    t.index ["feed_id"], name: "index_items_on_feed_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "api_token", null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "feeds", "users"
  add_foreign_key "items", "feeds"
end
