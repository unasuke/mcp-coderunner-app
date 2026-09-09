class CreateJobResults < ActiveRecord::Migration[8.1]
  def change
    create_table :job_results do |t|
      t.references :job, null: false, foreign_key: true
      t.string :termination_reason, null: false
      t.integer :exit_code
      t.text :stdout
      t.text :stderr
      t.boolean :truncated, null: false, default: false
      t.integer :duration_ms
      t.integer :cpu_time_ms
      t.bigint :max_rss_bytes
      # docker が返す "sha256:..." 形式。Blueprint の digest とは別物
      t.string :image_digest
      # ワーカーが実際に適用した値
      t.json :applied_limits, null: false
      t.string :worker_id

      t.timestamps
    end

    # 結果はジョブに 1 行だけ。最初に届いたものを採用する
    add_index :job_results, :job_id, unique: true
  end
end
