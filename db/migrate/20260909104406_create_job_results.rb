class CreateJobResults < ActiveRecord::Migration[8.1]
  def change
    create_table :job_results do |t|
      # One result row per job. The first to arrive is the one that counts
      t.references :job, null: false, foreign_key: true, index: { unique: true }
      t.string :termination_reason, null: false
      t.integer :exit_code
      t.text :stdout
      t.text :stderr
      t.boolean :truncated, null: false, default: false
      t.integer :duration_ms
      t.integer :cpu_time_ms
      t.bigint :max_rss_bytes
      # The "sha256:..." form docker returns. Not the same thing as a Blueprint's digest
      t.string :image_digest
      # What the worker actually applied
      t.json :applied_limits, null: false
      t.string :worker_id

      t.timestamps
    end
  end
end
