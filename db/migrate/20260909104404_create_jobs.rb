class CreateJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :jobs do |t|
      t.references :blueprint, null: false, foreign_key: true
      t.text :script, null: false
      # When retention emptied the script. It is what tells "deleted" from "empty to begin with"
      t.datetime :purged_at
      t.json :entrypoint
      t.string :profile, null: false
      # Defaults to pending_review, so a job whose state nobody set stops rather than runs
      t.string :state, null: false, default: "pending_review"
      t.references :requested_by, foreign_key: { to_table: :users }
      t.references :oauth_application, foreign_key: { to_table: :oauth_applications }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :cancel_requested_at

      t.timestamps
    end

    # Takes the oldest queued job, one at a time
    add_index :jobs, [ :state, :created_at ]
  end
end
