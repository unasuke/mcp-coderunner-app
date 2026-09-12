class CreatePushSubscriptions < ActiveRecord::Migration[8.1]
  def change
    create_table :push_subscriptions do |t|
      t.references :user, null: false, foreign_key: true

      # The push service's URL for this browser. Unique: subscribing twice from the
      # same browser hands back the same one
      t.string :endpoint, null: false, index: { unique: true }

      # The keys the payload is encrypted to. Without them a notification can only
      # be an empty ping
      t.string :p256dh_key, null: false
      t.string :auth_key, null: false

      # So a stale row can be recognised in /admin before it is deleted
      t.string :user_agent

      t.datetime :created_at, null: false
      t.datetime :updated_at, null: false
    end
  end
end
