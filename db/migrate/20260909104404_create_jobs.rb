class CreateJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :jobs do |t|
      t.references :blueprint, null: false, foreign_key: true
      t.text :script, null: false
      # 保持期間を過ぎて script を空にした時刻。「消した」と「元々空だった」を区別する
      t.datetime :purged_at
      t.json :entrypoint
      t.string :profile, null: false
      # 既定値は pending_review。state の設定を書き忘れたジョブは実行されずに止まる
      t.string :state, null: false, default: "pending_review"
      t.references :requested_by, foreign_key: { to_table: :users }
      t.references :oauth_application, foreign_key: { to_table: :oauth_applications }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime :cancel_requested_at

      t.timestamps
    end

    # queued のジョブを古い順に 1 件掴む
    add_index :jobs, [ :state, :created_at ]
  end
end
